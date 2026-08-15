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
