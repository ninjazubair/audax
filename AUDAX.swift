// AUDAX: dictation app, in the Dock and the menu bar. Owns two global shortcuts set in Settings
// (hold one to talk, press the other for hands-free; Carbon hot keys, or the KeyTap for Fn ones),
// records the mic with a live voice meter, hands the WAV to the bundled dictate.py (local
// transcribe + clean-up), then pastes the text into the app the user was typing in.
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import Cocoa

let stateDir = NSHomeDirectory() + "/.cache/mac-dictation"
let wavURL = URL(fileURLWithPath: stateDir + "/rec.wav")
let logPath = stateDir + "/dictation.log"
let userSubsPath = stateDir + "/word_subs.json"  // dictate.py's USER_SUBS, not the bundled file
let whisperCLI = "/opt/homebrew/bin/whisper-cli"
let whisperServerBinary = "/opt/homebrew/bin/whisper-server"
let whisperServerPort = 18777  // dictate.py's WHISPER_SERVER
let modelPath = stateDir + "/models/ggml-large-v3-turbo-q5_0.bin"
let minRecordSeconds = 0.3  // shorter than this is "didn't catch that", never transcribed
let voiceFloorDB: Float = -50  // loudest tick below this is silence, never transcribed
// ponytail: calibration knob, assumed not measured; room noise on a Mac mic is usually
// -55…-70 dBFS, speech -35…-15. Tune from the peak_db log lines.
let maxSeconds = 300.0  // the only automatic stop
let tick = 0.05
let exitNothingHeard: Int32 = 3  // dictate.py's code; 2 is python's own "can't open file"

enum Phase { case idle, recording, transcribing }
enum RecordMode { case hold, toggle }
enum GitHubSignIn { case signedIn, signedOut, noCLI }  // for clean-up with GitHub Copilot

/// providers.GH_PATHS: absolute, because an app's PATH has no Homebrew.
let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

func ghPath() -> String? { ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

/// True when `gh auth token` prints a token within 3 s. The token stays in a local and is
/// dropped here: only "non-empty" leaves this function. dictate.py asks gh again per dictation.
func ghHasToken(_ gh: String) -> Bool {
    let proc = Process(), out = Pipe(), done = DispatchSemaphore(value: 0)
    proc.executableURL = URL(fileURLWithPath: gh)
    proc.arguments = ["auth", "token", "--hostname", "github.com"]
    proc.standardInput = FileHandle.nullDevice
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    proc.terminationHandler = { _ in done.signal() }
    guard (try? proc.run()) != nil else { return false }
    guard done.wait(timeout: .now() + 3) == .success else {
        proc.terminate()
        return false
    }
    let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return proc.terminationStatus == 0 && !token.isEmpty
}

typealias CopilotModel = (id: String, name: String)

/// `providers.py --copilot-models`: the Copilot seat's models, or [] on any failure or after
/// 10 s. Python asks gh for the token itself; only ids and names reach Swift. Blocks: call it
/// off the main thread.
func copilotModels(script: String) -> [CopilotModel] {
    let proc = Process(), out = Pipe(), done = DispatchSemaphore(value: 0)
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-B", "-X", "utf8", script, "--copilot-models"]
    proc.standardInput = FileHandle.nullDevice
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    proc.terminationHandler = { _ in done.signal() }
    guard (try? proc.run()) != nil else { return [] }
    // ponytail: read after exit, so the list must fit the 64 KB pipe buffer (38 models ≈ 3 KB);
    // a longer one times out to []. Read on a second thread if seats ever list hundreds.
    guard done.wait(timeout: .now() + 10) == .success else {
        proc.terminate()
        return []
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    return list.compactMap { m in
        guard let id = m["id"] as? String else { return nil }
        return (id: id, name: m["name"] as? String ?? id)
    }
}

/// `providers.py --test`: one tiny clean-up request with `config` (dictate.py's stdin, so it
/// carries the API key: stdin only, never argv, env or the log). "OK (N ms)" or the error text.
/// Blocks up to 25 s: call it off the main thread.
func providerTest(script: String, config: Data) -> String {
    let proc = Process(), input = Pipe(), out = Pipe(), done = DispatchSemaphore(value: 0)
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-B", "-X", "utf8", script, "--test"]
    // Written before launch, as for dictate.py: the pipe buffers it (a few hundred bytes).
    input.fileHandleForWriting.write(config)
    input.fileHandleForWriting.closeFile()
    proc.standardInput = input
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    proc.terminationHandler = { _ in done.signal() }
    guard (try? proc.run()) != nil else { return "Could not start providers.py" }
    guard done.wait(timeout: .now() + 25) == .success else {
        proc.terminate()
        return "No answer within 25 s"
    }
    return testResultText(out.fileHandleForReading.readDataToEndOfFile())
}

/// providers.py --test prints one line: {"ok": true, "ms": N} or {"ok": false, "error": "…"}.
func testResultText(_ data: Data) -> String {
    let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if reply?["ok"] as? Bool == true { return "OK (\(reply?["ms"] as? Int ?? 0) ms)" }
    return reply?["error"] as? String ?? "No result from providers.py"
}

/// Short generated chimes, independent of the alert-volume slider. The audio engine runs only
/// while a chime plays, so the speakers are not held open (and idle sleep not blocked) all day.
final class Chime {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    var pending = 0
    var warned = false  // the engine warning, logged once per dictation (beginRecording resets it)

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ notes: [Double], step: Double = 0.085, length: Double = 0.22,
              amplitude: Double = 0.28) {
        guard let buf = render(notes, step: step, length: length, amplitude: amplitude)
        else { return }
        if !engine.isRunning { try? engine.start() }
        // No sound and a log line, not a crash: play() on an engine that failed to start raises an
        // Objective-C exception ("player did not see an IO cycle", seen with audio output wedged).
        // ponytail: a running engine whose device dies mid-play can still raise; catching that
        // needs an Objective-C @try bridge, which this Swift-only build does not have.
        guard engine.isRunning else {
            if !warned { appendToLog(["warning": "audio engine did not start"]) }
            warned = true
            return
        }
        pending += 1
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.finished() }
        }
        player.play()
    }

    func finished() {
        pending -= 1
        if pending == 0 {
            player.stop()
            engine.stop()
        }
    }

    func render(_ notes: [Double], step: Double, length: Double,
                amplitude: Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount((step * Double(notes.count - 1) + length) * rate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let out = buf.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }
        for (n, freq) in notes.enumerated() {
            let start = Int(Double(n) * step * rate)
            for i in 0..<Int(length * rate) where start + i < Int(frames) {
                let t = Double(i) / rate
                let envelope = min(1, t / 0.004) * exp(-t * 14)
                let wave = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
                out[start + i] += Float(amplitude * envelope * wave)
            }
        }
        return buf
    }

    // Rising E-B, 0.31 s; recording starts at 0.1 s.
    func start() { play([659.3, 987.8], amplitude: 0.35) }
    func done() { play([784.0, 1046.5], step: 0.09, length: 0.2) }  // soft G-C: text pasted
    func nothing() { play([392.0, 293.7], step: 0.12, length: 0.25) }  // low, soft
}

