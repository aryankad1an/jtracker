import SwiftUI

/// Compose and send cold mails: pick a template, choose one or more recipients
/// from the company's contacts, confirm, and send them all through the connected
/// Gmail account. Successfully sent contacts are marked sent.
struct SendMailView: View {
    let job: Job

    @Environment(JobStore.self) private var jobStore
    @Environment(TemplateStore.self) private var templateStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<Contact.ID>
    @State private var templateID: MailTemplate.ID?
    @State private var isSending = false
    @State private var sentCount = 0
    @State private var totalCount = 0
    @State private var showingPreview = false
    @State private var resultMessage: String?
    /// A snapshot of the rendered mails that the review screen can tailor per
    /// card. Rebuilt each time the user advances from the recipient list.
    @State private var editablePreviews: [MailPreview] = []

    /// - Parameter preselect: recipients to start selected. When nil, everyone
    ///   not yet sent is preselected so a bulk send is one tap.
    init(job: Job, preselect: Set<Contact.ID>? = nil) {
        self.job = job
        let sendable = job.contacts.filter { $0.email.contains("@") }
        let sendableIDs = Set(sendable.map(\.id))
        if let preselect {
            _selection = State(initialValue: preselect.intersection(sendableIDs))
        } else {
            _selection = State(initialValue: Set(sendable.filter { !$0.isSent }.map(\.id)))
        }
    }

    /// Contacts with a usable email — the ones we can send to.
    private var recipients: [Contact] {
        job.contacts.filter { $0.email.contains("@") }
    }

    private var selectedTemplate: MailTemplate? {
        templateStore.templates.first { $0.id == templateID }
    }

    private var canSend: Bool {
        gmail.isConnected && selectedTemplate != nil && !selection.isEmpty && !isSending
    }

