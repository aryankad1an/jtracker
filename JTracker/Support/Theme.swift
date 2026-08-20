import SwiftUI

/// Shared design tokens so spacing, sizing, and semantic color usage stay
/// consistent across every screen instead of being re-picked ad hoc per view.
enum Theme {
    /// Avatar diameters. `medium` for primary list rows, `small` for dense or
    /// secondary contexts.
    enum Avatar {
        static let small: CGFloat = 36
        static let medium: CGFloat = 44
    }
}

extension ShapeStyle where Self == Color {
    /// Positive / completed states: sent, applied, Gmail connected.
    static var statusDone: Color { .green }

    /// Set-aside states: a contact marked invalid. Deliberately not red — nothing
    /// has been destroyed, and red is reserved for delete.
    static var statusInvalid: Color { .orange }
}

extension Color {
    /// A stable accent color derived from `text`, so the same name always gets the
    /// same color everywhere it appears — an avatar, a filter chip, the tint of a
    /// timeline card — and those readings agree with each other.
    ///
    /// The bucket comes from a djb2 hash rather than a sum of code points: summing
    /// barely mixes the low bits, so real names (similar lengths, overlapping
    /// letters) collided in visible clumps — a list would show the same color three
    /// rows running. Swift's own `hashValue` isn't an option, since it's seeded per
    /// process and would repaint every avatar on each launch.
    static func monogram(for text: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green,
                                .teal, .indigo, .red, .brown]
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

extension String {
    /// Swap stray Unicode line/paragraph separators (U+2028, U+2029, U+0085) for
    /// a plain space.
    ///
    /// iOS's keyboard (swipe-typing and predictive text in particular) will
    /// occasionally emit one of these instead of an ordinary space when the tap
    /// or swipe lands right on a soft line-wrap boundary in a multi-line text
    /// view. They're invisible in the editor — indistinguishable from a normal
    /// space on screen — but mail is sent as `text/plain`, where every mail
    /// client (Gmail included) honors them as a hard line break, same as a real
    /// "\n". So a paragraph that only ever wrapped on screen can arrive with an
    /// unintended break in it even though the sender never pressed Return.
    /// Actual "\n"/"\n\n" from a real Return keypress are left untouched.
    var sanitizedLineSeparators: String {
        replacingOccurrences(of: "[\u{2028}\u{2029}\u{0085}]", with: " ", options: .regularExpression)
    }
}

extension Date {
    /// A compact, human label for activity timestamps:
    /// "Today", "Yesterday", "Aug 12", or "Aug 12, 2025" outside the current year.
    var activityLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Like `activityLabel`, but appends the time for entries from today
    /// (e.g. "Today, 11:05 AM"). Other days show the date only.
    var activityLabelWithTime: String {
        guard Calendar.current.isDateInToday(self) else { return activityLabel }
        return "Today, " + formatted(date: .omitted, time: .shortened)
    }
}
