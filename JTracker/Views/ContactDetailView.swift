import SwiftUI

/// A contact's details: recruiter fields (read-only until you tap the pencil,
/// then saved upstream to the shared database) plus this user's send history —
/// tapping a history entry opens that sent mail.
struct ContactDetailView: View {
    let contact: Contact
    let company: String
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

    @State private var history: [MailSend] = []
    @State private var isLoadingHistory = true
    @State private var selectedSend: MailSend?

    init(contact: Contact, company: String, onSave: @escaping (Contact) -> Void) {
        self.contact = contact
        self.company = company
        self.onSave = onSave
        _email = State(initialValue: contact.email)
        _name = State(initialValue: contact.name)
        _phone = State(initialValue: contact.phone ?? "")
        _position = State(initialValue: contact.position)
        _committed = State(initialValue: contact)
    }

    private var isValid: Bool {
        RecruiterFields.isValid(email: email, name: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                RecruiterFields(email: $email, name: $name, position: $position, phone: $phone,
                                isEditing: isEditing, header: company)

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
                        Button("Save") { save() }.disabled(!isValid)
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
            position: position
        )
        committed = updated
        email = updated.email      // reflect the lowercased email back in the field
        onSave(updated)
        isEditing = false
    }
}
