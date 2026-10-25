// STUB — replaced by lane U2 at merge
// The AI Provider pane, as the shared interface (task-7-ui-briefs.md) defines it.
import SwiftUI

struct AIProviderView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var model: Model
    let actions: Actions

    var body: some View {
        Form {
            Section("Clean-up provider") {
                LabeledContent("Provider", value: ProviderInfo.name(settings.provider))
                LabeledContent("Model", value: settings.models[settings.provider] ?? "")
            }
        }
        .formStyle(.grouped)
    }
}
