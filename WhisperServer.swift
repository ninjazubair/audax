// WhisperServer: keeps whisper.cpp's whisper-server running on 127.0.0.1 while AUDAX runs, so
// dictate.py transcribes without loading the model on every dictation (measured 0.17 s per
// call against 0.42-0.49 s for whisper-cli). dictate.py falls back to whisper-cli whenever the
// server does not answer, so a server that is down only costs speed.
import Foundation

final class WhisperServer {
    let binary: String
    let model: String
    let port: Int
    /// Random per launch. The server answers only under this path, so a web page in the user's
    /// browser cannot reach /inference or /load on the fixed port (whisper-server sends
    /// Access-Control-Allow-Origin: *). dictate.py gets it on stdin, never in argv or env.
    let requestPath = "/audax-" + UUID().uuidString
    private let pidPath = stateDir + "/whisper-server.pid"
    private var proc: Process?
    private var lastStart = Date.distantPast
    private var retryGap: TimeInterval = 60  // never less: at most one start per minute
    private var stopping = false
    var isRunning: Bool { proc?.isRunning ?? false }

    init(binary: String, model: String, port: Int) {
        self.binary = binary
        self.model = model
        self.port = port
    }

    /// Starts the server when it is down, its binary and model exist (setup can add them while
    /// AUDAX runs) and `retryGap` has passed since the last start. AUDAX calls this at launch
    /// and every 5 s, so a restart is delayed, never dropped.
    func keepAlive() {
        let fm = FileManager.default
        guard !isRunning, !stopping, Date().timeIntervalSince(lastStart) >= retryGap,
              fm.isExecutableFile(atPath: binary), fm.fileExists(atPath: model) else { return }
        start()
    }

    /// Launches the server; its stdout and stderr are appended to stateDir/whisper-server.log.
    func start() {
        guard !isRunning else { return }
        stopOrphan()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        // -bs 5 -bo 5: beam search, as whisper-cli does, so both paths give the same text
        // (measured 0.143-0.152 s per call against 0.121-0.124 s greedy).
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port), "-nt",
                       "-bs", "5", "-bo", "5", "--request-path", requestPath]
        let fd = open(stateDir + "/whisper-server.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let log = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.exited(ended) }
        }
        lastStart = Date()  // a launch that fails counts too: keepAlive retries it a minute on
        do {
            try p.run()
        } catch {  // dictate.py uses whisper-cli meanwhile
            let why = error.localizedDescription
            return appendToLog(["warning": "whisper-server did not start: \(why)"])
        }
        proc = p
        stopping = false
        try? String(p.processIdentifier).write(toFile: pidPath, atomically: true, encoding: .utf8)
        appendToLog(["info": "whisper-server started"])
    }

    func stop() {
        stopping = true
        proc?.terminate()
    }

    /// An unexpected exit logs a warning and restarts the server: at once if it ran a minute or
    /// more. One that died sooner (a broken model) waits twice as long each time, up to an hour,
    /// so a server that cannot run costs a log line an hour, not one a minute.
    private func exited(_ ended: Process) {
        guard ended === proc, !stopping else { return }
        appendToLog(["warning": "whisper-server exited: \(ended.terminationStatus)"])
        let ranFor = Date().timeIntervalSince(lastStart)
        retryGap = ranFor < 60 ? min(retryGap * 2, 3600) : 60
        keepAlive()
    }

    /// A server left by an AUDAX that ended without quitting (a crash, SIGKILL) keeps its
    /// 861 MB and the port. It is stopped only while the PID it left still runs a
    /// whisper-server (by name, since a Homebrew upgrade moves the binary's real path) whose
    /// parent is launchd (PID 1): a server whose AUDAX still runs is not an orphan.
    private func stopOrphan() {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text), pid > 0 else { return }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_ppid == 1
        else { return }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
        let name = "/" + URL(fileURLWithPath: binary).lastPathComponent
        guard length > 0, String(decoding: path.prefix(length), as: UTF8.self).hasSuffix(name)
        else { return }
        kill(pid, SIGTERM)
        appendToLog(["warning": "stopped a whisper-server left running: \(pid)"])
    }
}
