// Home: the dictation state and shortcuts, what still needs setting up, a box to try dictation
// in, the everyday settings, and the last dictation.
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: Settings
    let actions: Actions
    @FocusState private var tryBoxFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                SetupCard(model: model, settings: settings, actions: actions)
                tryIt
                QuickControls(model: model, settings: settings)
                lastDictation
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    var hero: some View {
        HStack(spacing: 16) {
            heroGlyph
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(.title2.weight(.semibold))
                if model.phase == .idle && model.ready {
                    shortcutLine
                } else {
                    Text(subline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 20)
    }

    var headline: String {
        switch model.phase {
        case .recording: return model.mode == .hold ? "Listening…" : "Listening hands-free…"
        case .transcribing: return "Transcribing…"
        case .idle: return model.ready ? "Ready to dictate" : "Almost ready"
        }
    }

    /// Under the headline whenever the shortcut keycaps are not shown.
    var subline: String {
        let talk = settings.talkKey.display, handsFree = settings.handsFreeKey.display
        switch model.phase {
        case .recording where model.mode == .hold:
            return "Release \(talk) to finish, or press \(handsFree) to go hands-free."
        case .recording: return "Press \(handsFree) to finish."
        case .transcribing: return "Your text is on its way."
        case .idle: return "Fix the items below, then hold \(talk) and speak."
        }
    }

    @ViewBuilder var heroGlyph: some View {
        switch model.phase {
        case .idle:
            Image(nsImage: NSApp.applicationIconImage).resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
        case .recording:
            glyph("waveform", .red).symbolEffect(.variableColor.iterative)
        case .transcribing:
            glyph("ellipsis", .orange).symbolEffect(.pulse)
        }
    }

    func glyph(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 64, height: 64)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    /// "Hold [Fn] and speak · [Fn] [Space] for hands-free"; two lines when the pane is narrow.
    var shortcutLine: some View {
        let talk = HStack(spacing: 6) {
            Text("Hold")
            ShortcutKeys(shortcut: settings.talkKey)
            Text("and speak")
        }
        let handsFree = HStack(spacing: 6) {
            ShortcutKeys(shortcut: settings.handsFreeKey)
            Text("for hands-free")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                talk
                Text("·").foregroundStyle(.tertiary)
                handsFree
            }
            VStack(alignment: .leading, spacing: 6) {
                talk
                handsFree
            }
        }
        .foregroundStyle(.secondary)
    }

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try it here").font(.headline)
            TextEditor(text: $model.scratch)
                .focused($tryBoxFocused)
                .onAppear(perform: focusOnOpen)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 88)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) { placeholder }
            Text("While AUDAX is in front on Home, dictations land in this box. "
                 + "\(settings.talkKey.display) works the same in any other app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    /// Open AUDAX, hold the talk key, talk: the first Home after the window opens focuses the
    /// box. Coming back to Home from another pane leaves the focus alone.
    func focusOnOpen() {
        guard model.focusTryBox else { return }
        model.focusTryBox = false
        tryBoxFocused = true
    }

    @ViewBuilder var placeholder: some View {
        if model.scratch.isEmpty {
            Text("Hold \(settings.talkKey.display) and speak: the text appears here.")
                .foregroundStyle(.tertiary)
                .padding(.leading, 11)
                .padding(.top, 6)
                .allowsHitTesting(false)
        }
    }

    var lastDictation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last dictation").font(.headline)
                Spacer()
                Button("Show all") { model.pane = .history }
                    .buttonStyle(.link)
                    .disabled(model.recent.isEmpty)
            }
            if let last = model.recent.first {
                Text(last.text)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(last.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    CopyButton(text: last.text, title: "Copy").controlSize(.small)
                }
            } else {
                Text("Nothing yet. Every dictation appears here, ready to copy.")
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

/// One row per problem with its fix; a single green line when nothing needs attention.
struct SetupCard: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: Settings
    let actions: Actions

    var body: some View {
        let rows = self.rows
        if rows.isEmpty { allSet } else { problems(rows) }
    }

    func problems(_ rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs your attention").font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { Divider() }
                rows[index]
            }
        }
        .card()
    }

    var allSet: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(settings.cleanup == "off"
                 ? "All set: microphone, pasting and speech engine are ready; clean-up is off."
                 : "All set: microphone, pasting, speech engine and clean-up are ready.")
        }
        .font(.callout)
        .card(padding: 12)
    }

    /// Requirements first, then clean-up, then the Globe-key hint.
    var rows: [AnyView] {
        var rows: [CheckRow] = []
        if !model.micOK {
            rows.append(CheckRow(
                ok: false, title: "Microphone",
                detail: "Lets AUDAX hear you while the pill is showing.",
                fixTitle: "Allow…", fix: actions.allowMic, symbol: "mic.fill"))
        }
        if !model.pasteOK {
            rows.append(CheckRow(
                ok: false, title: "Paste into other apps",
                detail: "Accessibility permission, so text appears where you type.",
                fixTitle: "Allow…", fix: actions.allowPaste, symbol: "accessibility"))
        }
        if !model.engineOK {
            rows.append(CheckRow(
                ok: false, title: "Speech engine and model",
                detail: "whisper.cpp with the large-v3-turbo model, on this Mac's GPU.",
                fixTitle: "Run setup…", fix: actions.runSetup, symbol: "waveform"))
        }
        if usesTap && !model.tapOK {
            rows.append(CheckRow(
                ok: false, title: "Fn shortcuts", detail: "Fn shortcuts need Accessibility.",
                fixTitle: "Allow…", fix: actions.allowPaste, symbol: "keyboard"))
        }
        if let cleanup = cleanupRow { rows.append(cleanup) }
        let globe = model.globeConflict ? [AnyView(GlobeHint(open: actions.openKeyboardSettings))]
            : []
        return rows.map { AnyView($0) } + globe
    }

    var usesTap: Bool { settings.talkKey.needsTap || settings.handsFreeKey.needsTap }

    /// Off needs nothing: the raw transcript is pasted.
    var cleanupRow: CheckRow? {
        guard settings.cleanup != "off" else { return nil }
        let status = providerStatus(settings, model: model)
        guard !status.ok else { return nil }
        return CheckRow(ok: false, title: "AI clean-up", detail: status.detail,
                        fixTitle: status.fixTitle, fix: cleanupFix, symbol: "sparkles")
    }

    var cleanupFix: () -> Void {
        switch ProviderInfo.active(settings, env: EnvFile.values()) {
        case "ollama": return actions.startOllama
        case "copilot": return actions.signInGitHub
        default: return { model.pane = .aiProvider }  // keys, endpoints: the provider pane
        }
    }
}

