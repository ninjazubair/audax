// AUDAX settings: kept in UserDefaults under the property names, and the Settings window that
// edits them. Opened from the main window's footer and from the menu-bar menu.
import SwiftUI

/// One correction: dictate.py replaces `wrong` (any case, any spacing) with `right`.
struct WordSub: Identifiable, Equatable {
    let id = UUID()
    var wrong: String
    var right: String
}

final class Settings: ObservableObject {
    @Published var talkKey: Shortcut {
        didSet {
            save(talkKey, as: "talkKey")
            onShortcutsChanged?()
        }
    }
    @Published var handsFreeKey: Shortcut {
        didSet {
            save(handsFreeKey, as: "handsFreeKey")
            onShortcutsChanged?()
        }
    }
    @Published var language: String {  // "en" | "de"
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var cleanup: String {  // "off" | "light" | "full"
        didSet { UserDefaults.standard.set(cleanup, forKey: "cleanup") }
    }
    @Published var sounds: Bool {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    @Published var provider: String {  // "ollama" | "copilot" | "claude" | "openai"
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    @Published var models: [String: String] {  // provider → model name
        didSet { UserDefaults.standard.set(models, forKey: "models") }
    }
    @Published var wordSubs: [WordSub] {  // the user's own corrections, in userSubsPath
        didSet { saveWordSubs() }
    }
    var wordSubsUnreadable = false  // the file exists but is not a JSON object
    var onShortcutsChanged: (() -> Void)?

    static let defaultModels = [
        "ollama": "gemma4", "copilot": "gpt-4.1", "claude": "claude-opus-5-5", "openai": "gpt-4.1"]

    init() {
        let d = UserDefaults.standard
        talkKey = Settings.shortcut(d.data(forKey: "talkKey")) ?? .talkDefault
        handsFreeKey = Settings.shortcut(d.data(forKey: "handsFreeKey")) ?? .handsFreeDefault
        language = d.string(forKey: "language") ?? "en"
        cleanup = Settings.storedCleanup(d.object(forKey: "cleanup"))
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        provider = d.string(forKey: "provider") ?? "ollama"
        let stored = d.dictionary(forKey: "models") as? [String: String] ?? [:]
        models = Settings.defaultModels.merging(stored) { $1 }
        let subs = Settings.readWordSubs()
        wordSubs = subs ?? []
        wordSubsUnreadable = subs == nil
    }

    /// nil when the file exists but is not a JSON object; [] when there is no file yet.
    static func readWordSubs() -> [WordSub]? {
        guard let data = FileManager.default.contents(atPath: userSubsPath) else { return [] }
        guard let pairs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return pairs.compactMap { wrong, right in
            guard let right = right as? String, !wrong.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return WordSub(wrong: wrong, right: right)
        }.sorted { $0.wrong.lowercased() < $1.wrong.lowercased() }
    }

    /// Replaces a pair with the same misspelling, any case; otherwise appends.
    func addWordSub(wrong: String, right: String) {
        let sub = WordSub(wrong: wrong.trimmingCharacters(in: .whitespaces),
                          right: right.trimmingCharacters(in: .whitespaces))
        if let i = wordSubs.firstIndex(where: { $0.wrong.lowercased() == sub.wrong.lowercased() }) {
            wordSubs[i] = sub
        } else {
            wordSubs.append(sub)
        }
    }

    /// dictate.py re-reads the file on every dictation, so a change applies to the next one.
    func saveWordSubs() {
        if wordSubsUnreadable {  // keep the user's hand-edited file instead of overwriting it
            // ponytail: one aside copy; a second unreadable file is overwritten if the move fails.
            try? FileManager.default.moveItem(atPath: userSubsPath,
                                              toPath: userSubsPath + ".unreadable")
            wordSubsUnreadable = false
        }
        let pairs = Dictionary(wordSubs.map { ($0.wrong, $0.right) }) { _, last in last }
        guard let data = try? JSONSerialization.data(withJSONObject: pairs,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: userSubsPath), options: .atomic)
    }

    static func shortcut(_ data: Data?) -> Shortcut? {
        data.flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    /// v1 kept clean-up as a Bool under the same key; false meant off.
    static func storedCleanup(_ value: Any?) -> String {
        switch value {
        case let level as String where ["off", "light", "full"].contains(level): return level
        case let on as Bool: return on ? "full" : "off"
        default: return "full"
        }
    }

    func save(_ shortcut: Shortcut, as key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    let actions: Actions
    @State private var wrong = ""  // the Words box's new pair
    @State private var right = ""

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Recording") { recording.padding(6) }
                GroupBox("Clean-up") { cleanupBox.padding(6) }
                GroupBox("Words") { wordsBox.padding(6) }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Hold to talk") {
                ShortcutRecorder(shortcut: $settings.talkKey, conflictsWith: settings.handsFreeKey,
                                 onRecording: actions.pauseHotKeys)
            }
            LabeledContent("Hands-free: press to start, again to finish") {
                ShortcutRecorder(shortcut: $settings.handsFreeKey, conflictsWith: settings.talkKey,
                                 onRecording: actions.pauseHotKeys)
            }
            Toggle("Sounds", isOn: $settings.sounds)
            Picker("Language", selection: $settings.language) {
                Text("English").tag("en")
                Text("German").tag("de")
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let cleanupCaptions = [
        "off": "You get the raw transcript.",
        "light": "Punctuation, filler words and self-corrections.",
        "full": "Light, plus grammar, word order and recognition errors.",
    ]

    /// Task 5 adds the provider, model and API key here.
    var cleanupBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Clean-up", selection: $settings.cleanup) {
                Text("Off").tag("off")
                Text("Light").tag("light")
                Text("Full").tag("full")
            }
            .pickerStyle(.segmented)
            Text(Self.cleanupCaptions[settings.cleanup] ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var wordsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Misspelled", text: $wrong, prompt: Text("Misspelled")).labelsHidden()
                TextField("Correct", text: $right, prompt: Text("Correct")).labelsHidden()
                Button("Add") {
                    settings.addWordSub(wrong: wrong, right: right)
                    wrong = ""
                    right = ""
                }
                .disabled(Self.blank(wrong) || Self.blank(right))
            }
            List(settings.wordSubs) { sub in
                HStack {
                    Text("\(sub.wrong) → \(sub.right)")
                    Spacer()
                    Button { settings.wordSubs.removeAll { $0.id == sub.id } } label: {
                        Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            .frame(height: 150)  // the window sizes to fit once, so the list must not grow
            Text("Built-in corrections (Workfront, RTCDP, …) stay active.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

final class SettingsWindow {
    let window: NSWindow

    init(settings: Settings, actions: Actions) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AUDAX Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings,
                                                                  actions: actions))
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}
