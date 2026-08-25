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
            .animation(Theme.Motion.bouncy, value: isSelecting)
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: onDelete)
            } message: {
                Text(deleteMessage
                     ?? "This permanently removes the selected \(noun.plural). This can't be undone.")
            }
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
                    .foregroundStyle(.white)
                    // Room for two digits before it has to grow, so ticking from
                    // 9 to 10 doesn't shove the buttons sideways.
                    .frame(minWidth: 22)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.clay, in: Capsule())
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
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
                .buttonStyle(.borderedProminent)
                .tint(bulkAction.tint ?? .accentColor)
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
                .buttonStyle(.borderedProminent)
                .disabled(count == 0 || effectiveSendCount == 0)
                .accessibilityLabel("Send")
            }
            // Bordered, not prominent. Delete here is irreversible, cascades to a
            // shared catalog, and affects every user — it should be reachable, not
            // the brightest thing on screen inviting a tap.
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
            .buttonStyle(.bordered)
            .tint(.danger)
            .disabled(count == 0 || effectiveDeleteCount == 0)
            .accessibilityLabel("Delete")
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
        .transition(.move(edge: .bottom)
            .combined(with: .scale(scale: 0.92, anchor: .bottom))
            .combined(with: .opacity))
        // Every tick and untick of a row is a detent, felt through the bar that
        // counts them rather than through each row separately.
        .sensoryFeedback(.selection, trigger: count)
    }
}

// MARK: - Hold to select

/// The shared shape of "a hold started a selection", so every list in the app
/// enters the mode after the same delay and with the same knock.
enum SelectionHold {
    /// Long enough that a scroll flick or a slow tap can't trigger it, short
    /// enough that the mode arrives while the finger is still down. iOS's own
    /// lists sit in this range.
    static let duration = 0.45

    /// A hold has no visible target and nothing on screen to press, so the knock
    /// *is* the affordance: it's the only thing that tells the user the mode has
    /// arrived, and it lands before the checkmarks have finished animating in.
    @MainActor
    static func begin(_ action: () -> Void) {
        Haptics.press()
        action()
    }
}

extension View {
    /// The project's row interaction: a tap opens the row, a hold starts a
    /// multi-select with that row already picked.
    ///
    /// Selection mode used to be reachable only through the `⋯` menu, which meant
    /// the fastest path to "delete these three" was menu → Select → three taps,
    /// and nothing on any screen hinted the mode existed. A hold is what every
    /// iOS list with a selection mode uses, and it lands you in it already
    /// holding the row you were pointing at — which is almost always one of the
    /// ones you wanted.
    ///
    /// The row is a `Button` while it isn't selecting, so it keeps the card press
    /// treatment and its button semantics; in selection mode the `List` owns the
    /// row and a tap must tick it rather than navigate away from the selection
    /// being built.
    func selectableRow(isSelecting: Bool,
                       onHold: @escaping () -> Void,
                       onTap: @escaping () -> Void) -> some View {
        modifier(SelectableRow(isSelecting: isSelecting, onHold: onHold, onTap: onTap))
    }

    /// The hold half on its own, for a row that can't be wrapped in a `Button` —
    /// a contact row carries its own send button, and a button nested inside a
    /// button stops receiving taps.
    ///
    /// Composed with the row's existing `onTapGesture`, which SwiftUI resolves
    /// exclusively: a quick tap opens, a hold selects, never both.
    func holdToSelect(isSelecting: Bool, onHold: @escaping () -> Void) -> some View {
        onLongPressGesture(minimumDuration: SelectionHold.duration) {
            guard !isSelecting else { return }
            SelectionHold.begin(onHold)
        }
        // A hold is invisible to VoiceOver, so the same act is offered by name.
        .accessibilityAction(named: "Select") {
            guard !isSelecting else { return }
            SelectionHold.begin(onHold)
        }
    }
}

private struct SelectableRow: ViewModifier {
    let isSelecting: Bool
    let onHold: () -> Void
    let onTap: () -> Void

    /// Set the instant a hold fires, so the touch-up that ends the hold can't
    /// also open the row.
    ///
    /// Entering selection mode swaps this row for its selection-mode twin, which
    /// normally tears the button's own gesture down before it can fire — but
    /// "normally" isn't a guarantee, and pushing a company's detail screen on top
    /// of the selection the user just started is a bad enough outcome to spend a
    /// `Bool` on.
    @State private var held = false

    func body(content: Content) -> some View {
        if isSelecting {
            content
        } else {
            Button {
                guard !held else { held = false; return }
                onTap()
            } label: {
                content
            }
            .cardButtonStyle()
            // Simultaneous rather than exclusive: the button owns the tap, and
            // this only has to recognise alongside it.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: SelectionHold.duration)
                    .onEnded { _ in
                        held = true
                        SelectionHold.begin(onHold)
                    }
            )
            .accessibilityAction(named: "Select") { SelectionHold.begin(onHold) }
        }
    }
}
