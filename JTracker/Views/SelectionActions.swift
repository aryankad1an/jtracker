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
    ///   whose delete cascades (e.g. removing a company drops its mails too).
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
        confirmingDelete: Binding<Bool> = .constant(false),
        deleteMessage: String? = nil,
        confirmsDelete: Bool = true,
        deletableCount: Int? = nil,
        sendableCount: Int? = nil,
        onSend: (() -> Void)? = nil,
        bulkAction: SelectionBulkAction? = nil,
        onDelete: (() -> Void)? = nil
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
    let onDelete: (() -> Void)?

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
            // No `.animation(value: isSelecting)` here: `ListSelection` already
            // changes the mode inside `withAnimation`. A second, screen-wide
            // animation re-animated every row of the list along with the bar.
            .safeAreaInset(edge: .bottom) {
                if isSelecting { bar }
            }
            .uniformDeleteAlert(
                title: deleteTitle,
                message: deleteMessage ?? "Are you sure you want to permanently delete the selected \(noun.plural)? This action cannot be undone.",
                isPresented: $confirmingDelete,
                onDelete: { onDelete?() }
            )
    }

    /// The selection count, as a badge that can never be squeezed out.
    ///
    /// It used to be the sentence "6 selected", laid out as the flexible element
    /// beside three intrinsically-sized buttons — so it was the first thing the
    /// buttons took width from. On a phone showing a bulk action, Send and Delete
    /// there was nothing left, and the label rendered as a bare "…": the one piece
    /// of state this bar exists to report was the one thing it couldn't show.
    ///
    /// A figure in a capsule fixes that three ways over. It costs about a third of
    /// the width of the sentence, `fixedSize` means it holds that width against
    /// any set of buttons, and a filled clay capsule is read before any of the
    /// words around it — which is right, because in selection mode the count *is*
    /// the state. The word "selected" was never carrying anything: every row on
    /// screen has a tick beside it.
    private var countBadge: some View {
        Group {
            if count == 0 {
                Text("Select")
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
            } else {
                Text("\(count)")
                    // A serif figure, like every other number in the app.
                    .font(.display(17, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.paper)
                    // Room for two digits before it has to grow, so ticking from
                    // 9 to 10 doesn't shove the buttons sideways.
                    .frame(minWidth: 22)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.clay, in: Capsule())
                    .transition(LiquidMaterialize(scale: 0.5, blur: 4))
            }
        }
        .fixedSize()
        // Wins every width negotiation in the bar.
        .layoutPriority(1)
        .animation(Theme.Motion.pop, value: count)
        // The badge drops the noun the sentence carried, so VoiceOver restates it.
        .accessibilityLabel(count == 0
                            ? "Nothing selected"
                            : "\(count) \(noun.phrase(count)) selected")
    }

    /// Send and Delete are icon-only; the screen's own bulk action keeps its words.
    ///
    /// Three labelled buttons plus the count don't fit a phone width — they wrapped
    /// mid-word into "Sen d" / "Delet e". A paperplane and a trash can are the two
    /// most legible glyphs in the system and need no caption, whereas "Mark
    /// Invalid" vs "Mark Valid" is the whole point of that button, so that's the
    /// one that keeps its text (and `lineLimit`, so it can never wrap again).
    private var bar: some View {
        // The bar is the glass; its buttons are solid fills on it. Glass
        // buttons on a glass bar are two panes rendering at once, and they
        // trailed the bar by a frame whenever it moved.
        HStack(spacing: 10) {
            countBadge
            Spacer(minLength: 6)
            if let bulkAction {
                Button(action: bulkAction.action) {
                    Label(bulkAction.title, systemImage: bulkAction.systemImage)
                        .lineLimit(1)
                        // Scales rather than truncating. This is now the flexible
                        // element in the bar — it gives up width before the count
                        // does, because "Mark Invali…" still reads as the action
                        // while a clipped count reads as nothing at all.
                        .minimumScaleFactor(0.8)
                        // The glyph bounces when the button flips meaning —
                        // Track to Untrack, Mark Invalid to Mark Valid — which is
                        // the one moment this slot changes under the user's thumb.
                        .symbolEffect(.bounce, value: bulkAction.systemImage)
                }
                .filledButton(bulkAction.tint ?? .clay)
                .disabled(count == 0)
            }
            if let onSend {
                Button {
                    Haptics.press()
                    onSend()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .labelStyle(.iconOnly)
                }
                .primaryButton()
                .disabled(count == 0 || effectiveSendCount == 0)
                .accessibilityLabel("Send")
            }
            if let onDelete {
                Button(role: .destructive) {
                    if confirmsDelete {
                        Haptics.warning()
                        confirmingDelete = true
                    } else {
                        Haptics.thud()
                        onDelete()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .secondaryButton()
                .tint(.danger)
                .disabled(count == 0 || effectiveDeleteCount == 0)
                .accessibilityLabel("Delete")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Glass, and floating rather than docked: this bar sits *over* the list
        // it acts on, and the material is what keeps the rows legible sliding
        // underneath it. A solid bar in the same paper as the rows read as the
        // end of the list rather than as a layer above it.
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.card))
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.bottom, 6)
        // The bar grows up out of the bottom edge rather than sliding in at full
        // size, matching Home's undo capsule — both are the same kind of object.
        .transition(.glassRise)
        // Every tick and untick of a row is a detent, felt through the bar that
        // counts them rather than through each row separately.
        .sensoryFeedback(.selection, trigger: count)
    }
}
