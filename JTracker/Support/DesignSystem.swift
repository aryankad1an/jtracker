import SwiftUI

/// The app's visual vocabulary: surfaces, numbers, headers, chips and the motion
/// that ties them together. Colours and type live in `Palette.swift`.
///
/// The rules these pieces encode:
///
/// - **One surface.** Everything raised is the same paper at the same radius with
///   the same hairline. Depth comes from the rule, not from a shadow or a wash.
/// - **Colour is information.** A card is only coloured when its colour means
///   something — a reply, a warning, how long a silence has run — and then only
///   as a rule down its leading edge. Decorative tint was removed: when every
///   card was tinted, the tint that mattered was invisible.
/// - **Serif for figures and titles.** A serif numeral among sans labels reads as
///   a headline without having to be large.

extension Theme {
    /// Corner radii, largest to smallest. Deliberately shallow — a nearly-square
    /// corner reads as a document, a pill reads as a control.
    enum Radius {
        static let hero: CGFloat = 18
        static let card: CGFloat = 14
        static let inner: CGFloat = 10
        static let chip: CGFloat = 6
    }

    enum Space {
        /// The margin every screen's content sits inside.
        static let gutter: CGFloat = 18
    }

    /// The app's springs, so everything that moves shares one tempo.
    ///
    /// The two originals — `snappy` for things that travel, `quick` for things
    /// that only respond — are joined by three that overshoot. Bounce is used the
    /// same way colour is: it means "this thing is a physical object you just
    /// acted on". A card that dips and springs back is a card you pressed; a
    /// count that settles past its target and returns is a count that *changed*
    /// rather than one that was always that number.
    ///
    /// Nothing here bounces for longer than it takes to read the thing that
    /// bounced. `extraBounce` above ~0.3 starts to read as a wobble the user has
    /// to wait out, which is the difference between lively and slow.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.26, extraBounce: 0.01)
        static let quick = Animation.snappy(duration: 0.16)

        /// Things that arrive or leave: a bar sliding up, a card popping into a
        /// list, a lane swapping. Big enough travel to earn a real overshoot.
        static let bouncy = Animation.snappy(duration: 0.4, extraBounce: 0.24)

        /// Small things that react: a chip, a badge, a checkmark, a pressed card.
        /// Fast, with the springiest return in the app — it's over before it can
        /// get in the way.
        static let pop = Animation.spring(response: 0.3, dampingFraction: 0.56)

        /// Figures and meters settling into place — a ring drawing itself, a
        /// number counting up. Slow enough to watch, and it lands twice.
        static let settle = Animation.snappy(duration: 0.62, extraBounce: 0.3)
    }
}

// MARK: - Surfaces

/// A raised surface: paper, a hairline, and — when the card's state is worth
/// saying in colour — a rule down its leading edge.
struct Panel: ViewModifier {
    var accent: Color?
    var radius: CGFloat = Theme.Radius.card

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color.paperRaised)
            }
            .overlay(alignment: .leading) {
                if let accent {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3)
                }
            }
            // Clipped before the border is drawn, so the rule is cut by the
            // card's curve and the stroke stays a clean unbroken outline on top.
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.hairline, lineWidth: 1)
            }
    }
}

extension View {
    /// A plain raised surface.
    func panel(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(Panel(accent: nil, radius: radius))
    }

    /// A raised surface whose leading rule states the row's condition.
    func panel(accent: Color, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(Panel(accent: accent, radius: radius))
    }

    /// A surface whose rule is conditional — nil means an unmarked card.
    @ViewBuilder
    func panelAccented(_ accent: Color?, radius: CGFloat = Theme.Radius.card) -> some View {
        if let accent {
            modifier(Panel(accent: accent, radius: radius))
        } else {
            modifier(Panel(accent: nil, radius: radius))
        }
    }

    /// Press feedback for anything card-shaped, applied through a button style so
    /// the whole card dips as one object.
    func cardButtonStyle() -> some View {
        buttonStyle(CardPress())
    }

    /// Press feedback for a small control — an icon button, a pill, a glass
    /// capsule. Dips further than a card because there's less of it to see move.
    func bouncyButtonStyle() -> some View {
        buttonStyle(BouncyPress())
    }

    /// The app's standard arrival: scale up from slightly small while fading in.
    /// Paired with `Theme.Motion.bouncy` it reads as the view springing into the
    /// space rather than being cross-faded into it.
    func popIn(anchor: UnitPoint = .center) -> some View {
        transition(.scale(scale: 0.86, anchor: anchor).combined(with: .opacity))
    }
}

/// A card dips, springs back, and knocks once on the way down.
///
/// The knock is on press rather than on release deliberately: it confirms the
/// finger landed on the card, which is the moment the user is still deciding
/// whether they hit the right row. Feedback on release would arrive after the
/// screen had already started changing, where it says nothing new.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(isPressed: configuration.isPressed,
                  scale: 0.972, dim: 0.82, intensity: 0.55) {
            configuration.label
        }
    }
}

/// The same idea at small-control scale: a deeper dip, a lighter knock.
struct BouncyPress: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        PressBody(isPressed: configuration.isPressed,
                  scale: scale, dim: 1, intensity: 0.45) {
            configuration.label
        }
    }
}