    /// The fully rendered mails for the current template + selection, in the same
    /// order shown in the recipients list.
    private var previews: [MailPreview] {
        guard let template = selectedTemplate else { return [] }
        let profile = profileStore.profile
        return recipients
            .filter { selection.contains($0.id) }
            .map { contact in
                let context = MailContext.make(contact: contact, company: job.company, profile: profile)
                return MailPreview(
                    id: contact.id,
                    name: contact.name.isEmpty ? contact.email : contact.name,
                    email: contact.email,
                    subject: context.fill(template.subject),
                    body: context.fill(template.content)
                )
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !gmail.isConnected {
                    Label("Connect Gmail in Profile to send mail.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Section("Template") {
                    if templateStore.templates.isEmpty {
                        Text("Create a template first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Template", selection: $templateID) {
                            Text("Choose…").tag(MailTemplate.ID?.none)
                            ForEach(templateStore.templates) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }
                    }
                }

                Section {
                    ForEach(recipients) { contact in
                        Button {
                            toggle(contact.id)
                        } label: {
                            recipientRow(contact)
                        }
                    }
                } header: {
                    Text("Recipients (\(selection.count) selected)")
                }
            }
            .navigationTitle("Send Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        editablePreviews = previews
                        showingPreview = true
                    }.disabled(!canSend)
                }
            }
            .navigationDestination(isPresented: $showingPreview) {
                MailPreviewView(previews: $editablePreviews, isSending: isSending,
                                sentCount: sentCount, totalCount: totalCount) {
                    Task { await send() }
                }
            }
            .alert(
                "Send Mail",
                isPresented: Binding(get: { resultMessage != nil },
                                     set: { if !$0 { resultMessage = nil; dismiss() } })
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(resultMessage ?? "")
            }
            .onAppear {
                if templateID == nil { templateID = templateStore.templates.first?.id }
            }
        }
    }

    private func recipientRow(_ contact: Contact) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name.isEmpty ? contact.email : contact.name)
                    .foregroundStyle(.primary)
                Text(contact.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selection.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection.contains(contact.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private func toggle(_ id: Contact.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func send() async {
        let profile = profileStore.profile
        // Send exactly what's shown on the review screen — including any per-card
        // edits — rather than re-rendering from the template.
        let targets = editablePreviews
        guard !targets.isEmpty else { return }
        totalCount = targets.count
        sentCount = 0
        isSending = true

        var sent: [Contact.ID: SentMail] = [:]
        var failures: [String] = []
        for preview in targets {
            do {
                try await gmail.send(
                    to: preview.email,
                    subject: preview.subject,
                    body: preview.body,
                    fromName: profile.name
                )
                sent[preview.id] = SentMail(subject: preview.subject, body: preview.body)
                sentCount += 1   // advances the n/m progress bar
            } catch {
                failures.append(preview.email)
            }
        }
        await jobStore.markContactsSent(sent)
        isSending = false

        // On full success just close; only stop to report partial failures.
        if failures.isEmpty {
            dismiss()
        } else {
            resultMessage = "Sent \(sent.count) of \(totalCount). Failed for: \(failures.joined(separator: ", "))."
        }
    }
}

/// One fully rendered mail, ready to preview and send. Subject/body are mutable
/// so each card can be tailored on the review screen before sending.
struct MailPreview: Identifiable {
    let id: Contact.ID
    let name: String
    let email: String
    var subject: String
    var body: String
}

/// Reviews the rendered mails before sending: a single mail fills the screen, a
/// batch shows as a horizontal deck of cards with a "Send All" button below.
private struct MailPreviewView: View {
    @Binding var previews: [MailPreview]
    let isSending: Bool
    let sentCount: Int
    let totalCount: Int
    let onSendAll: () -> Void

    /// The card currently open in the edit drawer.
    @State private var editingPreview: MailPreview?

    var body: some View {
        VStack(spacing: 0) {
            if previews.count == 1, let only = previews.first {
                card(only)
                    .padding()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(previews) { preview in
                            card(preview).frame(width: 300)
                        }
                    }
                    .padding()
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
        .navigationTitle(previews.count == 1 ? "Review Mail" : "Review \(previews.count) Mails")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { sendBar }
        .sheet(item: $editingPreview) { preview in
            MailEditorView(preview: preview) { subject, body in
                apply(id: preview.id, subject: subject, body: body)
            }
        }
    }

    /// Write an edited card back into the deck so the review page updates.
    private func apply(id: MailPreview.ID, subject: String, body: String) {
        guard let index = previews.firstIndex(where: { $0.id == id }) else { return }
        previews[index].subject = subject
        previews[index].body = body
    }

    private func card(_ preview: MailPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MonogramAvatar(text: preview.name, size: Theme.Avatar.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(preview.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    editingPreview = preview
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .disabled(isSending)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("SUBJECT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(preview.subject)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("MESSAGE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    messageText(preview.body)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func messageText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sendBar: some View {
        VStack(spacing: 0) {
            Divider()
            if isSending {
                VStack(spacing: 8) {
                    ProgressView(value: Double(sentCount), total: Double(max(totalCount, 1)))
                    Text("\(sentCount)/\(totalCount) sent")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                Button(action: onSendAll) {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                        Text(previews.count == 1 ? "Send" : "Send All (\(previews.count))")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
        .background(.bar)
    }
}

/// A drawer for tailoring a single mail's subject and body before sending.
/// Edits are local until "Save", which hands them back to the review deck.
private struct MailEditorView: View {
    let name: String
    let email: String
    let onSave: (_ subject: String, _ body: String) -> Void

    @State private var subject: String
    @State private var messageBody: String
    @Environment(\.dismiss) private var dismiss

    init(preview: MailPreview, onSave: @escaping (String, String) -> Void) {
        self.name = preview.name
        self.email = preview.email
        self.onSave = onSave
        _subject = State(initialValue: preview.subject)
        _messageBody = State(initialValue: preview.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Subject") {
                    TextField("Subject", text: $subject, axis: .vertical)
                }
                Section("Message") {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 260)
                        .font(.callout)
                }
            }
            .navigationTitle("Edit Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(subject, messageBody)
                        dismiss()
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
