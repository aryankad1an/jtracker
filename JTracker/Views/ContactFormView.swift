import SwiftUI

/// Add a new cold-mail contact (recruiter). Editing an existing one happens in
/// `ContactDetailView`.
struct ContactFormView: View {
    let onSave: (Contact) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var name = ""
    @State private var phone = ""
    @State private var position = ""

    var body: some View {
        NavigationStack {
            Form {
                RecruiterFields(email: $email, name: $name, position: $position, phone: $phone)
            }
            .navigationTitle("Add Cold Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(Contact(
                            email: email.lowercased(),
                            name: name,
                            phone: phone.isEmpty ? nil : phone,
                            position: position
                        ))
                        dismiss()
                    }
                    .disabled(!RecruiterFields.isValid(email: email, name: name))
                }
            }
        }
    }
}

/// The shared recruiter form fields, reused by add and edit.
///
/// Read-only mode isn't just "the same fields, disabled". A disabled `TextField`
/// renders its value with no label at all, so a filled-in detail screen became a
/// stack of anonymous strings — you could read "HARMESH ROHIT" but nothing said
/// which field it was. `LabeledContent` names each value instead.
struct RecruiterFields: View {
    @Binding var email: String
    @Binding var name: String
    @Binding var position: String
    @Binding var phone: String
    var isEditing = true
    var header = "Recruiter"

    static func isValid(email: String, name: String) -> Bool {
        email.contains("@") && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Section(header) {
            if isEditing {
                TextField("Recruiter Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .onChange(of: email) { _, value in
                        if value != value.lowercased() { email = value.lowercased() }
                    }
                TextField("Name", text: $name)
                TextField("Position (optional)", text: $position)
                TextField("Phone Number (optional)", text: $phone)
                    .keyboardType(.phonePad)
            } else {
                if !name.isEmpty { LabeledContent("Name", value: name) }
                LabeledContent("Email", value: email)
                if !position.isEmpty { LabeledContent("Position", value: position) }
                if !phone.isEmpty { LabeledContent("Phone", value: phone) }
            }
        }
    }
}
