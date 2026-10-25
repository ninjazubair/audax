// AI clean-up providers: the eight AUDAX knows, what dictate.py gets on stdin for the one in use
// (Settings plus Keychain; dictate.py then lays ~/.config/audax/.env over it, key by key), the
// check row's status, and a read-only view of that .env file. AIProviderView.swift edits it.
import AppKit
import UniformTypeIdentifiers

/// One secret a provider needs, kept in the Keychain (service local.audax) under `account`.
struct ProviderSecret {
    let field: String  // its key in the config JSON
    let account: String
    let label: String
    let optional: Bool
}

enum ProviderInfo {
    /// Spec order. Symbols are generic SF Symbols, never brand marks.
    static let all: [(id: String, name: String, symbol: String, blurb: String)] = [
        ("ollama", "Local Ollama", "desktopcomputer", "Runs on this Mac. Nothing leaves it."),
        ("copilot", "GitHub Copilot", "chevron.left.forwardslash.chevron.right",
         "Your Copilot seat, via the GitHub CLI."),
        ("claude", "Claude API", "text.bubble.fill", "Anthropic's API with your own key."),
        ("openai", "OpenAI API", "circle.hexagongrid.fill", "OpenAI's API with your own key."),
        ("bedrock", "Amazon Bedrock", "cloud.fill", "Models in your own AWS account."),
        ("foundry", "Microsoft Foundry", "building.2.fill", "Azure OpenAI model deployments."),
        ("openai_compatible", "Other (OpenAI-compatible)", "server.rack",
         "Any gateway with /chat/completions."),
        ("anthropic_compatible", "Other (Anthropic-compatible)",
         "point.3.connected.trianglepath.dotted", "Any gateway with /v1/messages."),
    ]

    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
    static func known(_ id: String) -> Bool { all.contains { $0.id == id } }

    /// The key-based providers whose endpoint the user sets (base URL, header style, version).
    static let gateways = ["foundry", "openai_compatible", "anthropic_compatible"]

    /// Who receives the text for the provider dictations use; nil when it stays on this Mac.
    /// Needs no secret, so it never asks the Keychain (it runs in view bodies).
    static func recipient(_ settings: Settings) -> String? {
        let env = EnvFile.values()
        return recipient(effective(settings, id: active(settings, env: env), env: env,
                                   stored: { _ in false }))
    }

    static func recipient(_ cfg: [String: String]) -> String? {
        switch cfg["provider"] ?? "" {
        case "ollama": return nil
        case "copilot": return "GitHub"
        case "claude": return "Anthropic"
        case "openai": return "OpenAI"
        case "bedrock": return "Amazon Bedrock"
        case "foundry": return "Microsoft Foundry"
        case let id where !known(id): return nil  // an id from the .env: clean-up is skipped
        default:  // the two gateways
            return URL(string: cfg["base_url"] ?? "")?.host ?? "the server at your base URL"
        }
    }

    /// The provider dictations use: the .env file's AUDAX_PROVIDER when set, else Settings'.
    static func active(_ settings: Settings, env: [String: String]) -> String {
        EnvFile.nonEmpty(env["AUDAX_PROVIDER"]) ?? settings.provider
    }

    /// Bedrock's sign-in method: "api_key" (default), "access_key" or "profile".
    static func awsAuth(_ settings: Settings) -> String {
        EnvFile.nonEmpty(settings.advanced["bedrock"]?["aws_auth"]) ?? "api_key"
    }

    static func secrets(_ id: String, awsAuth: String) -> [ProviderSecret] {
        switch (id, awsAuth) {
        case ("claude", _), ("openai", _), ("foundry", _), ("openai_compatible", _),
             ("anthropic_compatible", _):
            return [ProviderSecret(field: "api_key", account: id, label: "API key",
                                   optional: false)]
        case ("bedrock", "access_key"):
            return [
                ProviderSecret(field: "aws_access_key_id", account: "bedrock_access_key_id",
                               label: "Access key ID", optional: false),
                ProviderSecret(field: "aws_secret_access_key",
                               account: "bedrock_secret_access_key",
                               label: "Secret access key", optional: false),
                ProviderSecret(field: "aws_session_token", account: "bedrock_session_token",
                               label: "Session token", optional: true)]
        case ("bedrock", "profile"):
            return []  // the keys stay in ~/.aws, read by dictate.py
        case ("bedrock", _):
            return [ProviderSecret(field: "api_key", account: "bedrock", label: "Bedrock API key",
                                   optional: false)]
        default:
            return []  // ollama runs locally; copilot asks gh for its token
        }
    }

