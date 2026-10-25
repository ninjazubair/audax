// AUDAX settings: kept in UserDefaults under the property names (API keys in the Keychain).
// The window's Dictation, AI Provider and Words panes edit them.
import Security
import SwiftUI

/// API keys, as generic passwords in the login keychain: never in UserDefaults, files, the
/// environment or the log. The stable signing identity keeps them readable across rebuilds.
enum Keychain {
    static let service = "local.audax"  // accounts: ProviderInfo.accounts

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
    @Published var provider: String {  // an id of ProviderInfo.all, e.g. "ollama"
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    @Published var models: [String: String] {  // provider → model name
        didSet { UserDefaults.standard.set(models, forKey: "models") }
    }
    /// provider → its endpoint fields: base_url, auth_header, api_version (Foundry and the
    /// compatible gateways); region, aws_auth, aws_profile (Bedrock). Secrets: the Keychain.
    @Published var advanced: [String: [String: String]] {
        didSet { UserDefaults.standard.set(advanced, forKey: "advanced") }
    }
    @Published var wordSubs: [WordSub] {  // the user's own corrections, in userSubsPath
        didSet { saveWordSubs() }
    }
    var savedSubs: [String: String] = [:]  // wordSubs as last read or written
    var onShortcutsChanged: (() -> Void)?

    static let defaultModels = [
        "ollama": "gemma4", "copilot": "gpt-6.1-sol", "claude": "claude-opus-5-5",
        "openai": "gpt-4.1"]

    init() {
        let d = UserDefaults.standard
        talkKey = Settings.shortcut(d.data(forKey: "talkKey")) ?? .talkDefault
        handsFreeKey = Settings.shortcut(d.data(forKey: "handsFreeKey")) ?? .handsFreeDefault
        language = d.string(forKey: "language") ?? "en"
        cleanup = Settings.storedCleanup(d.object(forKey: "cleanup"))
        // bool(forKey:), not `as? Bool`: a launch argument (-sounds NO) arrives as the string "NO".
        sounds = d.object(forKey: "sounds") == nil ? true : d.bool(forKey: "sounds")
        provider = d.string(forKey: "provider") ?? "ollama"
        let stored = d.dictionary(forKey: "models") as? [String: String] ?? [:]
        models = Settings.migrateCopilotDefault(Settings.defaultModels.merging(stored) { $1 })
        advanced = d.dictionary(forKey: "advanced") as? [String: [String: String]] ?? [:]
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
