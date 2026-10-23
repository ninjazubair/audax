// AUDAX settings: kept in UserDefaults under the property names, and the Settings window that
// edits them. Opened from the main window's footer and from the menu-bar menu.
import SwiftUI

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

    /// Task 3 puts the clean-up level here, Task 5 the provider, model and API key.
    var cleanupBox: some View {
        Text("Clean-up options are not available yet.")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Task 4 puts the misspelling → correct word table here.
    var wordsBox: some View {
        Text("Word corrections are not available yet.")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
