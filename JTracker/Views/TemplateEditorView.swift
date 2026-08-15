import SwiftUI

/// Add or edit a mail template. Tap a placeholder chip to insert it at the
/// cursor position in the focused field. A live preview highlights placeholders.
struct TemplateEditorView: View {
    let existing: MailTemplate?
    let onSave: (MailTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var subject: String
    @State private var content: String
    @State private var contentSelection: TextSelection?
    @FocusState private var focus: Field?

    private enum Field { case subject, content }

    init(existing: MailTemplate?, onSave: @escaping (MailTemplate) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let t = existing ?? MailTemplate(name: "", subject: "", content: "")
        _name = State(initialValue: t.name)
        _subject = State(initialValue: t.subject)
        _content = State(initialValue: t.content)
    }

    private var isValid: Bool {
        !name.isEmpty && !subject.isEmpty && !content.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template Name") {
                    TextField("e.g. Cold Outreach", text: $name)
                }
                Section("Subject") {
                    TextField("Subject", text: $subject)
                        .focused($focus, equals: .subject)
                }
                Section("Content") {
                    TextEditor(text: $content, selection: $contentSelection)
                        .frame(minHeight: 200)
                        .focused($focus, equals: .content)
                }
                Section("Insert Placeholder") {
                    placeholderGrid
                }
            }
            .navigationTitle(existing == nil ? "New Template" : "Edit Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(MailTemplate(
                            id: existing?.id ?? UUID(),
                            name: name,
                            subject: subject,
                            content: content
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var placeholderGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
            spacing: 8
        ) {
            ForEach(MailPlaceholder.allCases) { placeholder in
                Button {
                    insert(placeholder.token)
                } label: {
                    Text(placeholder.token)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    /// Insert a token at the cursor in the focused field (falls back to append).
    private func insert(_ token: String) {
        if focus == .subject {
            subject += token
            return
        }
        guard let selection = contentSelection,
              case .selection(let range) = selection.indices else {
            content += token
            return
        }
        let startOffset = content.distance(from: content.startIndex, to: range.lowerBound)
        content.replaceSubrange(range, with: token)
        if let caret = content.index(content.startIndex,
                                     offsetBy: startOffset + token.count,
                                     limitedBy: content.endIndex) {
            contentSelection = TextSelection(range: caret..<caret)
        }
    }
}
