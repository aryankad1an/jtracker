import SwiftUI

/// Identifies one request to open the compose sheet, so `.sheet(item:)` mints a
/// fresh `SendMailView` identity per request — see `startCompose` for why.
private struct ComposeRequest: Identifiable {
    let id = UUID()
    let preselect: Set<Contact.ID>?
}

/// A company's cold mails, split by a Pending / Sent filter. Sent mails are a
/// permanent record and can't be deleted.
struct JobDetailView: View {
    @Environment(JobStore.self) private var jobStore
    let jobID: Job.ID

    @State private var isAdding = false
    @State private var composeRequest: ComposeRequest?
    @State private var detailContact: Contact?
    @State private var isSelecting = false
    @State private var selection = Set<Contact.ID>()
    @State private var confirmingDelete = false
    @State private var pendingDelete: Contact?
    @State private var searchText = ""

    /// Always read the live job from the store so edits show immediately. Looks in
    /// the full catalog first, so a company opened from the Companies tab renders
    /// even when it isn't tracked.
    private var job: Job? {
        jobStore.company(id: jobID)
    }

    /// All the company's cold mails, sorted by display name, in one list.
    private func sortedContacts(_ job: Job) -> [Contact] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? job.contacts : job.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.email.localizedCaseInsensitiveContains(query)
                || $0.position.localizedCaseInsensitiveContains(query)
        }
        return matching.sorted {
            let a = $0.name.isEmpty ? $0.email : $0.name
            let b = $1.name.isEmpty ? $1.email : $1.name
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Sent mails are a permanent record, so only unsent ones can actually be
    /// removed. The bar counts what's selected; the delete dialog counts what will
    /// really go — they aren't the same number, and pretending otherwise meant
    /// confirming "Delete 5" and watching 2 disappear.
    private var deletableCount: Int {
        guard let job else { return 0 }
        return job.contacts.filter { selection.contains($0.id) && !$0.isSent }.count
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
                    .refreshable { await jobStore.load() }
                }
            }
        }
        .navigationTitle(job?.company ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search recruiters")
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
                    .accessibilityLabel("More actions")
                }
            }
        }
        .selectionActions(
            isSelecting: isSelecting,
            count: selection.count,
            noun: SelectionNoun(singular: "cold mail", plural: "cold mails"),
            confirmingDelete: $confirmingDelete,
            deleteMessage: "This permanently deletes the selected recruiters from the shared database, for every user. Sent ones are kept. This can't be undone.",
            deletableCount: deletableCount,
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
        .sheet(item: $composeRequest) { request in
            if let job { SendMailView(job: job, preselect: request.preselect) }
        }
    }

    /// Carries its own action, like the Companies and Templates empty states —
    /// pointing at a menu the user then has to go hunting for is a dead end.
    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView {
                Label("No Cold Mails", systemImage: "envelope")
            } description: {
                Text("Add a recruiter to start sending.")
            } actions: {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Cold Mail", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    /// Open the compose sheet. Pass `preselect` to send to specific contacts
    /// (a single row or the current selection); nil defaults to all unsent.
    ///
    /// Presented via `.sheet(item:)` (not `isPresented:`) so every tap gets a
    /// fresh `ComposeRequest` identity — otherwise SwiftUI can reuse the prior
    /// `SendMailView`'s `@State` selection when reopened in quick succession,
    /// leaking the previous contact's selection into the new sheet.
    private func startCompose(preselect: Set<Contact.ID>? = nil) {
        composeRequest = ComposeRequest(preselect: preselect)
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

    /// Never repeats the title. A contact with no name is already titled by its
    /// email, and falling back to the email again printed the same string twice.
    private var subtitle: String? {
        if !contact.position.isEmpty { return contact.position }
        return contact.name.isEmpty ? nil : contact.email
    }

    var body: some View {
        HStack(spacing: 12) {
            // A monogram rather than the identical envelope glyph every row used
            // to get: these are people, and the colour makes a long recruiter list
            // scannable — the same treatment they already get in Activity.
            MonogramAvatar(text: title, size: Theme.Avatar.small)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                SentPill(sentAt: contact.sentAt)
                if let onSend {
                    Button(action: onSend) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .background(.tint.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(contact.isSent ? "Send again to \(title)" : "Send to \(title)")
                }
            }
        }
        .padding(.vertical, 4)
    }
}
