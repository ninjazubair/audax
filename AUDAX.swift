// AUDAX: menu-bar dictation app. Owns two global shortcuts set in Settings (hold one to talk,
// press the other for hands-free), records the mic with a live voice meter, hands the WAV to the
// bundled dictate.py (local transcribe + clean-up), then pastes the text into the app the user
// was typing in.
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import Cocoa

let stateDir = NSHomeDirectory() + "/.cache/mac-dictation"
let wavURL = URL(fileURLWithPath: stateDir + "/rec.wav")
let logPath = stateDir + "/dictation.log"
let whisperCLI = "/opt/homebrew/bin/whisper-cli"
let modelPath = stateDir + "/models/ggml-large-v3-turbo-q5_0.bin"
let minRecordSeconds = 0.3  // shorter than this is "didn't catch that", never transcribed
let voiceFloorDB: Float = -50  // loudest tick below this is silence, never transcribed
// ponytail: calibration knob, assumed not measured; room noise on a Mac mic is usually
// -55…-70 dBFS, speech -35…-15. Tune from the peak_db log lines.
let maxSeconds = 300.0  // the only automatic stop
let tick = 0.05
let exitNothingHeard: Int32 = 3  // dictate.py's code; 2 is python's own "can't open file"
let ollamaModel = "gemma4"  // keep in step with OLLAMA_MODEL in dictate.py

enum Phase { case idle, recording, transcribing }
enum RecordMode { case hold, toggle }

/// Short generated chimes, independent of the alert-volume slider. The audio engine runs only
/// while a chime plays, so the speakers are not held open (and idle sleep not blocked) all day.
final class Chime {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    var pending = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ notes: [Double], step: Double = 0.085, length: Double = 0.22) {
        guard let buf = render(notes, step: step, length: length) else { return }
        if !engine.isRunning { try? engine.start() }
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

    func render(_ notes: [Double], step: Double, length: Double) -> AVAudioPCMBuffer? {
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
                out[start + i] += Float(0.28 * envelope * wave)
            }
        }
        return buf
    }

    func start() { play([880.0], length: 0.09) }  // one short soft tick
    func done() { play([784.0, 1046.5], step: 0.09, length: 0.2) }  // soft G-C: text pasted
    func nothing() { play([392.0, 293.7], step: 0.12, length: 0.25) }  // low, soft
}

/// Floating pill: pulsing red dot = recording; bars move only when a voice is heard.
final class Pill: NSView {
    var levels = [CGFloat](repeating: 0, count: 24)
    var label = ""
    var pulse: CGFloat = 1

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.92).setFill()
        let r = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        if label.isEmpty { drawMeter() } else { drawLabel() }
    }

    func drawLabel() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                   withAttributes: attrs)
    }

    func drawMeter() {
        NSColor.systemRed.withAlphaComponent(0.45 + 0.55 * pulse).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: bounds.midY - 5, width: 10, height: 10)).fill()
        let barWidth: CGFloat = 3, gap: CGFloat = 3
        var x: CGFloat = 38
        for level in levels {
            let h = 3 + level * (bounds.height - 17)
            (level > 0.02 ? NSColor.white : NSColor(white: 1, alpha: 0.3)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - h / 2, width: barWidth, height: h),
                         xRadius: 1.5, yRadius: 1.5).fill()
            x += barWidth + gap
        }
    }
}

