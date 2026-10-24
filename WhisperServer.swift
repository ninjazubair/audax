// WhisperServer: keeps whisper.cpp's whisper-server running on 127.0.0.1 while AUDAX runs, so
// dictate.py transcribes without loading the model on every dictation (measured 0.17 s per
// call against 0.42-0.49 s for whisper-cli). dictate.py falls back to whisper-cli whenever the
// server does not answer, so a server that is down only costs speed.
import Foundation

final class WhisperServer {
    let binary: String
    let model: String
    let port: Int
    private var proc: Process?
    private var lastStart = Date.distantPast
    private var stopping = false
    var isRunning: Bool { proc?.isRunning ?? false }

    init(binary: String, model: String, port: Int) {
        self.binary = binary
        self.model = model
        self.port = port
    }

    /// Launches the server; its stdout and stderr are appended to stateDir/whisper-server.log.
    func start() {
        guard !isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", String(port), "-nt"]
        let fd = open(stateDir + "/whisper-server.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let log = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.exited(ended) }
        }
        guard (try? p.run()) != nil else { return }  // dictate.py uses whisper-cli
        proc = p
        lastStart = Date()
        stopping = false
        appendToLog(["info": "whisper-server started"])
    }

    func stop() {
        stopping = true
        proc?.terminate()
    }

    /// An unexpected exit restarts the server, at most once per 60 s.
    private func exited(_ ended: Process) {
        guard ended === proc, !stopping else { return }
        appendToLog(["warning": "whisper-server exited: \(ended.terminationStatus)"])
        // ponytail: an exit within 60 s of the last start is not retried (another process holds
        // the port, a broken model), so a failing server never loops; whisper-cli covers it
        // until AUDAX restarts. A timer that retries later is the upgrade if that is too strict.
        if Date().timeIntervalSince(lastStart) >= 60 { start() }
    }
}
