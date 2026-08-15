import SwiftUI

/// A noun with singular/plural forms, so selection UI copy reads correctly
/// ("1 company" vs "3 companies") without each screen hand-rolling the grammar.
struct SelectionNoun {
    let singular: String
    let plural: String

    func phrase(_ count: Int) -> String { count == 1 ? singular : plural }
}

extension View {
    /// The standard multi-select chrome shared by every list screen: a bottom
    /// action bar (shown while `isSelecting`) and the delete confirmation dialog.
    /// - Parameter deleteMessage: overrides the default warning copy for lists
    ///   whose delete cascades (e.g. removing a company drops its cold mails too).
    /// - Parameter onSend: when provided, a "Send" button appears in the bar
    ///   alongside delete (used by lists whose items can be mailed).
    /// - Parameter confirmsDelete: when false, the Delete button runs `onDelete`
    ///   immediately with no dialog — for reversible removals (e.g. untracking a
    ///   company from Home, which offers an Undo instead).
    func selectionActions(
        isSelecting: Bool,
        count: Int,
        noun: SelectionNoun,
        confirmingDelete: Binding<Bool>,
        deleteMessage: String? = nil,
        confirmsDelete: Bool = true,
        onSend: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(SelectionActions(
            isSelecting: isSelecting,
            count: count,
            noun: noun,
            confirmingDelete: confirmingDelete,
            deleteMessage: deleteMessage,
            confirmsDelete: confirmsDelete,
            onSend: onSend,
            onDelete: onDelete
        ))
    }
}

private struct SelectionActions: ViewModifier {
    let isSelecting: Bool
    let count: Int
    let noun: SelectionNoun
    @Binding var confirmingDelete: Bool
    let deleteMessage: String?
    let confirmsDelete: Bool
    let onSend: (() -> Void)?
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if isSelecting { bar }
            }
            .confirmationDialog(
                "Delete \(count) \(noun.phrase(count))?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: onDelete)
            } message: {
                Text(deleteMessage
                     ?? "This permanently removes the selected \(noun.plural). This can't be undone.")
            }
    }

    private var bar: some View {
        HStack {
            Text(count == 0 ? "Select \(noun.plural)" : "\(count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let onSend {
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.bordered)
                .disabled(count == 0)
            }
            Button(role: .destructive) {
                if confirmsDelete { confirmingDelete = true } else { onDelete() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(count == 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
