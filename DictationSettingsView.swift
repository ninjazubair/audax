// Dictation settings: the two shortcuts (recorded by pressing them), the Fn key's state, sounds,
// language and the clean-up level. ⌘, opens the window here.
import SwiftUI

struct DictationSettingsView: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: Settings
    let actions: Actions

    var body: some View {
        Form {
            Section("Shortcuts") { shortcuts }
            Section("Sound") {
                Toggle(isOn: $settings.sounds) {
                    Text("Sounds")
                    Text("A soft chime when recording starts and when the text is pasted.")
                }
            }
            Section("Language and clean-up") { languageAndCleanup }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var shortcuts: some View {
        LabeledContent {
            ShortcutRecorder(shortcut: $settings.talkKey, conflictsWith: settings.handsFreeKey,
                             onRecording: actions.pauseHotKeys)
                .buttonStyle(KeycapFieldStyle())
        } label: {
            Text("Hold to talk")
            Text("Hold the keys, speak, let go.")
        }
        LabeledContent {
            ShortcutRecorder(shortcut: $settings.handsFreeKey, conflictsWith: settings.talkKey,
                             onRecording: actions.pauseHotKeys)
                .buttonStyle(KeycapFieldStyle())
        } label: {
            Text("Hands-free")
            Text("Press to start, press again to finish.")
        }
        if settings.talkKey.needsTap || settings.handsFreeKey.needsTap {
            CheckRow(ok: model.tapOK, title: "Fn shortcuts",
                     detail: model.tapOK ? "Active: AUDAX sees the Fn key."
                         : "Fn shortcuts need Accessibility.",
                     fixTitle: "Allow…", fix: actions.allowPaste, symbol: "keyboard")
        }
        if model.globeConflict { GlobeHint(open: actions.openKeyboardSettings) }
    }

    static let cleanupCaptions = [
        "off": "You get the raw transcript.",
        "light": "Punctuation, filler words and self-corrections.",
        "full": "Light, plus grammar, word order and recognition errors.",
    ]

    @ViewBuilder var languageAndCleanup: some View {
        Picker("Language", selection: $settings.language) {
            Text("English").tag("en")
            Text("Deutsch").tag("de")
        }
        .pickerStyle(.segmented)
        Picker(selection: $settings.cleanup) {
            Text("Off").tag("off")
            Text("Light").tag("light")
            Text("Full").tag("full")
        } label: {
            Text("Clean-up")
            Text(Self.cleanupCaptions[settings.cleanup] ?? "")
        }
        .pickerStyle(.segmented)
    }
}
