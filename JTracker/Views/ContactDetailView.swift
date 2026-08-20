import SwiftUI

/// A contact's details: recruiter fields (read-only until you tap the pencil,
/// then saved upstream to the shared database) plus this user's send history —
/// tapping a history entry opens that sent mail.
///
/// This is also where a contact is ruled in or out. Marking invalid lives beside
/// the address rather than only in the list, because the two things you want to
/// do about a bounced mail — fix the address, or give up on it — belong on the
/// same screen.
struct ContactDetailView: View {
    let contact: Contact
    let company: String
    let onSetValidity: (Bool) -> Void
    let onSave: (Contact) -> Void

    @Environment(JobStore.self) private var jobStore
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var email: String
    @State private var name: String
    @State private var phone: String
    @State private var position: String
    /// The last-saved values, so Cancel reverts correctly even after a save.
    @State private var committed: Contact
    /// Mirrors the contact's shared valid/invalid flag so the sheet updates the
    /// moment you tap, without waiting for the round-trip and reload behind it.
    @State private var isContactValid: Bool

    @State private var history: [MailSend] = []
    @State private var isLoadingHistory = true
    @State private var selectedSend: MailSend?

    init(contact: Contact, company: String,
         onSetValidity: @escaping (Bool) -> Void,
         onSave: @escaping (Contact) -> Void) {
        self.contact = contact
        self.company = company
        self.onSetValidity = onSetValidity
        self.onSave = onSave
        _email = State(initialValue: contact.email)
        _name = State(initialValue: contact.name)
        _phone = State(initialValue: contact.phone ?? "")
        _position = State(initialValue: contact.position)
        _committed = State(initialValue: contact)
        _isContactValid = State(initialValue: contact.isValid)
    }

    /// Whether the edited fields are complete enough to save. (Not to be confused
    /// with `isContactValid`, which is whether the *person* is still worth mailing.)
    private var canSave: Bool {
        RecruiterFields.isValid(email: email, name: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isContactValid { invalidBanner }

                RecruiterFields(email: $email, name: $name, position: $position, phone: $phone,
                                isEditing: isEditing, header: company)

                validitySection

                Section("Sent History") {
                    if isLoadingHistory {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading history…").foregroundStyle(.secondary)
                        }
                    } else if history.isEmpty {
                        Text("No mail sent to this contact yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history) { send in
                            Button { selectedSend = send } label: {
                                historyRow(send)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            // The screen is about a person, so it's titled with their name. It used
            // to show the company, which is the one thing you already knew — you
            // arrived from that company's list.
            .navigationTitle(name.isEmpty ? email : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if isEditing { cancelEdit() } else { isEditing = true }
                    } label: {
                        Image(systemName: isEditing ? "xmark" : "pencil")
                    }
                    .accessibilityLabel(isEditing ? "Cancel editing" : "Edit recruiter")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Save") { save() }.disabled(!canSave)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task { await loadHistory() }
            .sheet(item: $selectedSend) { send in
                MailSummaryView(contact: contact(for: send), company: company)
            }
        }
    }

    /// Says the state plainly at the top of the sheet, so an invalid contact is
    /// obvious the moment it opens — the dimmed row in the list is a hint, this is
    /// the answer.
    private var invalidBanner: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Marked invalid")
                        .font(.subheadline.weight(.semibold))
                    Text("Not suggested to anyone, and can't be mailed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.statusInvalid)
            }
        }
    }

    /// The rule-in/rule-out control. Its own section under the fields: it isn't an
    /// edit to the recruiter's details (it applies straight away, with no Save),
    /// and the footer spells out that it lands for every user.
    private var validitySection: some View {
        Section {
            Button {
                let next = !isContactValid
                isContactValid = next
                onSetValidity(next)
            } label: {
                // Icon and text are coloured explicitly rather than via `.tint`:
                // inside a Form the row keeps painting a button's icon with the
                // app accent, so the label came out half green, half blue.
                let colour = isContactValid ? Color.statusInvalid : Color.statusDone
                Label {
                    Text(isContactValid ? "Mark as Invalid" : "Mark as Valid")
                        .foregroundStyle(colour)
                } icon: {
                    Image(systemName: isContactValid
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(colour)
                }
            }
        } footer: {
            Text(isContactValid
                 ? "For a bounced address or someone who has left. They stay on the company page for the record, but drop out of Suggested and can no longer be mailed — for every user."
                 : "Ruled out for every user. Fix the address above if it was wrong, then mark them valid to put them back in Suggested.")
        }
    }

    private func historyRow(_ send: MailSend) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(send.sentAt?.formatted(date: .abbreviated, time: .shortened) ?? "Sent")
                    .font(.subheadline)
                if let subject = send.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// A contact carrying this specific send's mail, for the summary drawer.
    private func contact(for send: MailSend) -> Contact {
        var c = Contact(id: contact.id, email: email, name: name,
                        phone: phone.isEmpty ? nil : phone, position: position)
        c.sentAt = send.sentAt
        c.sentSubject = send.subject
        c.sentBody = send.body
        return c
    }

    private func cancelEdit() {
        email = committed.email
        name = committed.name
        phone = committed.phone ?? ""
        position = committed.position
        isEditing = false
    }

    private func loadHistory() async {
        defer { isLoadingHistory = false }
        guard let email = jobStore.userEmail else { return }
        history = (try? await SupabaseAPI.fetchSendHistory(userEmail: email, recruiterID: contact.id)) ?? []
    }

    private func save() {
        let updated = Contact(
            id: contact.id,
            email: email.lowercased(),
            name: name,
            phone: phone.isEmpty ? nil : phone,
            position: position,
            isValid: isContactValid
        )
        committed = updated
        email = updated.email      // reflect the lowercased email back in the field
        onSave(updated)
        isEditing = false
    }
}
