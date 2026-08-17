import SwiftUI

/// Add or edit a mail template.
///
/// The editor is built around one idea: a template is never wrong on its own —
/// it's wrong against *your* profile and *your* contacts, and you only find out
/// after the mail has gone to a hundred recruiters. So the two halves of the
/// screen answer that directly. **Write** is a full-height composer with the
/// placeholder chips on the keyboard, where a status strip flags tokens that
/// aren't real, tokens your profile can't fill, and tokens your contacts are
/// missing. **Preview** renders the mail against a real contact, marking every
/// substitution — and every hole a substitution leaves behind.
struct TemplateEditorView: View {
    let existing: MailTemplate?
    let onSave: (MailTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(JobStore.self) private var jobStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(GmailAuthStore.self) private var gmail

    @State private var name: String
    @State private var subject: String
    @State private var content: String
    @State private var contentSelection: TextSelection?
    @State private var subjectSelection: TextSelection?
    @State private var mode: Mode = .write
    @State private var showingIssues = false
    @State private var sampleContactID: Contact.ID?
    @State private var confirmingTestSend = false
    @State private var confirmingSaveWithErrors = false
    @State private var testSendResult: String?
    @State private var isTestSending = false
    @FocusState private var focus: Field?

    private enum Mode: Hashable { case write, preview }
    private enum Field: Hashable { case name, subject, content }

    init(existing: MailTemplate?, onSave: @escaping (MailTemplate) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let t = existing ?? MailTemplate(name: "", subject: "", content: "")
        _name = State(initialValue: t.name)
        _subject = State(initialValue: t.subject)
        _content = State(initialValue: t.content)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Diagnostics

    /// Every contact in the catalog, used both as preview subjects and as the
    /// sample the diagnostics measure "how many are missing this?" against.
    private var allContacts: [(contact: Contact, company: String)] {
        jobStore.allCompanies.flatMap { company in
            company.contacts.map { (contact: $0, company: company.company) }
        }
    }

    private var findings: [TemplateFinding] {
        TemplateDiagnostics.analyze(
            subject: subject,
            content: content,
            profile: profileStore.profile,
            contacts: allContacts.map(\.contact)
        )
    }

    private var errorCount: Int { findings.filter { $0.severity == .error }.count }

    // MARK: - Preview subject

    /// A stand-in when the account has no contacts yet, so Preview is never a
    /// blank screen — you can still see the shape of the mail before your first
    /// company is tracked.
    private static let demoContact = (
        contact: Contact(id: "preview-demo", email: "priya.raghavan@example.com",
                         name: "Priya Raghavan", position: "University Recruiter"),
        company: "Acme Robotics"
    )

    private var sample: (contact: Contact, company: String) {
        if let sampleContactID, let match = allContacts.first(where: { $0.contact.id == sampleContactID }) {
            return match
        }
        return allContacts.first ?? Self.demoContact
    }

    private var sampleContext: MailContext {
        MailContext.make(contact: sample.contact, company: sample.company,
                         profile: profileStore.profile)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modePicker
                Divider()
                statusStrip

                switch mode {
                case .write: writePane
                case .preview: previewPane
                }
            }
            .navigationTitle(existing == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog("Send a test to yourself?",
                                isPresented: $confirmingTestSend, titleVisibility: .visible) {
                Button("Send to \(gmail.connectedEmail ?? "me")") { Task { await sendTest() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This sends one real mail to your own inbox, rendered with \(sample.contact.name.isEmpty ? "the sample contact" : sample.contact.name)'s details.")
            }
            .confirmationDialog("Save with \(errorCount) unresolved \(errorCount == 1 ? "issue" : "issues")?",
                                isPresented: $confirmingSaveWithErrors, titleVisibility: .visible) {
                Button("Save Anyway") { commit() }
                Button("Keep Editing", role: .cancel) { showingIssues = true }
            } message: {
                Text("Text that isn't a real placeholder is sent to recruiters exactly as written.")
            }
            .alert("Test Mail", isPresented: Binding(get: { testSendResult != nil },
                                                     set: { if !$0 { testSendResult = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(testSendResult ?? "")
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Write").tag(Mode.write)
            Text("Preview").tag(Mode.preview)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        // Cancel and Save are the only bar items: with a third, the glass pills
        // squeeze the title until "Edit Template" truncates to "Edit Tem…". The
        // test send moved into Preview, where it reads better anyway — you look
        // at the render, then mail it to yourself.
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                if errorCount > 0 { confirmingSaveWithErrors = true } else { commit() }
            }
            .disabled(!isValid)
        }
        // Placeholder chips live on the keyboard, so they're present exactly when
        // you're typing and cost no layout when you aren't.
        ToolbarItemGroup(placement: .keyboard) {
            if focus == .subject || focus == .content {
                placeholderBar
            }
        }
    }

    // MARK: - Write

    private var writePane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                fieldRow("Name") {
                    TextField("e.g. Cold Outreach", text: $name)
                        .focused($focus, equals: .name)
                }
                Divider().padding(.leading, 14)
                fieldRow("Subject") {
                    // Vertical axis so a long subject wraps instead of scrolling
                    // out of sight — a cold mail's subject carries the credentials
                    // and you need to read all of it while editing.
                    TextField("Subject", text: $subject, selection: $subjectSelection,
                              axis: .vertical)
                        .focused($focus, equals: .subject)
                        .lineLimit(1...4)
                }
            }
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .padding(.top, 12)

            TextEditor(text: $content, selection: $contentSelection)
                .focused($focus, equals: .content)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("Write your mail. Tap a placeholder below the keyboard to drop in a name, company, or your resume link.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 6)
        }
    }

    /// Label above the field rather than beside it. A side label needs a fixed
    /// column, which both steals width from the value and breaks down at larger
    /// Dynamic Type sizes; stacked, the value always gets the full card width and
    /// nothing has to truncate.
    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            field()
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The placeholder chips, sitting on the keyboard accessory bar.
    private var placeholderBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(MailPlaceholder.allCases) { placeholder in
                        Button {
                            insert(placeholder.token)
                        } label: {
                            Text(placeholder.shortLabel)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)

            Button("Done") { focus = nil }
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 12)
        }
    }

    // MARK: - Preview

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                samplePicker

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        MonogramAvatar(text: sample.contact.name.isEmpty ? sample.contact.email : sample.contact.name,
                                       size: Theme.Avatar.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.contact.name.isEmpty ? sample.contact.email : sample.contact.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(sample.contact.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUBJECT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(rendered(subject))
                            .font(.subheadline.weight(.semibold))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("MESSAGE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(rendered(content))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                legend
                testSendButton
            }
            .padding()
        }
    }

    /// Moved here from the toolbar: it belongs beside the thing it sends, and it
    /// keeps the nav bar down to two items so the title has room.
    @ViewBuilder
    private var testSendButton: some View {
        VStack(spacing: 6) {
            Button {
                confirmingTestSend = true
            } label: {
                HStack(spacing: 6) {
                    if isTestSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(isTestSending ? "Sending…" : "Send a test to myself")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!gmail.isConnected || !isValid || isTestSending)

            Text(gmail.isConnected
                 ? "Goes to your own inbox — the only way to see how it really lands."
                 : "Connect Gmail in Profile to send a test.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    private var samplePicker: some View {
        Menu {
            ForEach(allContacts, id: \.contact.id) { item in
                Button {
                    sampleContactID = item.contact.id
                } label: {
                    Text("\(displayName(item.contact)) · \(item.company)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                // Two lines rather than one: recruiter names run long, and at
                // larger text sizes a single line clips the very name it's
                // telling you about.
                Text("Previewing as \(displayName(sample.contact))")
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline.weight(.medium))
        }
        .disabled(allContacts.isEmpty)
    }

    private func displayName(_ contact: Contact) -> String {
        contact.name.isEmpty ? contact.email : contact.name
    }

    /// Side by side when there's room, stacked when there isn't — at larger text
    /// sizes the two labels can't share a line, and truncating a legend defeats
    /// the point of having one.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                legendItem(color: .accentColor, text: "Filled in")
                legendItem(color: .red, text: "Blank or not a placeholder")
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 5) {
                legendItem(color: .accentColor, text: "Filled in")
                legendItem(color: .red, text: "Blank or not a placeholder")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.3)).frame(width: 14, height: 10)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Render a template string the way the recruiter will receive it, but with
    /// the seams left visible: substituted values are tinted, and anything that
    /// resolves to nothing becomes a labelled red marker instead of collapsing
    /// into an invisible gap. The marker is the whole point — an empty position
    /// silently turns "as a {Receiver-Position} at Acme" into "as a  at Acme",
    /// which is impossible to notice in a plain render.
    private func rendered(_ text: String) -> AttributedString {
        let context = sampleContext
        let ns = text as NSString
        var out = AttributedString()
        var cursor = 0

        guard let regex = try? NSRegularExpression(pattern: "\\{[^{}]*\\}") else {
            return AttributedString(text)
        }

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: cursor,
                                                              length: match.range.location - cursor)))
            let literal = ns.substring(with: match.range)

            if let placeholder = MailPlaceholder(rawValue: literal) {
                let value = context.values[placeholder] ?? ""
                if value.trimmingCharacters(in: .whitespaces).isEmpty {
                    out += marker("⟨\(placeholder.blankLabel) missing⟩")
                } else {
                    var filled = AttributedString(value)
                    filled.backgroundColor = .accentColor.opacity(0.18)
                    out += filled
                }
            } else {
                out += marker(literal)
            }
            cursor = match.range.location + match.range.length
        }

        out += AttributedString(ns.substring(from: cursor))
        return out
    }

    private func marker(_ text: String) -> AttributedString {
        var chunk = AttributedString(text)
        chunk.backgroundColor = .red.opacity(0.18)
        chunk.foregroundColor = .red
        return chunk
    }

    // MARK: - Status strip

    /// Sits directly under the mode picker, and only when there's something wrong
    /// — a clean template says nothing rather than spending a row to say so. It
    /// expands downward in place instead of opening a modal over the text you'd
    /// need to edit to fix the problem.
    @ViewBuilder
    private var statusStrip: some View {
        if !findings.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showingIssues.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showingIssues ? 180 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showingIssues {
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(findings) { finding in
                                findingRow(finding)
                                if finding.id != findings.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                    .background(Color(.secondarySystemBackground))
                }

                Divider()
            }
            .background(.bar)
        }
    }