/// Language, clean-up level and the provider, with where the text goes.
struct QuickControls: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick settings").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    label("Language")
                    Picker("Language", selection: $settings.language) {
                        Text("English").tag("en")
                        Text("Deutsch").tag("de")
                    }
                    .fixedSize()
                }
                GridRow {
                    label("Clean-up")
                    Picker("Clean-up", selection: $settings.cleanup) {
                        Text("Off").tag("off")
                        Text("Light").tag("light")
                        Text("Full").tag("full")
                    }
                    .fixedSize()
                }
                GridRow {
                    label("Provider")
                    provider
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(privacyNote).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(minWidth: 72, alignment: .leading)
    }

    var provider: some View {
        HStack(spacing: 8) {
            Button { model.pane = .aiProvider } label: {
                Text(ProviderInfo.name(providerID))
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .buttonStyle(.link)
            .help("Choose the clean-up provider")
            if let hint = speedHint {
                Text(hint).foregroundStyle(.secondary)
                    .help("Measured on the developer's Mac")
            }
        }
    }

    /// Measured per dictation (handoff, Task 2); nothing for providers not measured.
    static let speedHints = ["ollama/gemma4": "≈0.3 s per dictation",
                             "copilot/gpt-4.1": "≈2 s per dictation",
                             "copilot/gpt-6.1-sol": "≈2.7–4.9 s per dictation"]

    /// The provider dictations use (the .env's AUDAX_PROVIDER wins), as the privacy line names.
    var providerID: String { ProviderInfo.active(settings, env: EnvFile.values()) }

    var speedHint: String? {
        let provider = providerID
        return Self.speedHints["\(provider)/\(settings.models[provider] ?? "")"]
    }

    /// Off counts as local: with clean-up switched off no text is sent anywhere.
    var privacyNote: String {
        guard settings.cleanup != "off", let to = ProviderInfo.recipient(settings) else {
            return "Audio and text never leave this Mac."
        }
        return "Audio stays on this Mac. Text is sent to \(to) for clean-up."
    }
}
