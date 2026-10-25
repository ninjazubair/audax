// AUDAX window state and the pieces the panes share: the observable Model the App keeps fresh,
// the Actions the views call back with, recent dictations read from the log, and small shared
// views (setup rows, keycaps, cards). The window itself is in MainWindow.swift.
import SwiftUI

struct Recent: Identifiable {
    let id = UUID()
    let day: String  // "2026-10-24", for History's day sections
    let time: String  // "12:05"
    let text: String
    let raw: String  // what Whisper heard, before the AI clean-up
    let caption: String  // "Local Ollama · speech 0.17 s · clean-up 0.31 s", or ""
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
    @Published var pane = Pane.home  // the window's sidebar selection
    @Published var seconds = 0  // whole seconds of the current recording, for the toolbar

    var ready: Bool { micOK && pasteOK && engineOK }
}

struct Actions {
    let toggle: () -> Void
    let allowMic: () -> Void
    let allowPaste: () -> Void
    let runSetup: () -> Void
    let signInGitHub: () -> Void
    let startOllama: () -> Void
    let openLog: () -> Void
    let openSettings: () -> Void  // the window on Dictation
    let pauseHotKeys: (Bool) -> Void  // true while a shortcut recorder listens
    let openKeyboardSettings: () -> Void
    let fetchCopilotModels: (@escaping ([CopilotModel]) -> Void) -> Void  // App's; [] = failed
    /// providers.py --test in the background; calls back on main with "OK (N ms)" or the error.
    let testConnection: (@escaping (String) -> Void) -> Void
    let openEnvFile: () -> Void
}

/// "0:07", "1:23".
func clockText(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// A rounded panel on the window background, the Home pane's building block.
struct Card: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(Card(padding: padding)) }
}

/// A row with a coloured symbol tile, a title, a detail line and something on the right.
struct IconRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7,
                                                                style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// A requirement: green when met, red with its fix button when not.
struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let fixTitle: String  // "" for no fix button
    let fix: () -> Void
    var symbol = "checkmark"

    var body: some View {
        IconRow(symbol: symbol, tint: ok ? .green : .red, title: title, detail: detail) {
            if !ok && !fixTitle.isEmpty { Button(fixTitle, action: fix) }
        }
    }
}

/// Shown while a Fn-only shortcut competes with macOS's own action for the Fn (Globe) key.
struct GlobeHint: View {
    let open: () -> Void

    var body: some View {
        IconRow(symbol: "globe", tint: .orange, title: "Globe key",
                detail: "macOS also uses Fn: set 'Press 🌐 key to' to Do Nothing.") {
            Button("Open Keyboard settings", action: open)
        }
    }
}

/// One key of a shortcut, drawn as a keycap.
struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 0, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A shortcut as keycaps: "Fn Space" → [Fn] [Space], "⌃⌥D" → [⌃] [⌥] [D].
struct ShortcutKeys: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keycapParts(shortcut.display).enumerated()), id: \.offset) {
                Keycap(label: $0.element)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.display)
    }
}

/// Splits Shortcut.display into keys: a leading "Fn", each modifier mark, then the key name.
func keycapParts(_ display: String) -> [String] {
    var rest = Substring(display), parts: [String] = []
    if rest.hasPrefix("Fn") {
        parts.append("Fn")
        rest = rest.dropFirst(2).drop { $0 == " " }
    }
    while let mark = rest.first, "⌃⌥⇧⌘".contains(mark) {
        parts.append(String(mark))
        rest = rest.dropFirst()
    }
    if !rest.isEmpty { parts.append(String(rest)) }
    return parts
}

/// The shortcut recorder's button drawn as a keycap field.
struct KeycapFieldStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 0.5, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
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

/// Reads the most recent successful dictations from the log, newest first.
func loadRecent(limit: Int = 200) -> [Recent] {
    guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
    var items: [Recent] = []
    for line in text.split(separator: "\n").reversed() where items.count < limit {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let final = entry["final"] as? String, !final.isEmpty else { continue }
        let at = entry["at"] as? String ?? ""
        items.append(Recent(day: String(at.prefix(10)), time: String(at.suffix(8).prefix(5)),
                            text: final, raw: entry["raw"] as? String ?? "",
                            caption: logCaption(entry)))
    }
    return items
}

/// "Local Ollama · speech 0.17 s · clean-up 0.31 s" from a dictation's log entry; parts that
/// are missing are left out (older entries have no timings).
func logCaption(_ entry: [String: Any]) -> String {
    var parts: [String] = []
    if let provider = entry["provider"] as? String { parts.append(ProviderInfo.name(provider)) }
    if let stt = entry["stt_s"] as? Double { parts.append(String(format: "speech %.2f s", stt)) }
    if entry["level"] as? String == "off" {
        parts.append("clean-up off")
    } else if let llm = entry["llm_s"] as? Double {
        parts.append(String(format: "clean-up %.2f s", llm))
    }
    return parts.joined(separator: " · ")
}
