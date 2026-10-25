// AUDAX main window: status checklist with fix buttons, a test box, recent dictations, and a
// footer that opens Settings.
// Opened when the user clicks AUDAX in Launchpad/Finder/Dock, and from the menu-bar icon.
import SwiftUI

struct Recent: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    let raw: String  // what Whisper heard, before the AI clean-up
}

final class Model: ObservableObject {
    @Published var phase = Phase.idle
    @Published var micOK = false
    @Published var pasteOK = false
    @Published var engineOK = false
    @Published var cleanupOK = false
    @Published var tapOK = false  // the Fn key tap exists and is enabled
    @Published var globeConflict = false  // App.globeKeyConflict
    @Published var mode = RecordMode.toggle
    @Published var gitHub = GitHubSignIn.signedOut  // copilot only: the last gh probe's answer
    @Published var recent: [Recent] = []
    @Published var scratch = ""

    /// `talk` and `handsFree` are the current shortcuts' labels, e.g. "Fn" and "Fn Space".
    func statusLine(talk: String, handsFree: String) -> String {
        switch phase {
        case .recording where mode == .hold:
            return "Listening… release \(talk) to finish, or press \(handsFree) to go hands-free"
        case .recording: return "Listening hands-free… press \(handsFree) to finish"
        case .transcribing: return "Transcribing…"
        case .idle:
            return micOK && pasteOK && engineOK
                ? "Ready. Hold \(talk) and speak, or press \(handsFree) to talk hands-free."
                : "Setup needed: see the red items below."
        }
    }
}

struct Actions {
    let toggle: () -> Void
    let allowMic: () -> Void
    let allowPaste: () -> Void
    let runSetup: () -> Void
    let signInGitHub: () -> Void
    let startOllama: () -> Void
    let openLog: () -> Void
    let openSettings: () -> Void
    let pauseHotKeys: (Bool) -> Void  // true while a shortcut recorder listens
    let openKeyboardSettings: () -> Void
    let fetchCopilotModels: (@escaping ([CopilotModel]) -> Void) -> Void  // App's; [] = failed
    // TEMP (lane U2 compile only; lane U1 adds the real fields and App wires them).
    var testConnection: (@escaping (String) -> Void) -> Void = { $0("Not wired yet") }
    var openEnvFile: () -> Void = { EnvFile.openOrCreateTemplate() }
}

struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let fixTitle: String  // "" for no fix button
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !ok && !fixTitle.isEmpty { Button(fixTitle, action: fix) }
        }
    }
}

/// Shown while a Fn-only shortcut competes with macOS's own action for the Fn (Globe) key.
struct GlobeHint: View {
    let open: () -> Void

    var body: some View {
        HStack {
            Text("macOS also uses the Fn key: set 'Press 🌐 key to' to Do Nothing")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Keyboard settings", action: open)
        }
    }
}

/// True when the clean-up changed actual words, not just punctuation or capitals.
func wordsDiffer(_ a: String, _ b: String) -> Bool {
    func words(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init).joined().split(separator: " ").joined(separator: " ")
    }
    return !a.isEmpty && words(a) != words(b)
}

