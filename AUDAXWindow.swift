// AUDAX main window: status checklist with fix buttons, a test box, recent dictations, settings.
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
    @Published var recent: [Recent] = []
    @Published var scratch = ""
    @Published var cleanup: Bool { didSet { UserDefaults.standard.set(cleanup, forKey: "cleanup") } }
    @Published var pause: Double { didSet { UserDefaults.standard.set(pause, forKey: "pause") } }

    init() {
        cleanup = UserDefaults.standard.object(forKey: "cleanup") as? Bool ?? true
        pause = UserDefaults.standard.object(forKey: "pause") as? Double ?? 1.5
    }

    var statusLine: String {
        switch phase {
        case .recording: return "Listening… release the key, or press it again to finish"
        case .transcribing: return "Transcribing…"
        case .idle:
            return micOK && pasteOK && engineOK
                ? "Ready. Hold ⌃⌥D and speak, or press ⌃⌥Space to talk hands-free."
                : "Setup needed: see the red items below."
        }
    }
}

struct Actions {
    let toggle: () -> Void
    let allowMic: () -> Void
    let allowPaste: () -> Void
    let runSetup: () -> Void
    let startOllama: () -> Void
    let openLog: () -> Void
}

struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let fixTitle: String
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
            if !ok { Button(fixTitle, action: fix) }
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
    let actions: Actions
    @FocusState private var tryBoxFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            GroupBox(label: Text("Status")) { checks.padding(6) }
            GroupBox(label: Text("Try it here")) { tryIt.padding(6) }
            GroupBox(label: Text("Transcripts")) { transcripts.padding(6) }
            GroupBox(label: Text("Settings")) { settings.padding(6) }
            footer
        }
        .padding(20)
        .frame(width: 540)
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("AUDAX").font(.system(size: 22, weight: .bold))
                Text(model.statusLine).foregroundColor(.secondary)
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
            CheckRow(ok: model.cleanupOK || !model.cleanup, title: "AI clean-up",
                     detail: model.cleanup ? "Local Ollama with gemma4: punctuation, fillers, corrections."
                                           : "Switched off in Settings: you get the raw transcript.",
                     fixTitle: "Start Ollama", fix: actions.startOllama)
        }
    }

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.scratch)
                .focused($tryBoxFocused)
                .onAppear { tryBoxFocused = true }  // open AUDAX, press ⌃⌥D, talk
                .font(.body)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button(model.phase == .recording ? "Stop" : "Start dictation", action: actions.toggle)
                    .disabled(model.phase == .transcribing)
                Text("The text lands in this box. ⌃⌥D works the same in any other app.")
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
                .frame(height: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Clean up with local AI (punctuation, filler words, self-corrections)",
                   isOn: $model.cleanup)
            Picker("Stop after a pause of", selection: $model.pause) {
                Text("1 s").tag(1.0)
                Text("1.5 s").tag(1.5)
                Text("2 s").tag(2.0)
                Text("3 s").tag(3.0)
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            Text("Shortcut: ⌃⌥D (Control + Option + D). Press it again to stop at once.")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var footer: some View {
        HStack {
            Button("Open log", action: actions.openLog)
            Button("Run setup again", action: actions.runSetup)
            Spacer()
            Text("Audio and text never leave this Mac.").font(.caption).foregroundColor(.secondary)
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

    init(model: Model, actions: Actions) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "AUDAX"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: model, actions: actions))
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}
