import SwiftUI

/// The screen the app opens on while it loads.
///
/// It replaces a spinner over the words "Loading your profile…". That spinner was
/// honest but wrong twice over: it named one of the four things being fetched, and
/// an indeterminate ring says only "still going", which is the one thing a launch
/// screen shouldn't dwell on. This says the same thing in the app's own terms —
/// paper, clay, the serif wordmark — and reports real progress on a rule that
/// fills, so the wait has a visible end.
///
/// The mark is the paperplane the empty states already use, so the first thing
/// drawn at launch is something the rest of the app repeats rather than a logo
/// that appears once and never again.
///
/// Motion runs on a phase enum rather than on a pile of booleans: each phase is a
/// moment (`landing` → `settled` → `leaving`), and every animated property reads
/// its value from the current one. Adding a beat means adding a case, not another
/// `@State` to keep in step with the others.
struct SplashView: View {

    /// How much of the launch work is done, 0…1. Drives the rule under the
    /// wordmark; it is a real fraction of the loads that have finished, not a
    /// timer pretending to be one.
    let progress: Double

    private enum Phase { case waiting, landing, settled }
    @State private var phase: Phase = .waiting

    /// Long enough for the mark to land before the wordmark follows it, short
    /// enough that a warm launch isn't held up waiting for choreography.
    private static let wordmarkDelay: Duration = .milliseconds(260)

    private var markScale: CGFloat {
        switch phase {
        case .waiting: 0.72
        case .landing, .settled: 1
        }
    }

    private var haloScale: CGFloat {
        // The halo keeps expanding after the mark has landed, so the composition
        // is still breathing while the data is still arriving.
        switch phase {
        case .waiting: 0.5
        case .landing: 1
        case .settled: 1.12
        }
    }

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()

            VStack(spacing: 22) {
                mark
                wordmark
                rule
            }
            // Nudged above centre: optically centred text sits a little high, and
            // the rule below the wordmark adds weight to the bottom of the group.
            .offset(y: -24)
        }
        .task {
            // The engine is primed in `RootView.init`, so this first knock lands
            // on time rather than tens of milliseconds late.
            withAnimation(Theme.Motion.settle) { phase = .landing }
            Haptics.lift(0.75)

            try? await Task.sleep(for: Self.wordmarkDelay)
            withAnimation(Theme.Motion.settle) { phase = .settled }
        }
    }

    // MARK: - Pieces

    private var mark: some View {
        ZStack {
            // A gradient, not a flat fill: a disc of solid 10% clay has a hard
            // edge, which on the dark paper reads as a grey plate behind the mark
            // rather than as light coming off it.
            Circle()
                .fill(
                    RadialGradient(colors: [Color.clay.opacity(0.20), Color.clay.opacity(0)],
                                   center: .center, startRadius: 30, endRadius: 84)
                )
                .frame(width: 168, height: 168)
                .scaleEffect(haloScale)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color.clay, Color.clay.opacity(0.82)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 86, height: 86)
                .overlay {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        // The same tilt the empty states give it, so the glyph is
                        // recognisably the one thing this app is about.
                        .rotationEffect(.degrees(-14))
                }
                .scaleEffect(markScale)
        }
        .opacity(phase == .waiting ? 0 : 1)
    }

    private var wordmark: some View {
        Text("JTracker")
            .font(.display(34))
            .foregroundStyle(.ink)
            .opacity(phase == .settled ? 1 : 0)
            // Rises into place rather than fading on the spot, so it reads as
            // arriving after the mark instead of being revealed beside it.
            .offset(y: phase == .settled ? 0 : 10)
    }

    /// The progress rule: a hairline track with a clay fill, sized by `progress`.
    ///
    /// Deliberately not a `ProgressView`. The system bar is the same grey
    /// everywhere in iOS, and the whole point of the screen is that the first
    /// thing the app shows is in its own palette.
    private var rule: some View {
        Capsule()
            .fill(Color.hairline)
            .frame(width: 128, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.clay)
                    .frame(width: 128 * min(max(progress, 0.06), 1), height: 3)
            }
            .opacity(phase == .settled ? 1 : 0)
            .animation(Theme.Motion.snappy, value: progress)
            .accessibilityElement()
            .accessibilityLabel("Loading")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

#Preview {
    SplashView(progress: 0.45)
}
