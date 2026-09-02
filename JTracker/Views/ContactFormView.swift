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
    @State private var greetingName = ""

    var body: some View {
        NavigationStack {
            PaperForm {
                RecruiterFields(email: $email, name: $name, position: $position, phone: $phone,
                                greetingName: $greetingName)
            }
            .navigationTitle("Add Cold Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.success()
                        onSave(Contact(
                            email: email.lowercased(),
                            name: name,
                            phone: phone.isEmpty ? nil : phone,
                            position: position,
                            greetingName: greetingName.isEmpty ? nil : greetingName
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
    @Binding var greetingName: String
    var isEditing = true
    var header = "Recruiter"

    static func isValid(email: String, name: String) -> Bool {
        email.contains("@") && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What a mail to this contact would open with, as edited right now — the
    /// override if one is typed, otherwise what gets derived from the name and
    /// address. Shown under the fields so the effect of filling in "Greeting
    /// Name" is visible before anything is sent.
    private var greetingPreview: String {
        Contact(email: email, name: name, greetingName: greetingName).greeting
    }

    var body: some View {
        Section {
            if isEditing {
                TextField("Recruiter Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .onChange(of: email) { _, value in
                        if value != value.lowercased() { email = value.lowercased() }
                    }
                TextField("Name", text: $name)
                TextField("Greeting Name (optional)", text: $greetingName)
                TextField("Position (optional)", text: $position)
                TextField("Phone Number (optional)", text: $phone)
                    .keyboardType(.phonePad)
            } else {
                if !name.isEmpty { LabeledContent("Name", value: name) }
                LabeledContent("Email", value: email)
                if !position.isEmpty { LabeledContent("Position", value: position) }
                if !phone.isEmpty { LabeledContent("Phone", value: phone) }
            }
        } header: {
            Text(header)
        } footer: {
            Text("Mail opens “Hi \(greetingPreview),”")
        }
    }
}