    private var statusIcon: String {
        errorCount > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        errorCount > 0 ? .red : .orange
    }

    private var statusText: String {
        let count = findings.count
        return "\(count) \(count == 1 ? "issue" : "issues") to check"
    }

    private func findingRow(_ finding: TemplateFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .error
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(finding.severity == .error ? .red : .orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if let token = finding.token, let suggestion = finding.suggestion {
                Button("Fix") { replace(token, with: suggestion) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Editing

    /// Insert a token at the caret of whichever field is focused. Both fields go
    /// through the same path, so the subject no longer appends blindly to the end
    /// while the body inserts properly.
    private func insert(_ token: String) {
        switch focus {
        case .subject:
            subject = inserting(token, into: subject, at: subjectSelection)
            subjectSelection = caret(after: token, in: subject, from: subjectSelection)
        case .content:
            content = inserting(token, into: content, at: contentSelection)
            contentSelection = caret(after: token, in: content, from: contentSelection)
        default:
            break
        }
    }

    private func inserting(_ token: String, into text: String, at selection: TextSelection?) -> String {
        guard let selection, case .selection(let range) = selection.indices else {
            return text + token
        }
        var copy = text
        copy.replaceSubrange(range, with: token)
        return copy
    }

    /// Where the caret should land after an insert: just past the token that was
    /// dropped in, so you can keep typing.
    private func caret(after token: String, in text: String, from selection: TextSelection?) -> TextSelection? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        // `range` indexes the pre-edit string; its offset is still valid because
        // everything before the insertion point is unchanged.
        let offset = min(text.distance(from: text.startIndex, to: range.lowerBound) + token.count,
                         text.count)
        guard let position = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else {
            return nil
        }
        return TextSelection(range: position..<position)
    }

    private func replace(_ token: String, with suggestion: String) {
        subject = subject.replacingOccurrences(of: token, with: suggestion)
        content = content.replacingOccurrences(of: token, with: suggestion)
    }

    private func commit() {
        onSave(MailTemplate(
            id: existing?.id ?? UUID(),
            name: name.sanitizedLineSeparators,
            subject: subject.sanitizedLineSeparators,
            content: content.sanitizedLineSeparators
        ))
        dismiss()
    }

    /// Send the previewed render to the signed-in account. Nothing else in the
    /// app shows what actually lands — line breaks, subject truncation, whether
    /// the resume link is clickable — until it's already gone to a recruiter.
    private func sendTest() async {
        guard let address = gmail.connectedEmail else { return }
        isTestSending = true
        defer { isTestSending = false }

        let context = sampleContext
        do {
            try await gmail.send(
                to: address,
                subject: "[Test] " + context.fill(subject),
                body: context.fill(content),
                fromName: profileStore.profile.name
            )
            testSendResult = "Sent to \(address). Open it on your phone to see exactly what a recruiter gets."
        } catch {
            testSendResult = error.localizedDescription
        }
    }
}

#Preview {
    TemplateEditorView(existing: nil) { _ in }
        .environment(JobStore())
        .environment(ProfileStore())
        .environment(GmailAuthStore())
}