/// Bar level for the pill from the recorder's level: tracks the room's noise floor so that only
/// sound clearly above it moves the bars.
struct VoiceMeter {
    let marginDB: Float = 12  // calibration knob: how far above room noise moves the bars
    var floor: Float?
    var shown: CGFloat = 0
    var ticks = 0

    mutating func update(db: Float) -> CGFloat {
        ticks += 1
        // Skip the recorder's warm-up dip (~150 ms) and invalid readings: one -160 dB sample
        // as the floor would make a quiet room move the bars for minutes.
        guard ticks > 4, db > -90 else {
            shown *= 0.7
            return shown
        }
        let current = floor ?? db
        floor = min(db, current + 0.03)  // drops at once, creeps up ~0.6 dB/s
        let above = db - (floor ?? db)
        let target = above > marginDB ? CGFloat(min(1, (above - marginDB / 2) / 30)) : 0
        shown = target > shown ? target : shown * 0.7  // fast rise, smooth fall
        return shown
    }
}

func appendToLog(_ entry: [String: Any]) {
    var e = entry
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")  // ASCII digits whatever the user's locale
    stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    e["at"] = stamp.string(from: Date())
    guard let data = try? JSONSerialization.data(withJSONObject: e),
          let line = String(data: data, encoding: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        h.closeFile()
    } else {
        try? (line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let script = Bundle.main.path(forResource: "dictate", ofType: "py") ?? ""
    let hud = HUD()
    let chime = Chime()
    let whisperServer = WhisperServer(binary: whisperServerBinary, model: modelPath,
                                      port: whisperServerPort)
    var hotKeys: [EventHotKeyRef?] = []  // the Carbon registrations, to drop on re-register
    var hotKeysPaused = false  // while a shortcut recorder listens for new keys
    var keyTap: KeyTap?  // Fn shortcuts; nil until Accessibility is granted
    var axTrusted = AXIsProcessTrusted()  // Accessibility at the last idle check: a grant renews
    var usr1: DispatchSourceSignal?
    var term: DispatchSourceSignal?
    var recorder: AVAudioRecorder?
    var timer: Timer?
    var target: NSRunningApplication?  // the app that had focus when the shortcut was pressed
    var targetIsSelf = false  // dictating into AUDAX's own window (its "Try it here" box)
    var lastOtherApp: NSRunningApplication?  // the last app in front that is not AUDAX
    var voice = VoiceMeter()
    let model = Model()
    let settings = Settings()
    lazy var actions = Actions(
        toggle: { [unowned self] in self.toggle() },
        allowMic: { [unowned self] in self.allowMic() },
        allowPaste: { [unowned self] in self.openAccessibility() },
        runSetup: { [unowned self] in self.runSetup() },
        signInGitHub: { [unowned self] in self.signInGitHub() },
        startOllama: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app")) },
        openLog: { [unowned self] in self.openLog() },
        openSettings: { [unowned self] in self.showSettings() },
        pauseHotKeys: { [unowned self] in self.pauseHotKeys($0) },
        openKeyboardSettings: {
            let pane = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        },
        fetchCopilotModels: { [unowned self] in self.fetchCopilotModels($0) },
        testConnection: { [unowned self] in self.testConnection($0) },
        openEnvFile: { EnvFile.openOrCreateTemplate() })
    lazy var mainWindow = MainWindow(model: model, settings: settings, actions: actions)
    var checkTimer: Timer?
    var keepAliveTimer: Timer?  // keeps the local clean-up model loaded while AUDAX runs
    var lastGitHubProbe = Date.distantPast  // the gh probe runs at most every 30 s
    var phase = Phase.idle { didSet { refreshIcon(); model.phase = phase } }
    var mode = RecordMode.toggle { didSet { model.mode = mode } }
    var elapsed = 0.0
    var peakDB: Float = -160  // loudest valid tick of the current recording
    var stoppedByCap = false  // maxSeconds ended it: nobody was there to stop it

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        whisperServer.keepAlive()  // first, so the model loads while the rest starts up
        buildMenu()
        buildMainMenu()
        installHotKeyHandler()
        startKeyTap()
        if keyTap == nil {
            appendToLog(["warning": "key tap unavailable: Accessibility not granted"])
        }
        registerHotKeys()
        settings.onShortcutsChanged = { [unowned self] in
            self.registerHotKeys()
            self.buildMenu()  // the dictation item shows the hands-free key
            self.refreshChecks()  // the Fn check row and the Globe-key hint
        }
        // `pkill -USR1 AUDAX` runs toggle(), as the menu item does: starts hands-free when idle,
        // finishes a recording. Lets scripts and tests drive the app.
        signal(SIGUSR1, SIG_IGN)
        usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1?.setEventHandler { [weak self] in self?.toggle() }
        usr1?.resume()
        // `pkill AUDAX` (build.sh --install) quits as the menu does, so applicationWillTerminate
        // stops whisper-server instead of leaving it to launchd with 861 MB and the port.
        signal(SIGTERM, SIG_IGN)
        term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term?.setEventHandler { NSApp.terminate(nil) }
        term?.resume()
        refreshIcon()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Every tick: the Fn tap's renewal and the server's keep-alive. The check rows' probes
            // (Ollama over HTTP, a gh process, the Keychain) only while a window shows them.
            if self.windowOnScreen { self.refreshChecks() } else { self.renewKeyTap() }
            self.whisperServer.keepAlive()  // restarts it, at most once a minute
        }
        checkTimer?.tolerance = 1  // lets macOS batch the wake-ups
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 240,
                                              repeats: true) { [weak self] _ in
            self?.warmCleanupModel()  // gated inside: local Ollama with clean-up on
        }
        keepAliveTimer?.tolerance = 10
        warmCleanupModel()  // now, not 4 minutes from now
        rememberOtherApp(NSWorkspace.shared.frontmostApplication)  // where AUDAX was opened from
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil,
            queue: .main) { [weak self] note in
            let key = NSWorkspace.applicationUserInfoKey
            self?.rememberOtherApp(note.userInfo?[key] as? NSRunningApplication)
        }
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisperServer.stop()
    }

    /// Clicking AUDAX in Launchpad, Finder or the Dock while it runs opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Closing the windows leaves AUDAX running: the shortcuts work with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Right-click on the Dock icon. Start / stop runs startDictation, so the text goes to the
    /// app in front or, if AUDAX is in front with no window of its own key, the app before it.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start / stop dictation   \(settings.handsFreeKey.display)",
                                action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    /// Kept for a dictation started while AUDAX is in front with none of its windows key (the
    /// last one closed): the text goes to the app the user was in before.
    func rememberOtherApp(_ app: NSRunningApplication?) {
        guard let app = app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastOtherApp = app
    }

    @objc func showWindow() {
        refreshChecks()
        model.recent = loadRecent()
        mainWindow.show()
    }

    /// ⌘, and the Settings… items: the window on Dictation.
    @objc func showSettings() {
        model.pane = .dictation
        showWindow()
    }

    @objc func showAbout() {
        model.pane = .about
        showWindow()
    }

    /// The window is on screen: open, not minimised, AUDAX not hidden.
    var windowOnScreen: Bool { mainWindow.window.isVisible }

    /// For the AI Provider pane's Test connection: the request on a background queue, the
    /// answer on main. The config is built here, on main (it reads the Keychain).
    func testConnection(_ completion: @escaping (String) -> Void) {
        let script = Bundle.main.path(forResource: "providers", ofType: "py") ?? ""
        let config = configJSON()
        DispatchQueue.global().async {
            let result = providerTest(script: script, config: config)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// For the Settings model picker: the list on a background queue, the completion on main.
    func fetchCopilotModels(_ completion: @escaping ([CopilotModel]) -> Void) {
        let script = Bundle.main.path(forResource: "providers", ofType: "py") ?? ""
        DispatchQueue.global().async {
            let models = copilotModels(script: script)
            DispatchQueue.main.async { completion(models) }
        }
    }

    /// The window's check rows; also renews the Fn tap. The timer runs it only while the window
    /// shows, and renewKeyTap alone otherwise.
    func refreshChecks() {
        renewKeyTap()
        model.micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        model.pasteOK = AXIsProcessTrusted()  // axTrusted waits for idle
        model.engineOK = !needsSetup()
        model.tapOK = keyTap?.isActive ?? false
        model.globeConflict = globeKeyConflict
        switch activeProvider {
        case "ollama": checkOllama()
        case "copilot": checkGitHub()
        default: model.cleanupOK = providerStatus(settings, model: model).ok  // keys, endpoints
        }
    }

    /// The provider dictations use (the .env's AUDAX_PROVIDER wins), so probes check that one.
    var activeProvider: String { ProviderInfo.active(settings, env: EnvFile.values()) }

    /// Accessibility granted since the last check (a tap from before a revoke may still count as
    /// enabled, yet sees no keys), or no tap, or a disabled one: a new tap. keyTap = nil first,
    /// so its deinit removes the old tap before the new one exists. Idle only, so a renewal never
    /// lands inside a recording; a grant meanwhile is seen on the first idle check.
    func renewKeyTap() {
        guard phase == .idle else { return }
        let wasTrusted = axTrusted
        axTrusted = AXIsProcessTrusted()
        guard axTrusted, !wasTrusted || keyTap?.isActive != true else { return }
        keyTap = nil
        startKeyTap()
        if keyTap != nil { registerHotKeys() }  // hands it the Fn shortcuts
    }

    /// Signed in to GitHub, from a background `gh auth token` probe at most every 30 s; between
    /// probes the last answer stands. No gh at all is a file check, done every time.
    func checkGitHub() {
        guard let gh = ghPath() else {
            model.gitHub = .noCLI
            model.cleanupOK = false
            return
        }
        model.cleanupOK = model.gitHub == .signedIn
        guard Date().timeIntervalSince(lastGitHubProbe) >= 30 else { return }
        lastGitHubProbe = Date()
        DispatchQueue.global().async {
            let signedIn = ghHasToken(gh)
            DispatchQueue.main.async {
                self.model.gitHub = signedIn ? .signedIn : .signedOut
                if self.activeProvider == "copilot" { self.model.cleanupOK = signedIn }
            }
        }
    }

    /// A Fn-only shortcut while macOS still runs its own action on an Fn (Globe) key press, i.e.
    /// "Press 🌐 key to" is not "Do Nothing" (0). Absent means the system default: not 0.
    /// Read only: AUDAX never writes that domain.
    var globeKeyConflict: Bool {
        guard settings.talkKey.isFnOnly || settings.handsFreeKey.isFnOnly else { return false }
        let hiToolbox = UserDefaults(suiteName: "com.apple.HIToolbox")
        return (hiToolbox?.object(forKey: "AppleFnUsageType") as? Int ?? -1) != 0
    }

    /// Ollama is running and has the configured model.
    func checkOllama() {
        let name = settings.models["ollama"] ?? ""
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let tags = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let ok = !name.isEmpty && tags.contains("\"\(name)")
            DispatchQueue.main.async {
                if self.activeProvider == "ollama" { self.model.cleanupOK = ok }
            }
        }.resume()
    }

    func allowMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refreshChecks() }
            }
        } else {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        }
    }

    func needsSetup() -> Bool {
        let fm = FileManager.default
        return !fm.isExecutableFile(atPath: whisperCLI) || !fm.fileExists(atPath: modelPath)
    }

    func offerSetup() {
        let a = NSAlert()
        a.messageText = "AUDAX needs a one-time setup"
        a.informativeText = "It installs the local speech engine (whisper.cpp), downloads its "
            + "574 MB model and the local clean-up model. Nothing is sent to the cloud. "
            + "Setup runs in a Terminal window; dictate once it says AUDAX is ready."
        a.addButton(withTitle: "Run setup")
        a.addButton(withTitle: "Later")
        bringToFront()
        if a.runModal() == .alertFirstButtonReturn { runSetup() }
    }

    @objc func runSetup() {
        guard let setup = Bundle.main.url(forResource: "setup", withExtension: "sh") else { return }
        openInTerminal(setup)
    }

    /// GitHub's own browser sign-in, in Terminal. The token stays in gh's store; AUDAX never
    /// keeps it. The next gh probe (within 30 s) turns the check green.
    func signInGitHub() {
        guard let gh = ghPath() else { return }
        let script = stateDir + "/gh-login.command"
        do {
            let login = "auth login --hostname github.com --web --git-protocol https"
            try "#!/bin/bash\nexec \(gh) \(login)\n"
                .write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        } catch {
            let why = error.localizedDescription
            return appendToLog(["warning": "GitHub sign-in not started: \(why)"])
        }
        openInTerminal(URL(fileURLWithPath: script))
        lastGitHubProbe = .distantPast  // the check row asks gh again on the next tick
    }

    func openInTerminal(_ script: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Pasting means sending Cmd+V to another app, which macOS allows only once the user
    /// ticks AUDAX under Privacy & Security > Accessibility. This shows that prompt.
    func askForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open AUDAX", action: #selector(showWindow),
                                keyEquivalent: ""))
        // toggle(): starts hands-free when idle, finishes a recording. Shown with the hands-free
        // key, which does the same except during a hold (there it locks hands-free).
        let handsFree = settings.handsFreeKey.display
        menu.addItem(NSMenuItem(title: "Start / stop dictation   \(handsFree)",
                                action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open dictation log", action: #selector(openLog),
                                keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AUDAX",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    /// The menu bar while AUDAX is in front, built once. Standard selectors with no target go to
    /// the first responder, so AppKit enables them: Edit works in Settings and the Try-it box,
    /// Minimize only for a window that can. The status menu keeps its own ⌘, and ⌘Q: AppKit
    /// matches key presses against the main menu, so those act only while that menu is open.
    func buildMainMenu() {
        let aboutItem = menuItem("About AUDAX", #selector(showAbout))
        let settingsItem = menuItem("Settings…", #selector(showSettings), ",")
        [aboutItem, settingsItem].forEach { $0.target = self }
        let appMenu = NSMenu(title: "AUDAX")
        appMenu.items = [
            aboutItem, .separator(), settingsItem, .separator(),
            menuItem("Hide AUDAX", #selector(NSApplication.hide(_:)), "h"),
            menuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                     [.command, .option]),
            menuItem("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            menuItem("Quit AUDAX", #selector(NSApplication.terminate(_:)), "q")]
        let edit = NSMenu(title: "Edit")
        edit.items = [
            menuItem("Undo", Selector(("undo:")), "z"),  // no Swift name for the responder action
            menuItem("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            menuItem("Cut", #selector(NSText.cut(_:)), "x"),
            menuItem("Copy", #selector(NSText.copy(_:)), "c"),
            menuItem("Paste", #selector(NSText.paste(_:)), "v"),
            menuItem("Select All", #selector(NSText.selectAll(_:)), "a")]
        let windows = NSMenu(title: "Window")
        windows.items = [
            menuItem("Close Window", #selector(NSWindow.performClose(_:)), "w"),
            menuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            menuItem("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            menuItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))]
        let bar = NSMenu()
        for menu in [appMenu, edit, windows] {
            let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            top.submenu = menu
            bar.addItem(top)
        }
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows  // AppKit lists the open windows here
    }

    /// Installed once at launch: every registered hot key reports press and release to `hotKey`.
    /// Carbon hot keys need no Accessibility permission, unlike a global key monitor.
    func installHotKeyHandler() {
        let specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let app = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
            app.hotKey(id: hkID.id, pressed: pressed)
            return noErr
        }, specs.count, specs, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Only when Accessibility is granted: without it creating a tap fails anyway.
    func startKeyTap() {
        guard AXIsProcessTrusted() else { return }
        keyTap = KeyTap()
        keyTap?.onKey = { [unowned self] in self.hotKey(id: $0, pressed: $1) }
        keyTap?.onFnChord = { [unowned self] in self.cancelRecording() }
    }

    /// Id 1 = talk key, id 2 = hands-free key. Fn shortcuts are matched by the key tap, the rest
    /// registered with Carbon. Drops the old registrations first, so it runs again whenever the
    /// shortcuts change; registers nothing while paused.
    func registerHotKeys() {
        hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        var keys: [(id: UInt32, shortcut: Shortcut)] = [(1, settings.talkKey),
                                                        (2, settings.handsFreeKey)]
        if hotKeysPaused { keys = [] }
        keyTap?.update(keys)  // matches only the Fn ones; the rest only exempt from Fn chords
        for (i, key) in keys where !key.needsTap {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x4155_4458, id: i)
            let events = GetApplicationEventTarget()
            let mods = key.modifiers & ~Shortcut.fnMask  // Carbon has no Fn modifier
            let status = RegisterEventHotKey(key.keyCode, mods, id, events, 0, &ref)
            if status != noErr {
                alert("\(key.display) is taken by another app (error \(status)). "
                      + "Pick another one in Settings.")
            }
            hotKeys.append(ref)
        }
    }

    /// A shortcut recorder (Dictation pane) pauses the hot keys so it can see (and reject) the
    /// keys pressed. A running recording finishes first: paused, a hold would never see its
    /// release.
    func pauseHotKeys(_ paused: Bool) {
        if paused, phase == .recording { finishRecording() }
        hotKeysPaused = paused
        registerHotKeys()
    }

    /// Talk key: press starts, release finishes. Hands-free key: press starts, next press
    /// finishes. The hands-free key during a hold locks it hands-free (Fn, then Space while Fn
    /// is down); the talk key is then ignored until it ends. Both engines report here; neither
    /// reports auto-repeats.
    func hotKey(id: UInt32, pressed: Bool) {
        switch (id, pressed, phase) {
        case (1, true, .idle): startDictation(mode: .hold)
        case (1, false, .recording) where mode == .hold: finishRecording()
        case (2, true, .idle): startDictation(mode: .toggle)
        case (2, true, .recording) where mode == .hold: lockHandsFree()
        case (2, true, .recording): finishRecording()
        default: break  // transcribing, the talk key during hands-free, other releases
        }
    }

    /// An Fn chord (Fn+Delete, Fn+←…) during a hold on the Fn talk key: the user meant the chord,
    /// not dictation. Stops without a sound or a transcript; the chord itself goes through.
    /// Hands-free (locked) recordings are left alone.
    func cancelRecording() {
        guard settings.talkKey.isFnOnly, phase == .recording, mode == .hold else { return }
        // Cuts the start sound to a blip. stop() still runs the buffer's completion handler,
        // once (checked), so Chime's pending count and engine stop stay right.
        chime.player.stop()
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        phase = .idle
        hud.hide()
        appendToLog(["cancel": "fn chord"])
    }

    /// Releasing the talk key no longer finishes. The pill's mode label says "Hands-free".
    func lockHandsFree() {
        mode = .toggle
        hud.showRecording(mode: .toggle)
    }

    /// The menu item, the window's button and SIGUSR1: start hands-free, or finish whatever
    /// recording runs (a hold too, so Stop always stops).
    @objc func toggle() {
        switch phase {
        case .idle: startDictation(mode: .toggle)
        case .recording: finishRecording()
        case .transcribing: break
        }
    }

    func startDictation(mode: RecordMode) {
        if needsSetup() { return offerSetup() }
        // AUDAX's window key on Home: its Try-it box gets the text directly, never by ⌘V. Key
        // on another pane (as the Settings window was): AUDAX is the frontmost app and gets ⌘V
        // as any app. AUDAX in front with its window not key (closed): the app the user was in
        // before, or the clipboard only when there is none (paste). Another app in front: that
        // app. Nothing here activates AUDAX: a hot key leaves the app in front where it is.
        let active = NSApp.isActive
        let windowKey = mainWindow.window.isKeyWindow
        targetIsSelf = active && windowKey && model.pane == .home
        target = targetIsSelf ? nil
            : active && !windowKey ? lastOtherApp : NSWorkspace.shared.frontmostApplication
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted { self.beginRecording(mode: mode) } else {
                    self.alert("Allow the microphone in System Settings > Privacy & Security.")
                }
            }
        }
    }

    func beginRecording(mode: RecordMode) {
        guard phase == .idle else { return }  // a second press while the mic prompt was open
        self.mode = mode
        phase = .recording
        elapsed = 0
        peakDB = -160
        stoppedByCap = false
        voice = VoiceMeter()
        warmCleanupModel()
        preReadModel()
        chime.warned = false
        model.seconds = 0
        if settings.sounds { chime.start() }
        hud.showRecording(mode: mode)
        // Start the mic 0.1 s in: later clips the first syllable of someone who talks the moment
        // they press. So the start sound's tail falls inside the recording window (≈0.2 s);
        // whether the warm-up skip (the first 0.25 s of readings) keeps it out of the silence
        // check is unmeasured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.phase == .recording else { return }
            self.startRecorder()
        }
    }

    func startRecorder() {
        guard recorder == nil else { return }
        let format: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        guard let rec = try? AVAudioRecorder(url: wavURL, settings: format), rec.record() else {
            phase = .idle
            hud.hide()
            return alert("Could not start recording from the microphone.")
        }
        rec.isMeteringEnabled = true
        recorder = rec
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            self?.meter()
        }
    }

    func meter() {
        guard let rec = recorder else { return }
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0)
        let level = voice.update(db: db)
        if voice.ticks > 4, db > -90 { peakDB = max(peakDB, db) }  // VoiceMeter's warm-up skip
        elapsed += tick
        hud.meter(level)
        if Int(elapsed) != model.seconds { model.seconds = Int(elapsed) }  // the toolbar clock
        if elapsed >= maxSeconds {
            stoppedByCap = true
            finishRecording()
        }
    }

    func finishRecording() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        var entry: [String: Any] = ["peak_db": Double(peakDB.rounded()),
                                    "ms": Int((elapsed * 1000).rounded())]
        if stoppedByCap { entry["cap"] = true }
        appendToLog(entry)
        guard elapsed >= minRecordSeconds, peakDB >= voiceFloorDB else {
            phase = .idle
            if settings.sounds { chime.nothing() }
            return hud.flash("Didn't catch that", symbol: "waveform.slash", seconds: 1.6)
        }
        phase = .transcribing
        hud.showTranscribing()
        runDictateScript()
    }

    func runDictateScript() {
        let proc = Process()
        let out = Pipe(), err = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // -B: never a __pycache__ in the signed app. -X utf8: stdout and the log are UTF-8
        // whatever LANG says (dictate.py writes German text unescaped).
        proc.arguments = ["-B", "-X", "utf8", script, wavURL.path]
        // Settings go in on stdin, written before launch: the pipe buffers them, and a script
        // that exits early cannot leave a write to a closed pipe (SIGPIPE).
        let input = Pipe()
        input.fileHandleForWriting.write(configJSON())
        input.fileHandleForWriting.closeFile()
        proc.standardInput = input
        proc.standardOutput = out
        proc.standardError = err
        proc.terminationHandler = { p in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                if !problem.isEmpty { appendToLog(["stderr": problem, "exit": p.terminationStatus]) }
                self.transcribed(status: p.terminationStatus, text: text)
            }
        }
        do { try proc.run() } catch {
            phase = .idle
            hud.hide()
            appendToLog(["error": "could not start dictate.py: \(error)"])
            alert("Could not start dictate.py: \(error)")
        }
    }

    /// What dictate.py (and providers.py --test) reads on stdin. Never logged: the provider
    /// fields carry secrets from the Keychain. Copilot needs none: dictate.py asks gh.
    func configJSON() -> Data {
        let base: [String: Any] = ["language": settings.language, "cleanup": settings.cleanup,
                                   "whisper_path": whisperServer.requestPath]
        let config = base.merging(providerConfigFields(settings)) { mine, _ in mine }
        return (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
    }

    /// `output` is dictate.py's stdout: {"text", "cleanup", "error"}, or plain text from an
    /// older script.
    func transcribed(status: Int32, text output: String) {
        phase = .idle
        model.recent = loadRecent()
        let result = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        let text = result == nil ? output : result?["text"] as? String ?? ""
        guard status == 0, !text.isEmpty else {
            if settings.sounds { chime.nothing() }
            if status == exitNothingHeard {
                return hud.flash("Didn't catch that", symbol: "waveform.slash", seconds: 1.6)
            }
            return hud.flash("Something went wrong: see log",
                             symbol: "exclamationmark.triangle.fill", seconds: 1.6)
        }
        if settings.sounds { chime.done() }
        deliver(text, skipped: result?["cleanup"] as? String == "skipped")
    }

    /// A recording ended by the 5-minute cap had nobody there to stop it, so whatever app is in
    /// front now may not be where the text belongs: clipboard only.
    func deliver(_ text: String, skipped: Bool) {
        if stoppedByCap {
            copyToClipboard(text)
            return hud.flash("Copied: recording hit the 5-minute limit",
                             symbol: "doc.on.clipboard.fill", seconds: 4)
        }
        // Before paste, so that paste's own flashes (clipboard only, Accessibility) win.
        if skipped {
            hud.flash("Pasted without clean-up", symbol: "checkmark.circle", seconds: 2.5)
        } else {
            hud.flash("Pasted", symbol: "checkmark.circle.fill", seconds: 1.2)
        }
        paste(text)
    }

    /// Keeps the clean-up model loaded while AUDAX runs: called at launch, when a recording
    /// starts, and every 4 minutes from `keepAliveTimer`. Ollama otherwise unloads it (when idle,
    /// or to load another model) and the next clean-up takes ~4 s.
    /// Local Ollama with clean-up on only: nothing is sent for another provider.
    func warmCleanupModel() {
        guard activeProvider == "ollama", settings.cleanup != "off",
              let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": settings.models["ollama"] ?? "", "keep_alive": "1h"])
        URLSession.shared.dataTask(with: req).resume()  // fire and forget; failure = no clean-up
    }

    /// Reads the whisper model while the user speaks, so whisper-cli finds it in memory instead
    /// of on disk. Fire and forget. Skipped while whisper-server runs: it holds the model, and
    /// whisper-cli is only its fallback.
    func preReadModel() {
        guard !whisperServer.isRunning, FileManager.default.fileExists(atPath: modelPath)
        else { return }
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/cat")
        cat.arguments = [modelPath]
        cat.standardOutput = FileHandle.nullDevice
        try? cat.run()
    }

    /// Puts the text on the clipboard (it stays there, like Blip) and pastes it into the app the
    /// user started dictating in, bringing that app back to the front if they switched away.
    /// No such app (none known, or quit since): the clipboard only, never ⌘V into whatever is
    /// in front.
    func paste(_ text: String) {
        copyToClipboard(text)
        // Smoke runs set this, so a test can never paste into the app in front.
        if ProcessInfo.processInfo.environment["AUDAX_NO_PASTE"] == "1" {
            return appendToLog(["paste": "suppressed by AUDAX_NO_PASTE"])
        }
        if targetIsSelf {
            model.scratch += (model.scratch.isEmpty ? "" : " ") + text
            return appendToLog(["paste_into": "AUDAX window"])
        }
        guard let app = target, !app.isTerminated else {
            appendToLog(["paste": "clipboard only: no app to paste into"])
            return hud.flash("Copied to the clipboard", symbol: "doc.on.clipboard.fill",
                             seconds: 2)
        }
        guard AXIsProcessTrusted() else {
            appendToLog(["paste": "blocked: AUDAX is not allowed under Accessibility"])
            hud.flash("Copied. Allow AUDAX in Accessibility to paste automatically",
                      symbol: "exclamationmark.triangle.fill", seconds: 4)
            return openAccessibility()
        }
        let front = NSWorkspace.shared.frontmostApplication
        appendToLog(["paste_into": app.localizedName ?? "?", "front": front?.localizedName ?? "?"])
        if app.processIdentifier != front?.processIdentifier {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.sendCommandV() }
        } else {
            sendCommandV()
        }
    }

    func sendCommandV() {
        // ponytail: kVK_ANSI_V is a key position; on pure Dvorak it sends Cmd+. instead of paste.
        // Look up the layout's "v" key (UCKeyTranslate) if a Dvorak user ever needs it.
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V),
                                keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func openAccessibility() {
        askForAccessibility()
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// The menu-bar mic and the Dock badge follow the phase.
    func refreshIcon() {
        let active = phase != .idle
        item.button?.image = NSImage(systemSymbolName: active ? "mic.fill" : "mic",
                                     accessibilityDescription: active ? "Recording" : "AUDAX")
        item.button?.contentTintColor = phase == .recording ? .systemRed : nil
        NSApp.dockTile.badgeLabel = [Phase.recording: "●", .transcribing: "…"][phase]  // idle: nil
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "AUDAX"
        a.informativeText = text
        bringToFront()
        a.runModal()
    }
}

func bringToFront() { NSApp.activate() }  // macOS 14 API; build.sh's MIN_MACOS is 14.0

/// A main-menu item with no target: AppKit sends `action` to the first responder.
func menuItem(_ title: String, _ action: Selector, _ key: String = "",
              _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