    /// Every Keychain account the providers use, for one presence check per screen visit.
    static let accounts = ["claude", "openai", "bedrock", "bedrock_access_key_id",
                           "bedrock_secret_access_key", "bedrock_session_token", "foundry",
                           "openai_compatible", "anthropic_compatible"]

    static let configKeys = ["provider", "model", "api_key", "base_url", "auth_header",
                             "api_version", "region", "aws_auth", "aws_access_key_id",
                             "aws_secret_access_key", "aws_session_token", "aws_profile"]
    static let advancedKeys = ["base_url", "auth_header", "api_version", "region", "aws_profile"]

    /// Provider `id`'s config as Settings holds it, every key present. `secret` gives the value
    /// for a Keychain account: the secret itself for dictate.py, a marker for a presence check.
    static func fields(_ settings: Settings, id: String,
                       secret: (String) -> String) -> [String: String] {
        var cfg = Dictionary(uniqueKeysWithValues: configKeys.map { ($0, "") })
        cfg["provider"] = id
        cfg["model"] = settings.models[id] ?? ""
        let stored = settings.advanced[id] ?? [:]
        for key in advancedKeys { cfg[key] = stored[key] ?? "" }
        if id == "bedrock" { cfg["aws_auth"] = awsAuth(settings) }
        for s in secrets(id, awsAuth: cfg["aws_auth"] ?? "") { cfg[s.field] = secret(s.account) }
        return cfg
    }

    /// `id`'s config as dictate.py will see it, secrets only as present or absent: Settings and
    /// Keychain, then the .env laid over. The .env's provider choice is `active`'s business.
    static func effective(_ settings: Settings, id: String, env: [String: String],
                          stored: (String) -> Bool) -> [String: String] {
        let cfg = fields(settings, id: id) { stored($0) ? "set" : "" }
        return EnvFile.overlay(cfg, env.filter { $0.key != "AUDAX_PROVIDER" })
    }

    /// The first required field still empty, as the screen names it; nil when complete.
    static func missing(_ cfg: [String: String]) -> String? { missingAll(cfg).first }