final class HUD {
    let pill = Pill()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 42),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    var hideWork: DispatchWorkItem?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true  // never takes focus from the app being typed into
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = pill
    }

    func show(_ label: String = "") {
        hideWork?.cancel()
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = label.size(withAttributes: [.font: font]).width + 44
        let width = label.isEmpty ? 200 : max(200, textWidth)
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - width / 2, y: f.minY + 48, width: width, height: 42),
                           display: false)
        }
        pill.label = label
        pill.levels = pill.levels.map { _ in 0 }
        pill.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func meter(_ level: CGFloat, pulse: CGFloat) {
        pill.levels.removeFirst()
        pill.levels.append(level)
        pill.pulse = pulse
        pill.needsDisplay = true
    }

    func flash(_ label: String, seconds: Double = 1.6) {
        show(label)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() { panel.orderOut(nil) }
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
    var hotKeys: [EventHotKeyRef?] = []  // [talk, hands-free]
    var hotKeysPaused = false  // while a Settings recorder listens for a new shortcut
    var usr1: DispatchSourceSignal?
    var recorder: AVAudioRecorder?
    var timer: Timer?
    var target: NSRunningApplication?  // the app that had focus when the shortcut was pressed
    var targetIsSelf = false  // dictating into AUDAX's own window (its "Try it here" box)
    var voice = VoiceMeter()
    let model = Model()
    let settings = Settings()
    lazy var actions = Actions(
        toggle: { [unowned self] in self.toggle() },
        allowMic: { [unowned self] in self.allowMic() },
        allowPaste: { [unowned self] in self.openAccessibility() },
        runSetup: { [unowned self] in self.runSetup() },
        startOllama: { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app")) },
        openLog: { [unowned self] in self.openLog() },
        openSettings: { [unowned self] in self.showSettings() },
        pauseHotKeys: { [unowned self] in self.pauseHotKeys($0) })
    lazy var mainWindow = MainWindow(model: model, settings: settings, actions: actions)
    lazy var settingsWindow = SettingsWindow(settings: settings, actions: actions)
    var checkTimer: Timer?
    var phase = Phase.idle { didSet { refreshIcon(); model.phase = phase } }
    var mode = RecordMode.toggle
    var elapsed = 0.0
    var peakDB: Float = -160  // loudest valid tick of the current recording

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        buildMenu()
        installHotKeyHandler()
        registerHotKeys()
        settings.onShortcutsChanged = { [unowned self] in
            self.registerHotKeys()
            self.buildMenu()  // the dictation item shows the hands-free key
        }
        // `pkill -USR1 AUDAX` acts like the hands-free key: lets scripts and tests drive the app.
        signal(SIGUSR1, SIG_IGN)
        usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1?.setEventHandler { [weak self] in self?.toggle() }
        usr1?.resume()
        refreshIcon()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshChecks()
        }
        showWindow()
    }

    /// Clicking AUDAX in Launchpad, Finder or the Dock while it runs opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc func showWindow() {
        refreshChecks()
        model.recent = loadRecent()
        mainWindow.show()
    }

    @objc func showSettings() { settingsWindow.show() }

    func refreshChecks() {
        model.micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        model.pasteOK = AXIsProcessTrusted()
        model.engineOK = !needsSetup()
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let ok = data.map { String(decoding: $0, as: UTF8.self).contains("\"\(ollamaModel)") } ?? false
            DispatchQueue.main.async { self.model.cleanupOK = ok }
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
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([setup], withApplicationAt: terminal,
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
        menu.addItem(NSMenuItem(title: "Open AUDAX…", action: #selector(showWindow),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                keyEquivalent: ","))
        let handsFree = settings.handsFreeKey.display  // the item acts like the hands-free key
        menu.addItem(NSMenuItem(title: "Start / stop dictation   \(handsFree)",
                                action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open dictation log", action: #selector(openLog),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Allow pasting (Accessibility)…",
                                action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Run setup again…", action: #selector(runSetup),
                                keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AUDAX",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
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

    /// Id 1 = talk key, id 2 = hands-free key. Drops the old registrations first, so it runs
    /// again whenever the shortcuts change; registers nothing while paused.
    func registerHotKeys() {
        hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        guard !hotKeysPaused else { return }
        for (i, key) in [settings.talkKey, settings.handsFreeKey].enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x4155_4458, id: UInt32(i + 1))
            let events = GetApplicationEventTarget()
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, events, 0, &ref)
            if status != noErr {
                alert("\(key.display) is taken by another app (error \(status)). "
                      + "Pick another one in Settings.")
            }
            hotKeys.append(ref)
        }
    }

    /// A Settings recorder pauses the hot keys so it can see (and reject) the keys pressed.
    func pauseHotKeys(_ paused: Bool) {
        hotKeysPaused = paused
        registerHotKeys()
    }

    /// Talk key: press starts, release finishes. Hands-free key: press starts, next press
    /// finishes. Hot keys do not auto-repeat.
    func hotKey(id: UInt32, pressed: Bool) {
        switch (id, pressed, phase) {
        case (1, true, .idle): startDictation(mode: .hold)
        case (1, false, .recording) where mode == .hold: finishRecording()
        case (2, true, .idle): startDictation(mode: .toggle)
        case (2, true, .recording): finishRecording()
        default: break  // transcribing, repeats, or release of the other key
        }
    }

    /// The menu item, the window's button and SIGUSR1 act like the hands-free key.
    @objc func toggle() { hotKey(id: 2, pressed: true) }

    func startDictation(mode: RecordMode) {
        if needsSetup() { return offerSetup() }
        // An accessory (menu-bar) app is not reported as frontmost even when its window is
        // active, so check AUDAX's own state first.
        targetIsSelf = NSApp.isActive && mainWindow.window.isKeyWindow
        target = targetIsSelf ? nil : NSWorkspace.shared.frontmostApplication
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
        voice = VoiceMeter()
        if settings.cleanup != "off" { warmCleanupModel() }
        if settings.sounds { chime.start() }
        hud.show()
        // Start the mic just after the 0.09 s tick so it is not recorded, and soon enough not
        // to clip the first syllable of someone who talks the moment they press.
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
        hud.meter(level, pulse: CGFloat(0.5 + 0.5 * cos(elapsed * 2 * .pi)))
        if elapsed >= maxSeconds { finishRecording() }
    }

    func finishRecording() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        appendToLog(["peak_db": Double(peakDB.rounded()), "seconds": (elapsed * 10).rounded() / 10])
        guard elapsed >= minRecordSeconds, peakDB >= voiceFloorDB else {
            phase = .idle
            if settings.sounds { chime.nothing() }
            return hud.flash("Didn't catch that")
        }
        phase = .transcribing
        hud.show("Transcribing…")
        runDictateScript()
    }

    func runDictateScript() {
        let proc = Process()
        let out = Pipe(), err = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script, wavURL.path]
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

    /// What dictate.py reads on stdin. Never logged: from Task 5 on it carries an API key.
    func configJSON() -> Data {
        let config = ["provider": settings.provider,
                      "model": settings.models[settings.provider] ?? "",
                      "language": settings.language, "cleanup": settings.cleanup, "api_key": ""]
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
            let nothing = status == exitNothingHeard
            return hud.flash(nothing ? "Didn't catch that" : "Something went wrong: see log")
        }
        if settings.sounds { chime.done() }
        // Before paste, so that paste's own "Allow AUDAX in Accessibility" flash wins.
        if result?["cleanup"] as? String == "skipped" {
            hud.flash("Pasted without clean-up", seconds: 2.5)
        } else {
            hud.hide()
        }
        paste(text)
    }

    /// Loads the clean-up model now, while the user speaks, and keeps it loaded for an hour:
    /// Ollama otherwise unloads it after 5 idle minutes and the next clean-up takes ~4 s.
    func warmCleanupModel() {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": ollamaModel, "keep_alive": "1h"])
        URLSession.shared.dataTask(with: req).resume()  // fire and forget; failure = no clean-up
    }

    /// Puts the text on the clipboard (it stays there, like Blip) and pastes it into the app the
    /// user started dictating in, bringing that app back to the front if they switched away.
    func paste(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        if targetIsSelf {
            model.scratch += (model.scratch.isEmpty ? "" : " ") + text
            return appendToLog(["paste_into": "AUDAX window"])
        }
        guard AXIsProcessTrusted() else {
            appendToLog(["paste": "blocked: AUDAX is not allowed under Accessibility"])
            hud.flash("Copied. Allow AUDAX in Accessibility to paste automatically", seconds: 4)
            return openAccessibility()
        }
        let front = NSWorkspace.shared.frontmostApplication
        appendToLog(["paste_into": target?.localizedName ?? "?", "front": front?.localizedName ?? "?"])
        if let app = target, !app.isTerminated, app.processIdentifier != front?.processIdentifier {
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

    func refreshIcon() {
        let active = phase != .idle
        item.button?.image = NSImage(systemSymbolName: active ? "mic.fill" : "mic",
                                     accessibilityDescription: active ? "Recording" : "AUDAX")
        item.button?.contentTintColor = phase == .recording ? .systemRed : nil
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "AUDAX"
        a.informativeText = text
        bringToFront()
        a.runModal()
    }
}

func bringToFront() {
    if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}
