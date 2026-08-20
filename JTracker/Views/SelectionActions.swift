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
    /// - Parameter deletableCount: how many of the selection can actually be
    ///   deleted, when that differs from `count` (some rows are protected). Drives
    ///   the confirmation copy so it never promises more than it will do.
    /// - Parameter sendableCount: how many of the selection can actually be mailed,
    ///   when that differs from `count` (invalid contacts can't). Disables Send
    ///   rather than opening a compose sheet with nobody in it.
    /// - Parameter bulkAction: the screen's own constructive bulk action, with its
    ///   own label so one slot can read "Track"/"Untrack" or "Mark Invalid"/"Mark
    ///   Valid" depending on what's selected.
    func selectionActions(
        isSelecting: Bool,
        count: Int,
        noun: SelectionNoun,
        confirmingDelete: Binding<Bool>,
        deleteMessage: String? = nil,
        confirmsDelete: Bool = true,
        deletableCount: Int? = nil,
        sendableCount: Int? = nil,
        onSend: (() -> Void)? = nil,
        bulkAction: SelectionBulkAction? = nil,
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
            sendableCount: sendableCount,
            onSend: onSend,
            bulkAction: bulkAction,
            onDelete: onDelete
        ))
    }
}

/// A labelled bulk action for the selection bar, so one slot can present itself
/// as "Track"/"Untrack" or "Mark Invalid"/"Mark Valid" depending on what's
/// selected. `tint` colours the button when the action carries a meaning of its
/// own — orange for ruling contacts out, green for putting them back.
struct SelectionBulkAction {
    let title: String
    let systemImage: String
    var tint: Color? = nil
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
    let sendableCount: Int?
    let onSend: (() -> Void)?
    let bulkAction: SelectionBulkAction?
    let onDelete: () -> Void

    /// What the delete will really remove.
    private var effectiveDeleteCount: Int { deletableCount ?? count }

    /// How many of the selection can actually be mailed.
    private var effectiveSendCount: Int { sendableCount ?? count }

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

    /// Send and Delete are icon-only; the screen's own bulk action keeps its words.
    ///
    /// Three labelled buttons plus the count don't fit a phone width — they wrapped
    /// mid-word into "Sen d" / "Delet e". A paperplane and a trash can are the two
    /// most legible glyphs in the system and need no caption, whereas "Mark
    /// Invalid" vs "Mark Valid" is the whole point of that button, so that's the
    /// one that keeps its text (and `fixedSize`, so it can never wrap again).
    private var bar: some View {
        HStack(spacing: 10) {
            Text(count == 0 ? "Select" : "\(count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if let bulkAction {
                Button(action: bulkAction.action) {
                    Label(bulkAction.title, systemImage: bulkAction.systemImage)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(bulkAction.tint ?? .accentColor)
                .fixedSize()
                .disabled(count == 0)
            }
            if let onSend {
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0 || effectiveSendCount == 0)
                .accessibilityLabel("Send")
            }
            // Bordered, not prominent. Delete here is irreversible, cascades to a
            // shared catalog, and affects every user — it should be reachable, not
            // the brightest thing on screen inviting a tap.
            Button(role: .destructive) {
                if confirmsDelete { confirmingDelete = true } else { onDelete() }
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(count == 0 || effectiveDeleteCount == 0)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
