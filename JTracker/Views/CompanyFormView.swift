import SwiftUI

/// A form to create a new company or edit an existing one's name and sector.
/// Both fields write upstream to the shared catalog (for every user).
struct CompanyFormView: View {
    let title: String
    let confirmLabel: String
    let onSave: (_ name: String, _ sector: String) -> Void

    @State private var name: String
    @State private var sector: String
    @Environment(\.dismiss) private var dismiss

    init(name: String = "", sector: String = "",
         title: String, confirmLabel: String,
         onSave: @escaping (_ name: String, _ sector: String) -> Void) {
        _name = State(initialValue: name)
        _sector = State(initialValue: sector)
        self.title = title
        self.confirmLabel = confirmLabel
        self.onSave = onSave
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Company") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Sector (optional)", text: $sector)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        onSave(trimmedName, sector.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}
