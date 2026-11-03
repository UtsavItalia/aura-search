import SwiftUI

/// Closed and auto-archived tabs, newest first. Tap one to reopen it.
struct ArchiveView: View {
    @Environment(TabStore.self) private var store
    @Environment(BrowserSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if store.archive.isEmpty {
                    ContentUnavailableView(
                        "Archive is empty",
                        systemImage: "archivebox",
                        description: Text("Closed and auto-archived tabs show up here.")
                    )
                } else {
                    List(store.archive) { item in
                        Button {
                            session.restore(item.id)
                            dismiss()
                        } label: {
                            archivedRow(item)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear", role: .destructive) { confirmingClear = true }
                        .disabled(store.archive.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear the archive?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear Archive", role: .destructive) { store.clearArchive() }
            } message: {
                Text("Archived tabs can't be restored after this.")
            }
        }
    }

    private func archivedRow(_ item: ArchivedTab) -> some View {
        let tint = store.space(withID: item.tab.spaceID)?.color.color ?? .gray
        let reason = item.reason == .autoArchived ? "Auto-archived" : "Closed"
        return HStack(spacing: 12) {
            FaviconView(tab: item.tab, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.tab.displayTitle)
                    .lineLimit(1)
                Text("\(reason) \(item.archivedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
