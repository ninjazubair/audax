// History: the last 200 dictations from the log, newest first, grouped by day, searchable,
// each ready to copy. Nothing here deletes: the log is the user's record.
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: Model
    let actions: Actions
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            list
            Divider()
            footer
        }
    }

    var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search dictations", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var shown: [Recent] {
        query.isEmpty ? model.recent
            : model.recent.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// Entries by day, days in first-seen order (newest first, as the log is in time order).
    /// One section per day even if the clock ever went back, so section ids stay unique.
    var days: [(day: String, items: [Recent])] {
        var out: [(day: String, items: [Recent])] = []
        for item in shown {
            if let i = out.firstIndex(where: { $0.day == item.day }) {
                out[i].items.append(item)
            } else {
                out.append((item.day, [item]))
            }
        }
        return out
    }

    var list: some View {
        List {
            ForEach(days, id: \.day) { group in
                Section(dayTitle(group.day)) {
                    ForEach(group.items) { HistoryRow(item: $0) }
                }
            }
        }
        .listStyle(.inset)
        .overlay { empty }
    }

    @ViewBuilder var empty: some View {
        if model.recent.isEmpty {
            ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                   description: Text("Every dictation appears here, newest first."))
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    var footer: some View {
        HStack {
            Button("Open log", action: actions.openLog)
            Spacer()
            Text(countText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    var countText: String {
        let total = model.recent.count
        if !query.isEmpty { return "\(shown.count) of \(total)" }
        return total == 1 ? "1 dictation" : "\(total) dictations"
    }

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")  // the log's own stamp format
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Today", "Yesterday", or "Thursday 22 October" in the user's locale.
    func dayTitle(_ day: String) -> String {
        guard let date = Self.dayParser.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct HistoryRow: View {
    let item: Recent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .textSelection(.enabled)  // drag to copy part of it
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.caption.isEmpty {
                    Text(item.caption).font(.caption).foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .trailing, spacing: 4) {
                CopyButton(text: item.text, title: "Copy")
                if wordsDiffer(item.raw, item.text) {
                    CopyButton(text: item.raw, title: "Copy original")
                        .help("What was heard before the AI clean-up: \(item.raw)")
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

/// Copies `text` and says "Copied" for 1.5 s.
struct CopyButton: View {
    let text: String
    let title: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            copyToClipboard(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}
