// AUDAX settings: kept in UserDefaults under the property names (API keys in the Keychain), and
// the Settings window that edits them. Opened from the main window's footer and the menu-bar menu.
import Security
import SwiftUI

/// API keys, as generic passwords in the login keychain: never in UserDefaults, files, the
/// environment or the log. The stable signing identity keeps them readable across rebuilds.
enum Keychain {
    static let service = "local.audax"  // accounts: "claude", "openai"

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Whether a key is stored, without reading (decrypting) it: for the 5-second check.
    static func has(account: String) -> Bool {
        SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        _ = SecItemDelete(query(account) as CFDictionary)
    }
}

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
    var savedSubs: [String: String] = [:]  // wordSubs as last read or written
    var onShortcutsChanged: (() -> Void)?

    static let defaultModels = [
        "ollama": "gemma4", "copilot": "gpt-6.1-sol", "claude": "claude-opus-5-5",
        "openai": "gpt-4.1"]
    /// Picker order and labels.
    static let providers = [("ollama", "Local Ollama"), ("copilot", "GitHub Copilot"),
                            ("claude", "Claude API"), ("openai", "OpenAI API")]
    /// Who receives the text, for each provider that is not on this Mac.
    static let recipients = ["copilot": "GitHub", "claude": "Anthropic", "openai": "OpenAI"]
    static let keyProviders = ["claude", "openai"]  // the ones that need an API key

    static func providerName(_ provider: String) -> String {
        providers.first { $0.0 == provider }?.1 ?? provider
    }

    init() {
        let d = UserDefaults.standard
        talkKey = Settings.shortcut(d.data(forKey: "talkKey")) ?? .talkDefault
        handsFreeKey = Settings.shortcut(d.data(forKey: "handsFreeKey")) ?? .handsFreeDefault
        language = d.string(forKey: "language") ?? "en"
        cleanup = Settings.storedCleanup(d.object(forKey: "cleanup"))
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        provider = d.string(forKey: "provider") ?? "ollama"
        let stored = d.dictionary(forKey: "models") as? [String: String] ?? [:]
        models = Settings.migrateCopilotDefault(Settings.defaultModels.merging(stored) { $1 })
        wordSubs = Settings.readWordSubs() ?? []
        savedSubs = Settings.pairs(wordSubs)
    }

    /// Once per Mac: gpt-4.1 was the Copilot default until 0.2.1 and got stored with any model
    /// edit, so it becomes the new default. The flag is set either way, so a later pick of
    /// gpt-4.1 stays. Written here because didSet does not run in init.
    static func migrateCopilotDefault(_ models: [String: String]) -> [String: String] {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "copilotDefaultMigrated") else { return models }
        var out = models
        if out["copilot"] == "gpt-4.1" {
            out["copilot"] = defaultModels["copilot"]
            d.set(out, forKey: "models")
        }
        d.set(true, forKey: "copilotDefaultMigrated")
        return out
    }

    /// [] when there is no file yet; nil when it exists but cannot be read or is not a JSON
    /// object (saveWordSubs then moves it aside, never writes over it).
    static func readWordSubs() -> [WordSub]? {
        guard FileManager.default.fileExists(atPath: userSubsPath) else { return [] }
        guard let data = FileManager.default.contents(atPath: userSubsPath),
              let pairs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
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

    static func pairs(_ subs: [WordSub]) -> [String: String] {
        Dictionary(subs.map { ($0.wrong, $0.right) }) { _, last in last }
    }

    /// dictate.py re-reads the file on every dictation, so a change applies to the next one.
    /// Re-reads it first, so a hand edit made while AUDAX runs is kept: the pairs here win, and
    /// only those removed here since the last save leave the file.
    func saveWordSubs() {
        let onDisk = Settings.readWordSubs()
        if onDisk == nil, !Settings.moveAsideUnreadable() { return }  // never write over it
        let mine = Settings.pairs(wordSubs)
        let removed = Set(savedSubs.keys).subtracting(mine.keys)
        let kept = Settings.pairs(onDisk ?? []).filter { !removed.contains($0.key) }
        do {
            let data = try JSONSerialization.data(withJSONObject: kept.merging(mine) { $1 },
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: userSubsPath), options: .atomic)
            savedSubs = mine
        } catch {
            appendToLog(["warning": "word_subs.json not saved: \(error.localizedDescription)"])
        }
    }

    /// The user's unreadable file, renamed with a time stamp; false (logged) if that fails.
    static func moveAsideUnreadable() -> Bool {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let aside = userSubsPath + ".unreadable-" + stamp.string(from: Date())
        do {
            try FileManager.default.moveItem(atPath: userSubsPath, toPath: aside)
            return true
        } catch {
            appendToLog(["warning": "word_subs.json left unchanged: could not move aside"])
            return false
        }
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
    @ObservedObject var model: Model  // the GitHub sign-in state, kept fresh by refreshChecks
    let actions: Actions
    @State private var wrong = ""  // the Words box's new pair
    @State private var right = ""
    @State private var key = ""  // typed API key; cleared once saved, never stored elsewhere
    @State private var keySaved = false
    @State private var copilotModels: [CopilotModel] = []  // fetched once per Settings session
    @State private var fetchingModels = false

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
            // Fixed height, shown or not (measured: two caption lines beside the button, 26):
            // the window sizes to fit only once. A VStack, as an empty Group would collapse.
            VStack(alignment: .leading) {
                if model.globeConflict { GlobeHint(open: actions.openKeyboardSettings) }
            }
            .frame(height: 26, alignment: .topLeading)
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
            Picker("Provider", selection: $settings.provider) {
                ForEach(Settings.providers, id: \.0) { tag, label in Text(label).tag(tag) }
            }
            if settings.provider == "copilot", !copilotModels.isEmpty {
                Picker("Model", selection: modelName) {
                    ForEach(copilotOptions, id: \.id) { Text($0.name).tag($0.id) }
                }
            } else {  // other providers, and Copilot while its list loads or if it failed
                TextField("Model", text: modelName)
            }
            providerExtras
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshKey()
            fetchModels()
        }
        .onChange(of: settings.provider) {
            key = ""  // a key typed for one provider is never saved under another
            refreshKey()
            fetchModels()
        }
    }

    var modelName: Binding<String> {
        Binding(get: { settings.models[settings.provider] ?? "" },
                set: { settings.models[settings.provider] = $0 })
    }

    /// The seat's list, plus the saved id when the seat does not list it: kept, never replaced.
    var copilotOptions: [CopilotModel] {
        let saved = settings.models["copilot"] ?? ""
        return copilotModels.contains { $0.id == saved }
            ? copilotModels : copilotModels + [(id: saved, name: saved)]
    }

    /// Copilot only, once per Settings session; a failed fetch is retried on the next switch.
    func fetchModels() {
        guard settings.provider == "copilot", copilotModels.isEmpty, !fetchingModels else { return }
        fetchingModels = true
        actions.fetchCopilotModels { models in
            copilotModels = models
            fetchingModels = false
        }
    }

    /// Fixed height, so switching provider (or the Copilot list arriving) never changes the box
    /// height: the window sizes to fit only once. Measured: Copilot's two-line timing caption
    /// plus the sign-in row, 56 (the key row plus its caption is 43).
    var providerExtras: some View {
        VStack(alignment: .leading, spacing: 6) {
            if Settings.keyProviders.contains(settings.provider) {
                HStack {
                    SecureField("API key", text: $key)
                    Button("Save", action: saveKey).disabled(Self.blank(key))
                }
                HStack {  // link style at caption size: the row keeps the caption's height
                    Text(keySaved ? "Key saved" : "No key").foregroundColor(.secondary)
                    if keySaved { Button("Remove key", action: removeKey).buttonStyle(.link) }
                }
                .font(.caption)
            } else if settings.provider == "copilot" {
                Text(Self.copilotTimings).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.gitHubCaptions[model.gitHub] ?? "")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Sign in to GitHub…", action: actions.signInGitHub)
                        .disabled(model.gitHub == .noCLI)
                }
            }
        }
        .frame(height: 56, alignment: .topLeading)
    }

    static let copilotTimings = "Measured on this Mac: local gemma4 ≈0.3 s, gpt-4.1 ≈2 s, "
        + "gpt-6.1-sol ≈2.7–4.9 s per dictation."

    static let gitHubCaptions: [GitHubSignIn: String] = [
        .signedIn: "Signed in to GitHub", .signedOut: "Not signed in",
        .noCLI: "GitHub CLI not found"]

    func refreshKey() {
        keySaved = Settings.keyProviders.contains(settings.provider)
            && Keychain.has(account: settings.provider)
    }

    func saveKey() {
        do {
            try Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines),
                             account: settings.provider)
        } catch {
            appendToLog(["warning": "API key not saved: OSStatus \((error as NSError).code)"])
        }
        key = ""
        refreshKey()
    }

    func removeKey() {
        Keychain.delete(account: settings.provider)
        refreshKey()
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

    init(settings: Settings, model: Model, actions: Actions) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AUDAX Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, model: model,
                                                                  actions: actions))
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}
