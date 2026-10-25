// AI Provider screen: choose who cleans up the transcript, set its model, keys (Keychain) and
// endpoint, test the connection, and see what the ~/.config/audax/.env file overrides.
import SwiftUI

struct AIProviderView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var model: Model  // GitHub sign-in and Ollama state, kept fresh by App
    let actions: Actions
    /// Whether the Keychain holds an account, without reading it. A seam for the offscreen
    /// renders, which must not touch the real Keychain.
    var keyStored: (String) -> Bool = { Keychain.has(account: $0) }

    @State private var drafts: [String: String] = [:]  // typed secrets by account, until saved
    @State private var stored: Set<String> = []  // accounts with a saved secret
    @State private var removing: ProviderSecret?  // Remove asks first: it deletes the secret
    @State private var copilotModels: [CopilotModel] = []  // fetched once per screen visit
    @State private var fetchingModels = false
    @State private var advancedOpen = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var env: [String: String] = [:]  // the .env's values; secrets stay in memory
    @State private var envExists = false
    @State private var envTooOpen = false

    /// Every field column on the screen is this wide, so all fields start at the same x.
    static let fieldWidth: CGFloat = 340

    var id: String { settings.provider }
    var secrets: [ProviderSecret] {
        ProviderInfo.secrets(id, awsAuth: ProviderInfo.awsAuth(settings))
    }
    /// The selected provider as dictate.py would see it, with this screen's view of the Keychain.
    var cfg: [String: String] {
        ProviderInfo.effective(settings, id: id, env: env, stored: { stored.contains($0) })
    }
    var activeID: String { ProviderInfo.active(settings, env: env) }
    var envProvider: String? { EnvFile.nonEmpty(env["AUDAX_PROVIDER"]) }
    var envKeys: [String] { EnvFile.setKeys(for: id, env: env) }
    var envFields: [String] { EnvFile.setFields(for: id, env: env) }
    var showsEnvBanner: Bool { envProvider != nil || !envFields.isEmpty }
    var keyBased: Bool { id != "ollama" && id != "copilot" }
    var missing: [String] { keyBased ? ProviderInfo.missingAll(cfg) : [] }
    var hasAdvanced: Bool { id == "bedrock" || ProviderInfo.gateways.contains(id) }

    var body: some View {
        Form {
            if settings.cleanup == "off" { offNotice }
            if showsEnvBanner || envTooOpen { envSection }
            Section("Provider") {
                ProviderGrid(selection: $settings.provider,
                             envChoice: activeID != id ? activeID : nil)
            }
            detailSection
            if !secrets.isEmpty { credentialsSection }
            if hasAdvanced { advancedSection }
            connectionSection
            if !showsEnvBanner { envFileSection }
        }
        .formStyle(.grouped)
        .confirmationDialog(removeTitle, isPresented: removeAsked, presenting: removing) { secret in
            Button("Remove", role: .destructive) { remove(secret) }
        } message: { _ in
            Text("Dictations cannot use it until you paste it again.")
        }
        .onAppear(perform: reload)
        .onChange(of: settings.provider) { providerChanged() }
        .onChange(of: model.gitHub) { gitHubChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            _ in reloadEnv()  // back from editing the .env
        }
    }

    // MARK: Sections

    var offNotice: some View {
        Section {
            Notice(symbol: "info.circle.fill", tint: .secondary, title: "Clean-up is off",
                   detail: "You get the raw transcript and no text is sent anywhere. Turn it on "
                       + "in Dictation; the provider below is used then.")
        }
    }

    var envSection: some View {
        Section {
            if showsEnvBanner {
                Notice(symbol: "doc.text.fill", tint: .blue, title: envTitle, detail: envDetail) {
                    Button("Open .env file", action: openEnv)
                }
            }
            if envTooOpen {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Other users on this Mac can read the .env file",
                       detail: "It may hold keys. In Terminal: chmod 600 ~/.config/audax/.env")
            }
        }
    }

    var envTitle: String {
        envProvider != nil ? "Provider and values come from ~/.config/audax/.env"
            : "Some values come from ~/.config/audax/.env"
    }

    var envDetail: String {
        var parts: [String] = []
        if let chosen = envProvider { parts.append(Self.envChoiceText(chosen, selected: id)) }
        if !envFields.isEmpty {
            parts.append("Set there for \(ProviderInfo.name(id)): "
                         + envFields.joined(separator: ", ") + ". They win over this page.")
        }
        return parts.joined(separator: " ")
    }

    static func envChoiceText(_ chosen: String, selected: String) -> String {
        if !ProviderInfo.known(chosen) {
            return "It names a provider AUDAX does not know (\(chosen)): dictations are pasted "
                + "without clean-up."
        }
        if chosen == selected { return "It selects \(ProviderInfo.name(chosen)) for dictations." }
        return "Dictations use \(ProviderInfo.name(chosen)), as the file says; the choice here "
            + "applies when it names no provider."
    }

    var detailSection: some View {
        Section {
            modelRow
            if id == "copilot" { gitHubRow }
            if id == "ollama" { ollamaRow }
            Label(ProviderInfo.speedHint(id), systemImage: "gauge.with.dots.needle.33percent")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            HStack(spacing: 8) {
                Text(ProviderInfo.name(id))
                Spacer(minLength: 8)
                if keyBased { SetupBadge(ready: missing.isEmpty) }
            }
        } footer: {
            if !missing.isEmpty {
                Label("Still needed: " + missing.joined(separator: ", ") + ".",
                      systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var modelRow: some View {
        if id == "copilot", !copilotModels.isEmpty {
            Picker("Model", selection: modelName) {
                ForEach(copilotOptions, id: \.id) { Text($0.name).tag($0.id) }
            }
        } else {  // the others, and Copilot while its list loads or if it failed
            LabeledContent(Self.modelLabels[id] ?? "Model") {
                HStack(spacing: 8) {
                    if fetchingModels && id == "copilot" { ProgressView().controlSize(.small) }
                    TextField("Model", text: modelName, prompt: Text(Self.modelPrompts[id] ?? ""))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                }
                .frame(width: Self.fieldWidth)
            }
        }
    }

    var gitHubRow: some View {
        LabeledContent("GitHub") {
            HStack(spacing: 8) {
                StatusText(ok: model.gitHub == .signedIn,
                           text: Self.gitHubCaptions[model.gitHub] ?? "")
                if model.gitHub != .signedIn {
                    Button("Sign in…", action: actions.signInGitHub)
                        .disabled(model.gitHub == .noCLI)
                }
            }
        }
    }

    var ollamaRow: some View {
        let name = settings.models["ollama"] ?? ""
        return LabeledContent("Ollama") {
            HStack(spacing: 8) {
                StatusText(ok: model.cleanupOK, text: model.cleanupOK ? "Running with \(name)"
                           : "Not running, or \(name) is not downloaded")
                if !model.cleanupOK { Button("Open Ollama", action: actions.startOllama) }
            }
        }
    }

    var credentialsSection: some View {
        Section {
            ForEach(secrets, id: \.account) { secret in
                SecretRow(secret: secret, draft: draft(secret.account),
                          stored: stored.contains(secret.account),
                          fromEnv: envKeys.contains(secret.field), save: save,
                          remove: { removing = $0 })
            }
            if id == "bedrock" {
                Text(ProviderInfo.awsAuth(settings) == "access_key"
                     ? "Signs in with an access key. Other methods: Advanced."
                     : "Signs in with a Bedrock API key. Access keys and AWS profiles: Advanced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text("Keys stay in your login Keychain: never in files, the log or the environment.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// A toggle row, then the fields as ordinary form rows: a DisclosureGroup inside a grouped
    /// form packs its children against the toggle without row spacing.
    var advancedSection: some View {
        Section {
            AdvancedToggle(open: $advancedOpen, summary: advancedSummary)
            if advancedOpen && id == "bedrock" {
                BedrockFields(region: advanced("region"), auth: advanced("aws_auth"),
                              profile: advanced("aws_profile"))
            } else if advancedOpen {
                GatewayFields(id: id, baseURL: advanced("base_url"),
                              header: advanced("auth_header"), version: advanced("api_version"))
            }
        }
    }

    /// What Advanced holds (the .env included), shown while it is closed.
    var advancedSummary: String {
        let cfg = self.cfg
        if id == "bedrock" && cfg["aws_auth"] == "profile" {
            let profile = EnvFile.nonEmpty(cfg["aws_profile"]) ?? "default"
            let region = EnvFile.nonEmpty(cfg["region"]) ?? "from the profile"
            return "AWS profile \(profile) · region \(region)"
        } else if id == "bedrock" {
            let method = cfg["aws_auth"] == "access_key" ? "access key" : "API key"
            let region = EnvFile.nonEmpty(cfg["region"]) ?? "not set"
            return "Region \(region) · signs in with \(method)"
        }
        let host = URL(string: cfg["base_url"] ?? "")?.host
        return host.map { "Base URL: \($0)" } ?? "Base URL not set"
    }

    var connectionSection: some View {
        Section {
            ConnectionRow(testing: testing, result: testResult, unsaved: hasUnsavedDraft,
                          testsOther: activeID != id ? ProviderInfo.name(activeID) : nil,
                          test: test)
        } header: {
            Text("Connection")
        } footer: {
            Label(privacyLine, systemImage: recipient == nil ? "lock.fill"
                  : "arrow.up.forward.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Where dictations send text: the provider in use, which is the .env's when it names one.
    var recipient: String? {
        guard settings.cleanup != "off" else { return nil }
        return ProviderInfo.recipient(activeID == id ? cfg : ProviderInfo.effective(
            settings, id: activeID, env: env, stored: { stored.contains($0) }))
    }

    var privacyLine: String {
        if settings.cleanup == "off" {
            return "Clean-up is off: audio and text never leave this Mac."
        }
        guard let to = recipient else { return "Audio and text never leave this Mac." }
        return "Audio stays on this Mac. Text is sent to \(to) for clean-up."
    }

    var envFileSection: some View {
        Section("Configuration file") {
            LabeledContent {
                Button("Open .env file", action: openEnv)
            } label: {
                Text("~/.config/audax/.env")
                Text(envExists ? "Values set there win over this page, key by key."
                     : "Optional. AUDAX creates a commented template you can fill in.")
            }
        }
    }

    // MARK: Bindings and state

    var modelName: Binding<String> {
        Binding(get: { settings.models[id] ?? "" }, set: { settings.models[id] = $0 })
    }

    /// One field of the selected provider's Advanced values; empty clears it.
    func advanced(_ key: String) -> Binding<String> {
        let provider = id
        return Binding(get: { settings.advanced[provider]?[key] ?? "" }, set: { value in
            var fields = settings.advanced[provider] ?? [:]
            fields[key] = value.isEmpty ? nil : value
            settings.advanced[provider] = fields
        })
    }

    func draft(_ account: String) -> Binding<String> {
        Binding(get: { drafts[account] ?? "" }, set: { drafts[account] = $0 })
    }

    var removeAsked: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    var removeTitle: String {
        "Remove “\(removing?.label ?? "API key")” from the Keychain?"
    }

    var hasUnsavedDraft: Bool {
        secrets.contains {
            !(drafts[$0.account] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The seat's list, plus the saved id when the seat does not list it: kept, never replaced.
    var copilotOptions: [CopilotModel] {
        let saved = settings.models["copilot"] ?? ""
        return saved.isEmpty || copilotModels.contains { $0.id == saved }
            ? copilotModels : copilotModels + [(id: saved, name: saved)]
    }

    static let modelLabels = ["bedrock": "Model ID", "foundry": "Deployment"]
    static let modelPrompts = [
        "ollama": "gemma4", "copilot": "gpt-6.1-sol", "claude": "claude-opus-5-5",
        "openai": "gpt-4.1", "bedrock": "Model ID or inference profile ID",
        "foundry": "Your deployment's name", "openai_compatible": "Model name the gateway expects",
        "anthropic_compatible": "e.g. claude-opus-5-5"]

    static let gitHubCaptions: [GitHubSignIn: String] = [
        .signedIn: "Signed in", .signedOut: "Not signed in", .noCLI: "GitHub CLI not found"]

    // MARK: Actions

    func reload() {
        stored = Set(ProviderInfo.accounts.filter(keyStored))
        reloadEnv()
        advancedOpen = advancedNeeded
        fetchModels()
    }

    func reloadEnv() {
        env = EnvFile.values()
        envExists = EnvFile.exists
        envTooOpen = EnvFile.tooOpen
    }

    /// Open on arrival when a field it holds is still missing (base URL, region).
    var advancedNeeded: Bool {
        !Set(ProviderInfo.missingAll(cfg)).isDisjoint(with: ["base URL", "region"])
    }

    func providerChanged() {
        drafts = [:]  // a key typed for one provider is never saved under another
        testResult = nil
        advancedOpen = advancedNeeded
        fetchModels()
    }

    func gitHubChanged() {
        guard model.gitHub == .signedIn else { return }
        // Perhaps as someone else, whose seat lists other models. The CLI's models cache is not
        // keyed by account, so for up to 10 minutes after a switch the old list may show.
        copilotModels = []
        fetchModels()
    }

    /// Copilot only, once per visit; a failed fetch is retried on the next switch to Copilot.
    func fetchModels() {
        guard id == "copilot", copilotModels.isEmpty, !fetchingModels else { return }
        fetchingModels = true
        actions.fetchCopilotModels { models in
            copilotModels = models
            fetchingModels = false
        }
    }

    func save(_ secret: ProviderSecret) {
        let value = (drafts[secret.account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.set(value, account: secret.account)
        } catch {  // the existing log line; neither the account nor the status is a secret
            appendToLog(["warning": "API key not saved: OSStatus \((error as NSError).code)"])
        }
        drafts[secret.account] = nil
        stored = Set(ProviderInfo.accounts.filter(keyStored))
        testResult = nil
    }

    /// The user's own action, confirmed in the dialog.
    func remove(_ secret: ProviderSecret) {
        Keychain.delete(account: secret.account)
        stored = Set(ProviderInfo.accounts.filter(keyStored))
        testResult = nil
    }

    func test() {
        testing = true
        testResult = nil
        let provider = id
        actions.testConnection { result in
            testing = false
            if settings.provider == provider { testResult = result }
        }
    }

    func openEnv() {
        actions.openEnvFile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reloadEnv() }
    }
}

// MARK: - Pieces (nested, so their names never meet another file's)

extension AIProviderView {
    /// The eight providers as selectable tiles: two to a row, one in a narrow pane (the
    /// minimum keeps "Other (Anthropic-compatible)" on one line).
    struct ProviderGrid: View {
        @Binding var selection: String
        let envChoice: String?  // the provider the .env selects, when it differs

        static let tints: [String: Color] = [
            "ollama": .green, "copilot": .indigo, "claude": .orange, "openai": .teal,
            "bedrock": .purple, "foundry": .blue, "openai_compatible": .gray,
            "anthropic_compatible": .gray]

        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], spacing: 8) {
                ForEach(ProviderInfo.all, id: \.id) { p in
                    ProviderTile(name: p.name, symbol: p.symbol, blurb: p.blurb,
                                 tint: Self.tints[p.id] ?? .gray, selected: selection == p.id,
                                 fromEnv: envChoice == p.id) { selection = p.id }
                }
            }
            .padding(.vertical, 4)
        }
    }

    struct ProviderTile: View {
        let name: String
        let symbol: String
        let blurb: String
        let tint: Color
        let selected: Bool
        let fromEnv: Bool
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                HStack(spacing: 10) {
                    ProviderIcon(symbol: symbol, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.body.weight(.medium)).lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text(fromEnv ? "Selected in the .env file" : blurb)
                            .font(.caption).foregroundStyle(fromEnv ? Color.blue : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Color.accentColor
                                         : Color.secondary.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
                .background(shape.fill(selected ? Color.accentColor.opacity(0.12)
                                       : Color.primary.opacity(0.035)))
                .overlay(shape.strokeBorder(selected ? Color.accentColor.opacity(0.7)
                                            : Color.primary.opacity(0.08)))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name). \(fromEnv ? "Selected in the .env file" : blurb)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }

        var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }
    }

    /// A System Settings-style icon: a white SF Symbol on a tinted rounded square.
    struct ProviderIcon: View {
        let symbol: String
        let tint: Color

        var body: some View {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white))
                .accessibilityHidden(true)
        }
    }

    /// "Set up" or "Needs setup" beside a key-based provider's name.
    struct SetupBadge: View {
        let ready: Bool

        var body: some View {
            let tint = ready ? Color.green : Color.orange
            Label(ready ? "Set up" : "Needs setup",
                  systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule())
                .fixedSize()
        }
    }

    /// A row with an icon, a title, a caption and an optional button on the right.
    struct Notice<Accessory: View>: View {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        @ViewBuilder var accessory: () -> Accessory

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(tint)
                    .frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.vertical, 2)
        }
    }

    /// A green or orange mark with a short state.
    struct StatusText: View {
        let ok: Bool
        let text: String

        var body: some View {
            Label {
                Text(text).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
            }
        }
    }

    /// One Keychain secret: a secure field and one button. Save while something is typed (it
    /// replaces a saved secret); Remove… while a secret is saved and the field is empty.
    struct SecretRow: View {
        let secret: ProviderSecret
        @Binding var draft: String
        let stored: Bool
        let fromEnv: Bool  // the .env sets it: that value wins over a saved one
        let save: (ProviderSecret) -> Void
        let remove: (ProviderSecret) -> Void

        var body: some View {
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField(secret.label, text: $draft, prompt: Text(prompt))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit { if !blank { save(secret) } }
                    Group {  // one fixed slot: every field on the screen ends at the same x
                        if stored && blank {
                            Button("Remove…", role: .destructive) { remove(secret) }
                                .help("Delete the saved “\(secret.label)” from the Keychain")
                        } else {
                            Button("Save") { save(secret) }.disabled(blank)
                        }
                    }
                    .frame(width: 84, alignment: .trailing)
                }
                .frame(width: AIProviderView.fieldWidth)
            } label: {
                HStack(spacing: 6) {
                    Text(secret.label)
                    if stored {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            .accessibilityLabel("Saved")
                    }
                }
            }
        }

        var blank: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }
        var prompt: String {
            if fromEnv { return "Set in the .env file" }
            return stored ? "Saved in the Keychain" : secret.optional ? "Optional" : "Paste to save"
        }
    }

    /// Base URL, header style and API version of Foundry and the two compatible gateways.
    struct GatewayFields: View {
        let id: String
        @Binding var baseURL: String
        @Binding var header: String
        @Binding var version: String

        static let urlPrompts = [
            "foundry": "https://<resource>.openai.azure.com/openai/v1",
            "openai_compatible": "https://gateway.example.com/v1",
            "anthropic_compatible": "https://<resource>.services.ai.azure.com/anthropic"]
        static let defaultHeaders = [
            "foundry": "api-key", "openai_compatible": "Bearer",
            "anthropic_compatible": "x-api-key"]

        var body: some View {
            FieldRow("Base URL") {
                TextField("Base URL", text: $baseURL, prompt: Text(Self.urlPrompts[id] ?? ""))
            }
            Picker("Header style", selection: $header) {
                Text("Default (\(Self.defaultHeaders[id] ?? ""))").tag("")
                Divider()
                Text("Authorization: Bearer").tag("bearer")
                Text("api-key").tag("api-key")
                Text("x-api-key").tag("x-api-key")
            }
            FieldRow("API version") {
                TextField("API version", text: $version,
                          prompt: Text("Optional: adds ?api-version="))
            }
        }
    }

    /// Bedrock's region, sign-in method and AWS profile.
    struct BedrockFields: View {
        @Binding var region: String
        @Binding var auth: String  // "" means api_key
        @Binding var profile: String

        var body: some View {
            FieldRow("Region") { TextField("Region", text: $region, prompt: Text("us-east-1")) }
            LabeledContent("Sign in with") {
                Picker("Sign in with", selection: method) {
                    Text("API key").tag("api_key")
                    Text("Access key").tag("access_key")
                    Text("AWS profile").tag("profile")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()  // its natural width, ending where the fields end
                .frame(width: AIProviderView.fieldWidth, alignment: .trailing)
            }
            if method.wrappedValue == "profile" {
                FieldRow("Profile name") {
                    TextField("Profile name", text: $profile, prompt: Text("default"))
                }
                Text("Reads ~/.aws/credentials and ~/.aws/config. SSO profiles are not "
                     + "supported: use an access key or a Bedrock API key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        var method: Binding<String> {
            Binding(get: { auth.isEmpty ? "api_key" : auth }, set: { auth = $0 })
        }
    }

    /// A label on the left, a bordered text field on the right: URLs read better left-aligned.
    struct FieldRow<Field: View>: View {
        let title: String
        @ViewBuilder var field: () -> Field

        init(_ title: String, @ViewBuilder field: @escaping () -> Field) {
            self.title = title
            self.field = field
        }

        var body: some View {
            LabeledContent(title) {
                field().labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading).frame(width: AIProviderView.fieldWidth)
            }
        }
    }

    /// The Advanced row: a chevron, the title and, while closed, what it holds.
    struct AdvancedToggle: View {
        @Binding var open: Bool
        let summary: String

        var body: some View {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text("Advanced")
                    Spacer(minLength: 8)
                    if !open {
                        Text(summary).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(open ? "Expanded" : "Collapsed. \(summary)")
        }
    }

    /// Test connection and its answer: "OK (N ms)" or the error, as providers.py --test gives it.
    struct ConnectionRow: View {
        let testing: Bool
        let result: String?
        let unsaved: Bool  // a typed key not saved yet: the test uses the saved one
        let testsOther: String?  // the .env's provider, when the test goes there instead
        let test: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button(action: test) {
                        Label("Test connection", systemImage: "network")
                    }
                    .disabled(testing)
                    if testing {
                        ProgressView().controlSize(.small)
                        Text("Sending one short request…").foregroundStyle(.secondary)
                    } else if let result = result {
                        answer(result)
                    }
                    Spacer(minLength: 0)
                }
                if let note = note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }

        func answer(_ text: String) -> some View {
            let ok = text.hasPrefix("OK")
            return Label {
                Text(text).foregroundStyle(ok ? Color.primary : Color.red)
                    .lineLimit(3).textSelection(.enabled)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
            }
        }

        var note: String? {
            if let other = testsOther {
                return "Tests \(other), the provider the .env file selects."
            }
            return unsaved ? "Save the key first: the test uses what is saved." : nil
        }
    }
}

extension AIProviderView.Notice where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}
