import SwiftUI
import UIKit

/// The app's colours, in one place.
///
/// The palette is warm and paper-like rather than the iOS default of neutral
/// greys on white: an ivory ground, near-black warm ink, hairline rules in a
/// warm grey, and a single clay accent that carries every action. Colour is
/// scarce on purpose — when almost nothing is coloured, the one thing that is
/// (a reply, a warning, the accent on a button) is read first.
///
/// Dark mode is a warm near-black rather than pure black, so the same ink and
/// clay stay recognisable instead of turning into a different app at night.
enum Palette {

    // MARK: - Ground and surfaces

    /// The page. Everything else sits on this.
    static let paper = dynamic(light: 0xF0EEE6, dark: 0x262624)

    /// A raised surface: cards, panels, rows.
    static let paperRaised = dynamic(light: 0xFAF9F5, dark: 0x30302E)

    /// A recessed surface: the trough of a control, a segmented track.
    static let paperSunken = dynamic(light: 0xE7E4DA, dark: 0x1F1E1D)

    // MARK: - Ink

    /// Primary text. Warm near-black, never pure #000.
    static let ink = dynamic(light: 0x1A1A17, dark: 0xF5F4EE)
    /// Secondary text: captions, subtitles, the second line of a row.
    static let inkMuted = dynamic(light: 0x6B6A62, dark: 0xA8A69C)
    /// Tertiary text: chevrons, timestamps, anything you should be able to ignore.
    static let inkFaint = dynamic(light: 0x9C9A8E, dark: 0x7C7A72)

    /// Hairline rules and card borders. Carries structure so shadows don't have to.
    static let hairline = dynamic(light: 0xE0DCD1, dark: 0x413F3B)

    // MARK: - Accent and status

    /// The one accent: Claude's clay. Buttons, selection, the active state.
    static let clay = dynamic(light: 0xC15F3C, dark: 0xD97757)
    /// A reply landed. A muted olive — legible against clay without competing.
    static let olive = dynamic(light: 0x5A7A55, dark: 0x93B189)
    /// Sent, waiting, in progress. Cool enough to read as neutral beside clay.
    static let slate = dynamic(light: 0x5D7086, dark: 0x9BAEC6)
    /// Set aside or needs attention: bounced, invalid, unmigrated.
    static let kraft = dynamic(light: 0xA1743C, dark: 0xD4A27F)
    /// Destructive and broken: delete, a template that won't render, a silence
    /// long past the point of following up. A warm red, so it belongs to the
    /// palette rather than arriving from the system.
    static let danger = dynamic(light: 0xB0453A, dark: 0xE08472)

    /// Build a colour that resolves per appearance. Hex is spelled out rather
    /// than named so the palette can be diffed against the brand values directly.
    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

/// The palette as `Color` members, so `Color.clay` reads naturally in a fill.
extension Color {
    static var paper: Color { Palette.paper }
    static var paperRaised: Color { Palette.paperRaised }
    static var paperSunken: Color { Palette.paperSunken }
    static var ink: Color { Palette.ink }
    static var inkMuted: Color { Palette.inkMuted }
    static var inkFaint: Color { Palette.inkFaint }
    static var hairline: Color { Palette.hairline }
    static var clay: Color { Palette.clay }
    static var olive: Color { Palette.olive }
    static var slate: Color { Palette.slate }
    static var kraft: Color { Palette.kraft }
    static var danger: Color { Palette.danger }
}

/// And in `ShapeStyle` position, so `.foregroundStyle(.inkMuted)` reads as
/// naturally as the system's `.secondary` it replaces. Both forward to
/// ``Palette`` by name rather than to each other — when these were mutually
/// referential, only Swift's preference for concrete members over protocol
/// extensions kept it from recursing forever.
extension ShapeStyle where Self == Color {
    static var paper: Color { Palette.paper }
    static var paperRaised: Color { Palette.paperRaised }
    static var paperSunken: Color { Palette.paperSunken }
    static var ink: Color { Palette.ink }
    static var inkMuted: Color { Palette.inkMuted }
    static var inkFaint: Color { Palette.inkFaint }
    static var hairline: Color { Palette.hairline }
    static var clay: Color { Palette.clay }
    static var olive: Color { Palette.olive }
    static var slate: Color { Palette.slate }
    static var kraft: Color { Palette.kraft }
    static var danger: Color { Palette.danger }
}

extension UIColor {
    /// A UIColor that resolves per appearance, for the UIKit surfaces SwiftUI
    /// still draws. Kept in step with `Color`'s values by hand — there are only
    /// two, and both are named at the one call site.
    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Type

extension Font {
    /// Editorial headings and figures, set in the system serif. Reserved for
    /// titles and for numbers that are the point of the screen — a serif numeral
    /// among sans labels reads as a headline without needing to be large.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - App-wide chrome

enum AppAppearance {
    /// Set navigation titles in the serif, so a screen's title matches the
    /// headings and figures on the screen below it.
    ///
    /// Called once at launch. Doing it through the appearance proxy rather than
    /// per-screen modifiers keeps every bar in the app in step, including the ones
    /// pushed inside sheets.
    static func apply() {
        // Only the type is overridden, through the bar's own properties. Handing
        // iOS 26 a fully configured `UINavigationBarAppearance` here made the
        // large title stop drawing altogether — the space was reserved and left
        // empty — so the background and materials are left to the system, which
        // already paints them to match the page.
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: serif(size: 34, weight: .bold)
        ]
        UINavigationBar.appearance().titleTextAttributes = [
            .font: serif(size: 17, weight: .semibold)
        ]
    }

    /// The system serif at a given size, falling back to the default face if the
    /// serif descriptor isn't available.
    private static func serif(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
