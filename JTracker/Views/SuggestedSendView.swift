import SwiftUI

/// Compose and send cold mails to Home's "Suggested" list — contacts spread
/// across many companies that haven't been mailed in the last month. Pick one
/// template, review the rendered deck, and send them all through Gmail. Mirrors
/// `SendMailView`, but its recipients span companies rather than one.
struct SuggestedSendView: View {
    let recipients: [(contact: Contact, company: String)]
    /// Called instead of the local `dismiss()` once every mail sends
    /// successfully, so the presenter can also close the selection view
    /// behind this one rather than leaving it open on stale companies.
    var onSent: (() -> Void)?

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
    /// A snapshot of the rendered mails the review screen can tailor per card.
    @State private var editablePreviews: [MailPreview] = []

    init(recipients: [(contact: Contact, company: String)], onSent: (() -> Void)? = nil) {
        self.recipients = recipients
        self.onSent = onSent
        _selection = State(initialValue: Set(recipients.map(\.contact.id)))
    }

    private var selectedTemplate: MailTemplate? {
        templateStore.templates.first { $0.id == templateID }
    }

    private var canSend: Bool {
        gmail.isConnected && selectedTemplate != nil && !selection.isEmpty && !isSending
    }

    /// The fully rendered mails for the current template + selection, each filled
    /// with its own company.
    private var previews: [MailPreview] {
        guard let template = selectedTemplate else { return [] }
        let profile = profileStore.profile
        return recipients
            .filter { selection.contains($0.contact.id) }
            .map { item in
                let context = MailContext.make(contact: item.contact, company: item.company, profile: profile)
                return MailPreview(
                    id: item.contact.id,
                    contact: item.contact,
                    company: item.company,
                    name: item.contact.name.isEmpty ? item.contact.email : item.contact.name,
                    email: item.contact.email,
                    subject: context.fill(template.subject),
                    body: context.fill(template.content),
                    templateID: template.id
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
                    ForEach(recipients, id: \.contact.id) { item in
                        Button {
                            toggle(item.contact.id)
                        } label: {
                            recipientRow(item.contact, company: item.company)
                        }
                    }
                } header: {
                    Text("Recipients (\(selection.count) selected)")
                }
            }
            .navigationTitle("Send to All")
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

    private func recipientRow(_ contact: Contact, company: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name.isEmpty ? contact.email : contact.name)
                    .foregroundStyle(.primary)
                Text("\(company) · \(contact.email)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                sentCount += 1
            } catch {
                failures.append(preview.email)
            }
        }
        await jobStore.markContactsSent(sent)
        isSending = false

        if failures.isEmpty {
            if let onSent {
                onSent()
            } else {
                dismiss()
            }
        } else {
            resultMessage = "Sent \(sent.count) of \(totalCount). Failed for: \(failures.joined(separator: ", "))."
        }
    }
}
