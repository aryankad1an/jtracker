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
    /// - Parameter onTrack: when provided, a "Track" button appears in the bar
    ///   alongside delete (used by the Companies list).
    /// - Parameter confirmsDelete: when false, the Delete button runs `onDelete`
    ///   immediately with no dialog — for reversible removals (e.g. untracking a
    ///   company from Home, which offers an Undo instead).
    /// - Parameter deletableCount: how many of the selection can actually be
    ///   deleted, when that differs from `count` (some rows are protected). Drives
    ///   the confirmation copy so it never promises more than it will do.
    /// - Parameter trackAction: the constructive bulk action for lists that have
    ///   one, with its own label so it can read "Track" or "Untrack".
    func selectionActions(
        isSelecting: Bool,
        count: Int,
        noun: SelectionNoun,
        confirmingDelete: Binding<Bool>,
        deleteMessage: String? = nil,
        confirmsDelete: Bool = true,
        deletableCount: Int? = nil,
        onSend: (() -> Void)? = nil,
        trackAction: SelectionBulkAction? = nil,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(SelectionActions(
            isSelecting: isSelecting,
            count: count,
            noun: noun,
            confirmingDelete: confirmingDelete,
            deleteMessage: deleteMessage,
            confirmsDelete: confirmsDelete,
            deletableCount: deletableCount,
            onSend: onSend,
            trackAction: trackAction,
            onDelete: onDelete
        ))
    }
}

/// A labelled bulk action for the selection bar, so one slot can present itself
/// as "Track" or "Untrack" depending on what's selected.
struct SelectionBulkAction {
    let title: String
    let systemImage: String
    let action: () -> Void
}

private struct SelectionActions: ViewModifier {
    let isSelecting: Bool
    let count: Int
    let noun: SelectionNoun
    @Binding var confirmingDelete: Bool
    let deleteMessage: String?
    let confirmsDelete: Bool
    let deletableCount: Int?
    let onSend: (() -> Void)?
    let trackAction: SelectionBulkAction?
    let onDelete: () -> Void

    /// What the delete will really remove.
    private var effectiveDeleteCount: Int { deletableCount ?? count }

    private var deleteTitle: String {
        let deletable = effectiveDeleteCount
        guard let deletableCount, deletableCount != count else {
            return "Delete \(deletable) \(noun.phrase(deletable))?"
        }
        return "Delete \(deletableCount) of \(count) \(noun.phrase(count))?"
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if isSelecting { bar }
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
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
            if let trackAction {
                Button(action: trackAction.action) {
                    Label(trackAction.title, systemImage: trackAction.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
            if let onSend {
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
            // Bordered, not prominent. Delete here is irreversible, cascades to a
            // shared catalog, and affects every user — it should be reachable, not
            // the brightest thing on screen inviting a tap.
            Button(role: .destructive) {
                if confirmsDelete { confirmingDelete = true } else { onDelete() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(count == 0 || effectiveDeleteCount == 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
