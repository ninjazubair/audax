// Words: the user's own corrections (word_subs.json), applied by dictate.py on every dictation.
// Removing a row is the user's own edit of their list, as adding one is.
import SwiftUI

struct WordsView: View {
    @ObservedObject var settings: Settings
    @State private var wrong = ""  // the new pair
    @State private var right = ""

    var body: some View {
        Form {
            Section {
                addRow
            } header: {
                Text("Add a correction")
            } footer: {
                Text("Any case and spacing matches. The next dictation uses it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if settings.wordSubs.isEmpty {
                    Text("No corrections yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.wordSubs) { row($0) }
                }
            } header: {
                Text("Your corrections (\(settings.wordSubs.count))")
            } footer: {
                Text("Built-in corrections (Workfront, RTCDP, …) stay active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var addRow: some View {
        HStack(spacing: 8) {
            TextField("Heard as", text: $wrong, prompt: Text("Heard as, e.g. work front"))
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Written as", text: $right, prompt: Text("Written as, e.g. Workfront"))
            Button("Add", action: add).disabled(!canAdd)
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .onSubmit(add)
    }

    func row(_ sub: WordSub) -> some View {
        HStack(spacing: 12) {
            Text(sub.wrong).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(sub.right).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
            Button { settings.wordSubs.removeAll { $0.id == sub.id } } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove \(sub.wrong)")
        }
    }

    var canAdd: Bool { !Self.blank(wrong) && !Self.blank(right) }

    func add() {
        guard canAdd else { return }
        settings.addWordSub(wrong: wrong, right: right)
        wrong = ""
        right = ""
    }

    static func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
