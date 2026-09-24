import SwiftUI

/// One request to open `SuggestedSendView`, so `.sheet(item:)` builds a fresh
/// compose screen per batch.
struct SendBatch: Identifiable {
    let id = UUID()
    /// What the compose screen is titled — which group this is.
    var title = "Send to All"
    let recipients: [(contact: Contact, company: String)]
}

/// Compose and send mails to Home's "Suggested" list — contacts spread
/// across many companies that haven't been mailed in the last month. Pick one
/// template, review the rendered deck, and send them all through Gmail. Mirrors
/// `SendMailView`, but its recipients span companies rather than one.
struct SuggestedSendView: View {
    var title = "Send to All"
    let recipients: [(contact: Contact, company: String)]
    /// Called instead of the local `dismiss()` once every mail sends
    /// successfully, so the presenter can also close the selection view
    /// behind this one rather than leaving it open on stale companies.
    var onSent: (() -> Void)?

    @Environment(TemplateStore.self) private var templateStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(MailQueue.self) private var mailQueue
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<Contact.ID>
    @State private var templateID: MailTemplate.ID?
    @State private var showingPreview = false
    /// A snapshot of the rendered mails the review screen can tailor per card.
    @State private var editablePreviews: [MailPreview] = []

    init(title: String = "Send to All", recipients: [(contact: Contact, company: String)],
         onSent: (() -> Void)? = nil) {
        self.title = title
        self.recipients = recipients
        self.onSent = onSent
        _selection = State(initialValue: Set(recipients.map(\.contact.id)))
    }

    private var selectedTemplate: MailTemplate? {
        templateStore.templates.first { $0.id == templateID }
    }

    private var canSend: Bool {
        gmail.isConnected && selectedTemplate != nil && !selection.isEmpty
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
                    name: item.contact.displayName,
                    email: item.contact.email,
                    subject: context.fill(template.subject),
                    body: context.fill(template.content),
                    templateID: template.id
                )
            }
    }

    var body: some View {
        NavigationStack {
            PaperForm {
                if !gmail.isConnected {
                    Label("Connect Gmail in Profile to send mail.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.kraft)
                }

                Section("Template") {
                    if templateStore.templates.isEmpty {
                        Text("Create a template first.").foregroundStyle(.inkMuted)
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
                        // Otherwise the Form tints the whole row, making every
                        // recipient name look like a link.
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Recipients (\(selection.count) selected)")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        Haptics.press()
                        editablePreviews = previews
                        showingPreview = true
                    }.disabled(!canSend)
                }
            }
            .navigationDestination(isPresented: $showingPreview) {
                MailPreviewView(previews: $editablePreviews) { enqueue() }
            }
            .onAppear {
                if templateID == nil { templateID = templateStore.templates.first?.id }
            }
            .sensoryFeedback(.selection, trigger: templateID)
        }
    }

    private func recipientRow(_ contact: Contact, company: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .foregroundStyle(.ink)
                Text("\(company) · \(contact.email)")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }
            Spacer()
            let isOn = selection.contains(contact.id)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: isOn)
                .scaleEffect(isOn ? 1.1 : 1)
                .animation(Theme.Motion.pop, value: isOn)
        }
    }

    private func toggle(_ id: Contact.ID) {
        Haptics.select()
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Hand the reviewed mails to the background queue and close. Exactly what's
    /// on the review screen goes out — including any per-card edits — rather than
    /// being re-rendered from the template.
    private func enqueue() {
        let mails = editablePreviews.map {
            MailQueue.Mail(id: $0.id, recipient: $0.email, displayName: $0.name,
                           subject: $0.subject, body: $0.body)
        }
        guard !mails.isEmpty else { return }
        // The same rising run the per-company send plays — this is the same act,
        // just spread across companies.
        Haptics.cascade(mails.count)
        mailQueue.enqueue(mails, fromName: profileStore.profile.name)

        // The suggestions these came from are about to go stale, so let the
        // presenter close the whole drawer rather than leaving it on companies
        // whose contacts are now queued.
        if let onSent { onSent() } else { dismiss() }
    }
}