    /// Every required field still empty, in the order of providers.py's `need` calls.
    static func missingAll(_ cfg: [String: String]) -> [String] {
        let id = cfg["provider"] ?? ""
        var need: [(key: String, label: String)] = []
        switch id {
        case "claude", "openai": need = [("api_key", "API key")]
        case "foundry", "openai_compatible", "anthropic_compatible":
            need = [("base_url", "base URL"), ("model", id == "foundry" ? "deployment" : "model"),
                    ("api_key", "API key")]
        case "bedrock": need = bedrockNeeds(cfg["aws_auth"] ?? "")
        default: return []
        }
        return need.filter { (cfg[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.label }
    }

    /// A profile may bring its own region from ~/.aws/config, so only the other two need one.
    static func bedrockNeeds(_ auth: String) -> [(key: String, label: String)] {
        switch auth {
        case "access_key":
            return [("model", "model ID"), ("aws_access_key_id", "access key ID"),
                    ("aws_secret_access_key", "secret access key"), ("region", "region")]
        case "profile": return [("model", "model ID")]
        default:
            return [("model", "model ID"), ("api_key", "Bedrock API key"), ("region", "region")]
        }
    }

    /// Speed per dictation, only where it was measured: the figures of the Copilot caption that
    /// Settings showed until 0.3.1. Nothing was measured for the others, so none is claimed.
    static func speedHint(_ id: String) -> String {
        switch id {
        case "ollama":
            return "Fastest: gemma4 ≈0.3 s per dictation, measured on the developer's Mac."
        case "copilot":
            return "gpt-4.1 ≈2 s, gpt-6.1-sol ≈2.7–4.9 s per dictation, measured on the "
                + "developer's Mac."
        default: return "Not measured yet: it depends on the model and where it runs. Test "
            + "connection shows one round trip."
        }
    }
}

struct ProviderStatus {
    let ok: Bool
    let detail: String
    let fixTitle: String  // "" for no fix button
}

/// The "AI clean-up" check row. Ollama's and Copilot's answers come from App's probes (in
/// `model`); the key-based providers are complete when their required fields are set in Settings,
/// the Keychain or the .env.
func providerStatus(_ settings: Settings, model: Model) -> ProviderStatus {
    if settings.cleanup == "off" {
        return ProviderStatus(ok: true, detail: "Switched off in Settings: you get the raw "
                              + "transcript.", fixTitle: "")
    }
    let env = EnvFile.values()
    let id = ProviderInfo.active(settings, env: env)
    let cfg = ProviderInfo.effective(settings, id: id, env: env,
                                     stored: { Keychain.has(account: $0) })
    let name = ProviderInfo.name(id), modelName = cfg["model"] ?? ""
    switch id {
    case "ollama":
        return ProviderStatus(ok: model.cleanupOK, detail: "Local Ollama with \(modelName): "
                              + "punctuation, fillers, corrections.", fixTitle: "Start Ollama")
    case "copilot" where model.gitHub == .noCLI:
        return ProviderStatus(ok: false, detail: "GitHub CLI not found. Install it with: brew "
                              + "install gh", fixTitle: "")
    case "copilot" where model.gitHub == .signedOut:
        return ProviderStatus(ok: false, detail: "Not signed in to GitHub. Sign in, then dictate.",
                              fixTitle: "Sign in…")
    case _ where !ProviderInfo.known(id):
        return ProviderStatus(ok: false, detail: "~/.config/audax/.env names a provider AUDAX does "
                              + "not know: \(id)", fixTitle: "")
    default:
        if let field = ProviderInfo.missing(cfg) {
            return ProviderStatus(ok: false, detail: "\(name) needs setup in AI Provider: \(field) "
                                  + "is not set.", fixTitle: "Settings…")
        }
    }
    let to = ProviderInfo.recipient(cfg) ?? "this Mac"
    return ProviderStatus(ok: true, detail: "\(name) (\(modelName)): text is sent to \(to).",
                          fixTitle: "")
}

/// What App.configJSON merges for dictate.py and providers.py --test. The provider is the one
/// dictations use (the .env's when it names one), so a key saved for one provider never goes to
/// another provider's endpoint. Only that provider's secrets are read. Never logged.
func providerConfigFields(_ settings: Settings) -> [String: Any] {
    let id = ProviderInfo.active(settings, env: EnvFile.values())
    return ProviderInfo.fields(settings, id: id) { Keychain.get(account: $0) ?? "" }
}

/// ~/.config/audax/.env, read the way providers.py reads it. AUDAX never edits or overwrites it:
/// it only creates the commented template when the file is missing.
enum EnvFile {
    static var url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/audax/.env")

    /// The file's KEY=VALUE pairs; [:] when it is missing, unreadable or not UTF-8. Holds
    /// secrets: never logged, never passed on.
    static func values() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// The .env grammar shared with providers.load_env_file (env_line, env_value), step by step:
    /// - UTF-8, one leading BOM dropped; lines end at LF, CRLF or CR. Blanks are space and tab.
    /// - A line is trimmed of blanks; one that starts with # is a comment.
    /// - "export" plus blanks is dropped from its start; then KEY=VALUE splits at the first "=",
    ///   both trimmed. No "=" or an empty key: the line is ignored.
    /// - A VALUE in ' or " runs to the next same quote; after it only blanks or a # comment may
    ///   follow. Anything else after it, or no closing quote: the line is ignored.
    /// - Unquoted: it ends before the first blank followed by #, trimmed. So `A=pa#ss` keeps
    ///   its #, and so does `A= # note` (the value is "# note": the blank goes with the "=").
    /// - No escapes, no variable expansion. A repeated key: the last one wins.
    static func parse(_ text: String) -> [String: String] {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var env: [String: String] = [:]
        let lines = body.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"  // CRLF is one Character in Swift
        }
        for line in lines {
            if let (key, value) = pair(line) { env[key] = value }
        }
        return env
    }

    static func blank(_ c: Character) -> Bool { c == " " || c == "\t" }

    static func trim(_ text: Substring) -> Substring {
        guard let first = text.firstIndex(where: { !blank($0) }),
              let last = text.lastIndex(where: { !blank($0) }) else { return "" }
        return text[first...last]
    }

    static func pair(_ raw: Substring) -> (String, String)? {
        var line = trim(raw)
        if line.hasPrefix("#") { return nil }
        if line.hasPrefix("export"), let next = line.dropFirst(6).first, blank(next) {
            line = line.dropFirst(6).drop(while: blank)
        }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = trim(line[..<eq])
        guard !key.isEmpty, let value = value(trim(line[line.index(after: eq)...])) else {
            return nil
        }
        return (String(key), value)
    }

    /// A trimmed VALUE as `parse` reads it; nil when the line is to be ignored.
    static func value(_ text: Substring) -> String? {
        if let quote = text.first, quote == "\"" || quote == "'" {
            guard let end = text.dropFirst().firstIndex(of: quote) else { return nil }
            let rest = text[text.index(after: end)...].drop(while: blank)
            guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
            return String(text[text.index(after: text.startIndex)..<end])
        }
        var previous: Character = "x"  // a # first in the value is part of it
        let comment = text.firstIndex { c in
            defer { previous = c }
            return c == "#" && blank(previous)
        }
        return String(trim(text[..<(comment ?? text.endIndex)]))
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    static var controlsProvider: Bool { nonEmpty(values()["AUDAX_PROVIDER"]) != nil }

    /// Readable by group or others: the file usually holds keys.
    static var tooOpen: Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attrs?[.posixPermissions] as? Int else { return false }
        return mode & 0o044 != 0
    }

    static let generic = [("AUDAX_PROVIDER", "provider"), ("AUDAX_MODEL", "model"),
                          ("AUDAX_BASE_URL", "base_url"), ("AUDAX_API_KEY", "api_key"),
                          ("AUDAX_AUTH_HEADER", "auth_header"),
                          ("AUDAX_API_VERSION", "api_version")]
    static let perProvider: [String: [(String, String)]] = [
        "foundry": [("AZURE_OPENAI_ENDPOINT", "base_url"), ("AZURE_OPENAI_API_KEY", "api_key"),
                    ("AZURE_OPENAI_API_VERSION", "api_version")],
        "openai": [("OPENAI_API_KEY", "api_key")],
        "openai_compatible": [("OPENAI_API_KEY", "api_key"), ("OPENAI_BASE_URL", "base_url")],
        "claude": [("ANTHROPIC_API_KEY", "api_key")],
        "anthropic_compatible": [("ANTHROPIC_API_KEY", "api_key"),
                                 ("ANTHROPIC_BASE_URL", "base_url")],
        "bedrock": [("AWS_DEFAULT_REGION", "region"), ("AWS_REGION", "region")],  // AWS_REGION wins
    ]
    static let awsKeys = [("AWS_ACCESS_KEY_ID", "aws_access_key_id"),
                          ("AWS_SECRET_ACCESS_KEY", "aws_secret_access_key"),
                          ("AWS_SESSION_TOKEN", "aws_session_token")]

    /// providers.apply_env: the non-empty generic keys, then the resulting provider's own keys.
    static func overlay(_ cfg: [String: String], _ env: [String: String]) -> [String: String] {
        var out = cfg
        func put(_ pairs: [(String, String)]) {
            for (name, field) in pairs { if let v = nonEmpty(env[name]) { out[field] = v } }
        }
        put(generic)
        let provider = out["provider"] ?? ""
        put(perProvider[provider] ?? [])
        guard provider == "bedrock" else { return out }
        let keyNames = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]  // a lone session token: no
        let keys = keyNames.contains { nonEmpty(env[$0]) != nil }
        if let token = nonEmpty(env["AWS_BEARER_TOKEN_BEDROCK"]) {
            out["api_key"] = token
            out["aws_auth"] = "api_key"
        } else if keys {
            // One unit from one source: an ID from the file never pairs with a saved secret.
            for (name, field) in awsKeys { out[field] = nonEmpty(env[name]) ?? "" }
            out["aws_auth"] = "access_key"
        } else if let profile = nonEmpty(env["AWS_PROFILE"]) {
            out["aws_profile"] = profile
            out["aws_auth"] = "profile"
        }
        return out
    }

