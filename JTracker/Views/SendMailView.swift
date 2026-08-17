import SwiftUI

/// Compose and send cold mails: pick a template, choose one or more recipients
/// from the company's contacts, confirm, and send them all through the connected
/// Gmail account. Successfully sent contacts are marked sent.
struct SendMailView: View {
    let job: Job

    @Environment(TemplateStore.self) private var templateStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(MailQueue.self) private var mailQueue
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<Contact.ID>
    @State private var templateID: MailTemplate.ID?
    @State private var showingPreview = false
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
        gmail.isConnected && selectedTemplate != nil && !selection.isEmpty
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
                    contact: contact,
                    company: job.company,
                    name: contact.name.isEmpty ? contact.email : contact.name,
                    email: contact.email,
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
                    ForEach(recipients) { contact in
                        Button {
                            toggle(contact.id)
                        } label: {
                            recipientRow(contact)
                        }
                        // Without this the Form paints the whole row in the accent
                        // colour, so every recipient name read as a tappable link.
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Recipients (\(selection.count) selected)")
                }
            }
            .navigationTitle("Send Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
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
        }
    }

    private func recipientRow(_ contact: Contact) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name.isEmpty ? contact.email : contact.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // Skipped when the name is already the address, which otherwise
                // printed the same string on both lines.
                if !contact.name.isEmpty {
                    Text(contact.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Already-mailed contacts start unselected. Without the pill that
            // reads as an arbitrary half-ticked list — this is the reason.
            SentPill(sentAt: contact.sentAt)
            Image(systemName: selection.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection.contains(contact.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private func toggle(_ id: Contact.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Hand the reviewed mails to the background queue and get out of the way.
    /// Exactly what's on the review screen goes out — including any per-card
    /// edits — rather than being re-rendered from the template.
    private func enqueue() {
        let mails = editablePreviews.map {
            MailQueue.Mail(id: $0.id, recipient: $0.email, displayName: $0.name,
                           subject: $0.subject, body: $0.body)
        }
        guard !mails.isEmpty else { return }
        mailQueue.enqueue(mails, fromName: profileStore.profile.name)
        dismiss()
    }
}

/// One fully rendered mail, ready to preview and send. Subject/body are mutable
/// so each card can be tailored on the review screen before sending. Carries the
/// source `contact`, `company`, and the `templateID` it was rendered from so the
/// review screen can re-render a subset when a different template is chosen.
struct MailPreview: Identifiable {
    let id: Contact.ID
    let contact: Contact
    let company: String
    let name: String
    let email: String
    var subject: String
    var body: String
    var templateID: MailTemplate.ID?
}

/// Reviews the rendered mails before sending: a single mail fills the screen, a
/// batch shows as a horizontal deck of cards with a "Send All" button below.
/// Shared by the per-company (`SendMailView`) and cross-company
/// (`SuggestedSendView`) send flows.
///
/// Sending itself is handed to `MailQueue`, so this screen dismisses as soon as
/// the button is tapped — there's no in-place progress to report.
struct MailPreviewView: View {
    @Binding var previews: [MailPreview]
    let onSendAll: () -> Void

    @Environment(TemplateStore.self) private var templateStore
    @Environment(ProfileStore.self) private var profileStore

    /// The card currently open in the edit drawer.
    @State private var editingPreview: MailPreview?
    /// nil = show all companies. Filters which cards the review deck shows so you
    /// can focus on (and re-template) one company at a time.
    @State private var companyFilter: String?

    /// Distinct companies in this batch, sorted. The per-company controls only
    /// appear when a send spans more than one.
    private var companies: [String] {
        Array(Set(previews.map(\.company)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var showsControls: Bool { companies.count > 1 }

    /// Cards matching the current company filter (all when none is set).
    private var displayed: [MailPreview] {
        guard let companyFilter else { return previews }
        return previews.filter { $0.company == companyFilter }
    }

    /// The template shared by every currently-shown card, or nil when they differ.
    private var activeTemplateID: MailTemplate.ID? {
        let ids = Set(displayed.map(\.templateID))
        return ids.count == 1 ? (ids.first ?? nil) : nil
    }

    private var activeTemplateName: String {
        guard let id = activeTemplateID,
              let template = templateStore.templates.first(where: { $0.id == id }) else { return "Mixed" }
        return template.name
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
                controlBar
                Divider()
            }
            deck
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

    @ViewBuilder
    private var deck: some View {
        if displayed.count == 1, let only = displayed.first {
            card(only)
                .padding()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(displayed) { preview in
                        card(preview).frame(width: 300)
                    }
                }
                .padding()
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    /// A per-company review bar: filter the deck by company (left) and set the
    /// template for whatever's currently shown (right) — so different companies
    /// can go out on different templates in one bulk send.
    private var controlBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    companyFilter = nil
                } label: {
                    if companyFilter == nil {
                        Label("All companies", systemImage: "checkmark")
                    } else {
                        Text("All companies")
                    }
                }
                Divider()
                ForEach(companies, id: \.self) { company in
                    Button {
                        companyFilter = company
                    } label: {
                        if companyFilter == company {
                            Label(company, systemImage: "checkmark")
                        } else {
                            Text(company)
                        }
                    }
                }
            } label: {
                Label(companyFilter ?? "All companies", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                if templateStore.templates.isEmpty {
                    Text("No templates")
                } else {
                    ForEach(templateStore.templates) { template in
                        Button {
                            applyTemplate(template)
                        } label: {
                            if activeTemplateID == template.id {
                                Label(template.name, systemImage: "checkmark")
                            } else {
                                Text(template.name)
                            }
                        }
                    }
                }
            } label: {
                Label(activeTemplateName, systemImage: "doc.plaintext")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .disabled(templateStore.templates.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// Re-render the currently-shown cards from `template`, replacing their earlier
    /// render (and any manual edits) for just that filtered set of companies.
    private func applyTemplate(_ template: MailTemplate) {
        let profile = profileStore.profile
        let ids = Set(displayed.map(\.id))
        for index in previews.indices where ids.contains(previews[index].id) {
            let context = MailContext.make(contact: previews[index].contact,
                                           company: previews[index].company, profile: profile)
            previews[index].subject = context.fill(template.subject)
            previews[index].body = context.fill(template.content)
            previews[index].templateID = template.id
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
                .accessibilityLabel("Edit mail to \(preview.name)")
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
        .background(.bar)
    }
}

/// A drawer for tailoring a single mail's subject and body before sending.
/// Edits are local until "Save", which hands them back to the review deck.
struct MailEditorView: View {
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
                        onSave(subject.sanitizedLineSeparators, messageBody.sanitizedLineSeparators)
                        dismiss()
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