/// The shared body behind both press styles.
///
/// It exists as a `View` rather than living in `makeBody` because a `ButtonStyle`
/// can't read the environment directly, and Reduce Motion has to be honoured here
/// above anywhere else in the app: this is the one treatment that fires on
/// essentially every tap. With it on, the dip is dropped and the button reports
/// itself through opacity and the haptic alone — the *feedback* is kept, only the
/// movement is spent. Turning the haptic off too would leave the setting removing
/// confirmation rather than removing motion.
private struct PressBody<Label: View>: View {
    let isPressed: Bool
    let scale: CGFloat
    let dim: Double
    let intensity: Double
    @ViewBuilder var label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .scaleEffect(isPressed && !reduceMotion ? scale : 1)
            .opacity(isPressed ? dim : 1)
            .animation(reduceMotion ? Theme.Motion.quick : Theme.Motion.pop, value: isPressed)
            .sensoryFeedback(trigger: isPressed) { _, pressed in
                pressed ? .impact(weight: .light, intensity: intensity) : nil
            }
    }
}

// MARK: - Numbers

/// A metric set the way every metric in the app is set: serif figures over a
/// sans caption, monospaced so digits don't jitter when they change.
struct Metric: View {
    let value: Int
    var caption: String
    var tint: Color = .ink
    var size: CGFloat = 26
    var alignment: HorizontalAlignment = .center

    /// Drives the kick. Held for a beat and released, so the figure overshoots
    /// on the way out and springs back rather than easing to a new size.
    @State private var kicked = false
    /// Whether this metric has already rendered once. `task(id:)` fires on first
    /// appearance as well as on every change, and a screen where every figure
    /// kicks as it loads reads as a glitch rather than as an update.
    @State private var settled = false

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text("\(value)")
                .font(.display(size))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint)
                // Only the figure kicks, not the caption — scaling the pair would
                // move the baseline of every metric in a row of them.
                .scaleEffect(kicked ? 1.16 : 1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: alignment == .center ? .center : .leading)
        .animation(Theme.Motion.settle, value: value)
        .task(id: value) {
            guard settled else { settled = true; return }
            withAnimation(Theme.Motion.pop) { kicked = true }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(Theme.Motion.pop) { kicked = false }
        }
    }
}

/// A thin vertical rule between metrics.
struct MetricDivider: View {
    var height: CGFloat = 28

    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: 1, height: height)
    }
}

// MARK: - Headers

/// A section header with an optional count. Uppercase and tracked, so it reads
/// as a label rather than as content.
struct SectionLabel: View {
    let title: String
    var systemImage: String?
    var count: Int?
    var tint: Color = .inkMuted

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.9)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Selector

/// A sliding segmented control, in Liquid Glass.
///
/// The selected segment is one glass capsule that travels rather than a
/// per-segment highlight, so switching reads as movement. Glass is the right
/// material here specifically *because* it's a floating control over content:
/// it picks up the paper beneath it and the specular edge marks it as the thing
/// that moves, which a flat fill can't do.
///
/// Tinted with clay rather than filled with it — a solid accent capsule would
/// put the loudest colour on screen on a control rather than on what the control
/// found.
struct SegmentedSelector<Value: Hashable>: View {
    let segments: [(value: Value, title: String, systemImage: String)]
    @Binding var selection: Value

    @Namespace private var pill

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(segments, id: \.value) { segment in
                    segmentButton(segment)
                }
            }
            .padding(3)
        }
        .background(Color.paperSunken, in: .capsule)
        // On the value rather than in the button action, so a segment changed
        // programmatically (a lane pruned, a mode restored) clicks too.
        .sensoryFeedback(.selection, trigger: selection)
    }

    /// Glass wraps the selected segment itself, not a layer behind it. Applied as
    /// a background, the material composited *over* the label and greyed out the
    /// very word it was meant to pick out.
    @ViewBuilder
    private func segmentButton(_ segment: (value: Value, title: String, systemImage: String)) -> some View {
        let isOn = segment.value == selection
        let button = Button {
            withAnimation(Theme.Motion.bouncy) { selection = segment.value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: segment.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isOn ? Color.clay : Color.inkFaint)
                    // The glyph bounces as its segment takes the pill, so the
                    // travelling capsule lands on something that reacts to it.
                    .symbolEffect(.bounce, value: isOn)
                Text(segment.title)
                    .font(.subheadline.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Color.ink : Color.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])

        if isOn {
            button
                .glassEffect(.regular.tint(Color.clay.opacity(0.16)).interactive(), in: .capsule)
                // A single id for whichever segment is selected, so the container
                // morphs one pane across rather than cross-fading two.
                .glassEffectID("selected", in: pill)
        } else {
            button
        }
    }
}

// MARK: - Forms

/// The app's form chrome, in one place: paper ground, paper rows.
///
/// Every editor in the app is a `Form` — the system's row layout, keyboard
/// handling and field semantics are worth keeping — but the default grouped
/// background is the neutral grey the rest of the app was moved off. Wrapping
/// rather than modifying is what makes the row colour reachable: `listRowBackground`
/// has to be applied to the rows, so the content is the thing that carries it.
///
/// Use this in place of `Form` everywhere, so a new editor can't quietly ship in
/// the system palette.
struct PaperForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
                .listRowBackground(Color.paperRaised)
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }
}

/// The same treatment for the read-only `List`s (a sent mail, a send history).
struct PaperList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowBackground(Color.paperRaised)
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }
}

// MARK: - Empty state

/// A compact empty state for use *inside* a scroll view, where
/// `ContentUnavailableView` would demand the whole screen.
struct InlineEmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
    var tint: Color = .inkFaint

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title)
                .font(.display(17))
                .foregroundStyle(.ink)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .panel()
        .popIn()
    }
}