    static let fieldNames = [
        "model": "model", "api_key": "API key", "base_url": "base URL",
        "auth_header": "header style", "api_version": "API version", "region": "region",
        "aws_access_key_id": "access key ID", "aws_secret_access_key": "secret access key",
        "aws_session_token": "session token", "aws_profile": "AWS profile",
        "aws_auth": "sign-in method"]

    /// The config keys the .env sets for provider `id`, in config-key order.
    static func setKeys(for id: String, env: [String: String]) -> [String] {
        let set = overlay(["provider": id], env.filter { $0.key != "AUDAX_PROVIDER" })
        return ProviderInfo.configKeys.filter { $0 != "provider" && set[$0] != nil }
    }

    /// The same, as the screen names them.
    static func setFields(for id: String, env: [String: String]) -> [String] {
        setKeys(for: id, env: env).compactMap { fieldNames[$0] }
    }

    /// Creates the commented template (0600, folder 0700) only when no file exists, then opens
    /// the file in the default text editor. O_EXCL: an existing file is never written.
    static func openOrCreateTemplate() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try? file.write(contentsOf: Data(template.utf8))  // throws, never raises
            try? file.close()
        } else if errno != EEXIST {
            let why = String(cString: strerror(errno))
            return appendToLog(["warning": ".env template not created: \(why)"])
        }
        let ws = NSWorkspace.shared
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let editor = ws.urlForApplication(toOpen: UTType.plainText) ?? textEdit
        ws.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Every line a comment: creating the file changes nothing until the user edits it.
    static let template = """
        # AUDAX clean-up settings. A non-empty value here overrides AUDAX's own settings, key by
        # key, on the next dictation. Remove the "# " in front of a line to use it. A value with
        # spaces or a # in it goes in quotes. Keep this file private: chmod 600.
        #
        # Provider: ollama, copilot, claude, openai, bedrock, foundry, openai_compatible or
        # anthropic_compatible.
        # AUDAX_PROVIDER=bedrock
        # AUDAX_MODEL=
        # AUDAX_BASE_URL=
        # AUDAX_API_KEY=
        # Header style for foundry and the two compatible providers: bearer, api-key, x-api-key.
        # AUDAX_AUTH_HEADER=
        # AUDAX_API_VERSION=

        # Amazon Bedrock: a Bedrock API key, or an access key, or a profile in ~/.aws.
        # AWS_REGION=
        # AWS_BEARER_TOKEN_BEDROCK=
        # AWS_ACCESS_KEY_ID=
        # AWS_SECRET_ACCESS_KEY=
        # AWS_SESSION_TOKEN=
        # AWS_PROFILE=

        # Microsoft Foundry, e.g. https://<resource>.openai.azure.com/openai/v1
        # AZURE_OPENAI_ENDPOINT=
        # AZURE_OPENAI_API_KEY=
        # AZURE_OPENAI_API_VERSION=

        # OpenAI API and OpenAI-compatible gateways
        # OPENAI_API_KEY=
        # OPENAI_BASE_URL=

        # Claude API and Anthropic-compatible gateways
        # ANTHROPIC_API_KEY=
        # ANTHROPIC_BASE_URL=

        """
}
