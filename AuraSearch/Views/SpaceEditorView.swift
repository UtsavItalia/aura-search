import SwiftUI

/// Creates a new Space, or renames and recolors an existing one.
struct SpaceEditorView: View {
    let space: Space?

    @Environment(TabStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: SpaceColor

    init(space: Space?) {
        self.space = space
        _name = State(initialValue: space?.name ?? "")
        _color = State(initialValue: space?.color ?? .blue)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Work, Study, Reading…", text: $name)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: SpaceColor.allCases.count)) {
                        ForEach(SpaceColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if option == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue.capitalized)
                            .accessibilityAddTraits(option == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(space == nil ? "New Space" : "Edit Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        if let space {
            store.updateSpace(space.id, name: name, color: color)
        } else {
            store.addSpace(name: name, color: color)
        }
        dismiss()
    }
}
