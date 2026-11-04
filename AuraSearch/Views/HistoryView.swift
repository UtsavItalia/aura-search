import SwiftUI

/// Every page you've visited, newest first. Search it, tap to reopen,
/// swipe to delete. Private tabs never appear here.
struct HistoryView: View {
    let onOpen: (URL) -> Void

    @Environment(BrowserSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var confirmingClear = false

    private var visible: [HistoryEntry] {
        let needle = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        return session.history.entries
            .filter { entry in
                entry.visitCount > 0 &&
                (needle.isEmpty ||
                 entry.title.lowercased().contains(needle) ||
                 entry.displayURL.lowercased().contains(needle))
            }
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
    }

    var body: some View {
        NavigationStack {
            let entries = visible
            List {
                ForEach(entries) { entry in
                    Button {
                        onOpen(entry.url)
                    } label: {
                        row(entry)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    for index in offsets { session.history.remove(entries[index].id) }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No History" : "No Results",
                        systemImage: "clock",
                        description: Text(searchText.isEmpty ? "Pages you visit show up here." : "Try a different word.")
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search history")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear", role: .destructive) { confirmingClear = true }
                        .disabled(session.history.entries.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { session.history.clear() }
            } message: {
                Text("This also removes it from address autocomplete.")
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            FaviconView(url: entry.url, title: entry.displayTitle, tint: .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .lineLimit(1)
                Text("\(entry.displayURL) · \(entry.lastVisitedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
