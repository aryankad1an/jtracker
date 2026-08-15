import SwiftUI

/// A company's cold mails, split by a Pending / Sent filter. Sent mails are a
/// permanent record and can't be deleted.
struct JobDetailView: View {
    @Environment(JobStore.self) private var jobStore
    let jobID: Job.ID

    @State private var isAdding = false
    @State private var isComposing = false
    @State private var composePreselect: Set<Contact.ID>?
    @State private var detailContact: Contact?
    @State private var isSelecting = false
    @State private var selection = Set<Contact.ID>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: Contact?

    /// Always read the live job from the store so edits show immediately.
    private var job: Job? {
        jobStore.jobs.first { $0.id == jobID }
    }

    /// All the company's cold mails, sorted by display name, in one list.
    private func sortedContacts(_ job: Job) -> [Contact] {
        job.contacts.sorted {
            let a = $0.name.isEmpty ? $0.email : $0.name
            let b = $1.name.isEmpty ? $1.email : $1.name
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let job {
                let contacts = sortedContacts(job)
                if contacts.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        contactRows(contacts, job: job)
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                }
            }
        }
        .navigationTitle(job?.company ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    GlassDoneButton { exitSelection() }
                } else {
                    Menu {
                        Button {
                            isAdding = true
                        } label: {
                            Label("Add Cold Mail", systemImage: "plus")
                        }
                        if let job, !job.contacts.isEmpty {
                            Button {
                                enterSelection()
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .selectionActions(
            isSelecting: isSelecting,
            count: selection.count,
            noun: SelectionNoun(singular: "cold mail", plural: "cold mails"),
            confirmingDelete: $confirmingDelete,
            deleteMessage: "This permanently deletes the selected recruiters from the shared database, for every user. Sent ones are kept. This can't be undone.",
            onSend: {
                let chosen = selection
                exitSelection()
                startCompose(preselect: chosen)
            }
        ) { deleteSelected() }
        .confirmationDialog(
            "Delete \(pendingDelete.map { $0.name.isEmpty ? $0.email : $0.name } ?? "recruiter")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let contact = pendingDelete {
                    Task { await jobStore.deleteContact(contact) }
                }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently deletes the recruiter from the shared database, for every user. This can't be undone.")
        }
        .sheet(isPresented: $isAdding) {
            ContactFormView { new in
                if let job { Task { await jobStore.addContact(new, to: job) } }
            }
        }
        .sheet(item: $detailContact) { contact in
            ContactDetailView(contact: contact, company: job?.company ?? "") { updated in
                Task { await jobStore.updateContact(updated) }
            }
        }
        .sheet(isPresented: $isComposing) {
            if let job { SendMailView(job: job, preselect: composePreselect) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Cold Mails",
            systemImage: "envelope",
            description: Text("Use the menu to add a cold mail.")
        )
    }

    /// Open the compose sheet. Pass `preselect` to send to specific contacts
    /// (a single row or the current selection); nil defaults to all unsent.
    private func startCompose(preselect: Set<Contact.ID>? = nil) {
        composePreselect = preselect
        isComposing = true
    }

    private func enterSelection() {
        selection = []
        withAnimation { isSelecting = true }
    }

    private func exitSelection() {
        withAnimation { isSelecting = false }
        selection = []
    }

    private func deleteSelected() {
        guard let job else { return }
        // Sent mails are a permanent record — never delete them.
        let toDelete = job.contacts.filter { selection.contains($0.id) && !$0.isSent }
        Task {
            for contact in toDelete {
                await jobStore.deleteContact(contact)
            }
        }
        exitSelection()
    }

    @ViewBuilder
    private func contactRows(_ contacts: [Contact], job: Job) -> some View {
        ForEach(contacts) { contact in
            if isSelecting {
                ContactRow(contact: contact)
            } else {
                ContactRow(contact: contact, onSend: contact.email.contains("@")
                           ? { startCompose(preselect: [contact.id]) } : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { detailContact = contact }
                    // Sent mails are a permanent record, so no delete swipe.
                    .swipeActions(edge: .trailing) {
                        if !contact.isSent {
                            Button(role: .destructive) {
                                pendingDelete = contact
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }
        }
    }
}

/// A single cold-mail row: icon, recruiter name, position, a "last sent" pill,
/// and a send button for sending (or re-sending).
private struct ContactRow: View {
    let contact: Contact
    var onSend: (() -> Void)? = nil

    private var title: String {
        contact.name.isEmpty ? contact.email : contact.name
    }

    private var subtitle: String {
        contact.position.isEmpty ? contact.email : contact.position
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let sentAt = contact.sentAt {
                    lastSentPill(sentAt)
                }
                if let onSend {
                    Button(action: onSend) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .background(.tint.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// A small "Last sent …" chip, shown once a mail has gone out.
    private func lastSentPill(_ date: Date) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar")
            Text(date.activityLabel)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.statusDone)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.statusDone.opacity(0.15), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}