struct TranscriptRow: View {
    let item: Recent
    @State private var copied = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.time).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 2)
            Text(item.text)
                .textSelection(.enabled)  // drag to copy part of it
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Button(copied == "text" ? "Copied" : "Copy") { copy(item.text, as: "text") }
                if wordsDiffer(item.raw, item.text) {
                    Button(copied == "raw" ? "Copied" : "Copy original") { copy(item.raw, as: "raw") }
                        .help("What was heard before the AI clean-up: \(item.raw)")
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 6)
    }

    func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = "" }
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: Settings
    let actions: Actions
    @FocusState private var tryBoxFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            GroupBox(label: Text("Status")) { checks.padding(6) }
            GroupBox(label: Text("Try it here")) { tryIt.padding(6) }
            GroupBox(label: Text("Transcripts")) { transcripts.padding(6) }
            footer
        }
        .padding(20)
        .frame(minWidth: 540)
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("AUDAX").font(.system(size: 22, weight: .bold))
                Text(model.statusLine(talk: settings.talkKey.display,
                                      handsFree: settings.handsFreeKey.display))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    var checks: some View {
        VStack(alignment: .leading, spacing: 10) {
            CheckRow(ok: model.micOK, title: "Microphone",
                     detail: "Lets AUDAX hear you while the pill is showing.",
                     fixTitle: "Allow…", fix: actions.allowMic)
            CheckRow(ok: model.pasteOK, title: "Paste into other apps",
                     detail: "Accessibility permission, so text appears where you type.",
                     fixTitle: "Allow…", fix: actions.allowPaste)
            CheckRow(ok: model.engineOK, title: "Speech engine and model",
                     detail: "whisper.cpp with the large-v3-turbo model, on this Mac's GPU.",
                     fixTitle: "Run setup…", fix: actions.runSetup)
            if settings.talkKey.needsTap || settings.handsFreeKey.needsTap { shortcutsRow }
            cleanupRow
        }
    }

    /// The Fn shortcuts run on the key tap, which needs Accessibility.
    var shortcutsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            CheckRow(ok: model.tapOK, title: "Shortcuts",
                     detail: model.tapOK ? "Fn shortcuts active."
                         : "Fn shortcuts need Accessibility.",
                     fixTitle: "Allow…", fix: actions.allowPaste)
            if model.globeConflict {
                GlobeHint(open: actions.openKeyboardSettings).padding(.leading, 26)
            }
        }
    }

    var cleanupRow: some View {
        let provider = settings.provider, name = settings.models[provider] ?? ""
        let ok = model.cleanupOK || settings.cleanup == "off"
        var detail = "Local Ollama with \(name): punctuation, fillers, corrections."
        if settings.cleanup == "off" {
            detail = "Switched off in Settings: you get the raw transcript."
        } else if provider == "copilot" && !ok {
            detail = model.gitHub == .noCLI
                ? "GitHub CLI not found. Install it with: brew install gh"
                : "Not signed in to GitHub. Sign in, then dictate."
        } else if let to = Settings.recipients[provider] {
            detail = "\(Settings.providerName(provider)) (\(name)): text is sent to \(to)."
        }
        let (fixTitle, fix) = cleanupFix
        return CheckRow(ok: ok, title: "AI clean-up", detail: detail, fixTitle: fixTitle, fix: fix)
    }

    /// No button without gh: the detail says how to install it.
    var cleanupFix: (String, () -> Void) {
        switch settings.provider {
        case "ollama": return ("Start Ollama", actions.startOllama)
        case "copilot": return (model.gitHub == .noCLI ? "" : "Sign in…", actions.signInGitHub)
        default: return ("Settings…", actions.openSettings)  // claude, openai: the key
        }
    }

    /// Off counts as local: with clean-up switched off no text is sent anywhere.
    var privacyNote: String {
        guard settings.cleanup != "off", let to = Settings.recipients[settings.provider] else {
            return "Audio and text never leave this Mac."
        }
        return "Audio stays on this Mac. Text is sent to \(to) for clean-up."
    }

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.scratch)
                .focused($tryBoxFocused)
                .onAppear { tryBoxFocused = true }  // open AUDAX, hold the talk key, talk
                .font(.body)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button(model.phase == .recording ? "Stop" : "Start dictation", action: actions.toggle)
                    .disabled(model.phase == .transcribing)
                Text("The text lands in this box. \(settings.talkKey.display) works the same "
                     + "in any other app.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    var transcripts: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.recent.isEmpty {
                Text("Nothing yet. Every dictation appears here, newest first, ready to copy.")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.recent) { item in
                            TranscriptRow(item: item)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 190, maxHeight: .infinity)  // takes the window's extra height
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var footer: some View {
        HStack {
            Button("Settings…", action: actions.openSettings)
            Button("Open log", action: actions.openLog)
            Button("Run setup again", action: actions.runSetup)
            Spacer()
            Text(privacyNote).font(.caption).foregroundColor(.secondary)
        }
    }
}

/// Reads the most recent successful dictations from the log, newest first.
func loadRecent(limit: Int = 30) -> [Recent] {
    guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
    var items: [Recent] = []
    for line in text.split(separator: "\n").reversed() where items.count < limit {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let final = entry["final"] as? String, !final.isEmpty else { continue }
        let at = entry["at"] as? String ?? ""
        let raw = entry["raw"] as? String ?? ""
        items.append(Recent(time: String(at.suffix(8).prefix(5)), text: final, raw: raw))
    }
    return items
}

final class MainWindow {
    let window: NSWindow

    init(model: Model, settings: Settings, actions: Actions) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "AUDAX"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 520)
        window.contentView = NSHostingView(rootView: MainView(model: model, settings: settings,
                                                              actions: actions))
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}
