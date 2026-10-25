// STUB — replaced by lane U2 at merge
// Provider facts and the clean-up config, as the shared interface (task-7-ui-briefs.md) defines
// them. Behaves as 0.3.1 for the four existing providers; the four new ones are only listed.
import Foundation

enum ProviderInfo {
    static let all: [(id: String, name: String, symbol: String, blurb: String)] = [
        ("ollama", "Local Ollama", "desktopcomputer", "On this Mac: nothing leaves it."),
        ("copilot", "GitHub Copilot", "chevron.left.forwardslash.chevron.right",
         "Your Copilot seat, through the GitHub CLI."),
        ("claude", "Claude API", "sparkle", "Anthropic, with your API key."),
        ("openai", "OpenAI API", "circle.hexagongrid", "OpenAI, with your API key."),
        ("bedrock", "Amazon Bedrock", "cloud", "AWS: API key, access key or profile."),
        ("foundry", "Microsoft Foundry", "square.stack.3d.up", "An Azure OpenAI endpoint."),
        ("openai_compatible", "Other (OpenAI-compatible)", "network",
         "Any /chat/completions endpoint."),
        ("anthropic_compatible", "Other (Anthropic-compatible)", "network",
         "Any /v1/messages endpoint."),
    ]

    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }

    /// The provider dictations use: the .env file's AUDAX_PROVIDER when set, else Settings'.
    static func active(_ settings: Settings, env: [String: String]) -> String {
        let id = env["AUDAX_PROVIDER"] ?? ""
        return id.isEmpty ? settings.provider : id
    }

    static func recipient(_ settings: Settings) -> String? {
        let provider = settings.provider
        return provider == "ollama" ? nil : Settings.recipients[provider] ?? name(provider)
    }
}

struct ProviderStatus {
    let ok: Bool
    let detail: String
    let fixTitle: String
}

func providerStatus(_ settings: Settings, model: Model) -> ProviderStatus {
    let provider = settings.provider, name = settings.models[provider] ?? ""
    switch provider {
    case "ollama":
        return ProviderStatus(ok: model.cleanupOK, detail: "Local Ollama with \(name): "
                              + "punctuation, fillers, corrections.", fixTitle: "Start Ollama")
    case "copilot":
        let detail = model.cleanupOK ? "GitHub Copilot (\(name)): text is sent to GitHub."
            : model.gitHub == .noCLI ? "GitHub CLI not found. Install it with: brew install gh"
            : "Not signed in to GitHub. Sign in, then dictate."
        return ProviderStatus(ok: model.cleanupOK, detail: detail,
                              fixTitle: model.gitHub == .noCLI ? "" : "Sign in…")
    default:
        let ok = Settings.keyProviders.contains(provider) && Keychain.has(account: provider)
        let to = ProviderInfo.recipient(settings) ?? ""
        let detail = ok ? "\(ProviderInfo.name(provider)) (\(name)): text is sent to \(to)."
            : "Needs setup in AI Provider."
        return ProviderStatus(ok: ok, detail: detail, fixTitle: "Settings…")
    }
}

/// The provider part of dictate.py's stdin, as 0.3.1 sent it. Carries the API key: never log it.
func providerConfigFields(_ settings: Settings) -> [String: Any] {
    let provider = settings.provider
    let key = Settings.keyProviders.contains(provider) ? Keychain.get(account: provider) : nil
    return ["provider": provider, "model": settings.models[provider] ?? "", "api_key": key ?? ""]
}

enum EnvFile {
    static var url: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.config/audax/.env") }
    static func values() -> [String: String] { [:] }
    static var controlsProvider: Bool { false }
    static var tooOpen: Bool { false }
    static func openOrCreateTemplate() {}
}
