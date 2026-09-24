import SwiftUI

// MARK: - Liquid transitions
//
// Surfaces don't slide or pop into place; they condense as they grow and
// dissolve as they leave — the way a droplet forms, rather than the way a card
// is dealt. These are the shared shapes of that motion.
//
// One rule: never blur glass. Glass already samples and blurs what's behind it,
// and animating a blur over it forces an offscreen render of the whole surface
// every frame — that was the lag when a selection bar arrived. Glass surfaces
// use `glassRise`/`glassPop`, which only scale, move and fade.

/// Condenses in from a soft, slightly smaller blur; evaporates the same way.
struct LiquidMaterialize: Transition {
    var scale: CGFloat = 0.88
    var blur: CGFloat = 10
    var anchor: UnitPoint = .center
    /// Optional drift, for things that rise into place from an edge.
    var offset: CGSize = .zero

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : scale, anchor: anchor)
            .blur(radius: phase.isIdentity ? 0 : blur)
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(phase.isIdentity ? .zero : offset)
    }
}

extension Transition where Self == LiquidMaterialize {
    /// The default liquid arrival for a non-glass surface: condenses from a blur.
    static var liquid: LiquidMaterialize { LiquidMaterialize() }

    /// A glass bar rising from the bottom edge. No blur (see above).
    static var glassRise: LiquidMaterialize {
        LiquidMaterialize(scale: 0.94, blur: 0, anchor: .bottom, offset: CGSize(width: 0, height: 20))
    }

    /// A glass capsule appearing in place. No blur (see above).
    static var glassPop: LiquidMaterialize {
        LiquidMaterialize(scale: 0.88, blur: 0)
    }
}

/// The splash leaving: it swells, softens and dissolves, so the app surfaces
/// through it rather than having it wiped off.
struct LiquidDissolve: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 1.14)
            .blur(radius: phase.isIdentity ? 0 : 24)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}
