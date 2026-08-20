import SwiftUI

/// The small status capsule contacts wear in lists — "Sent 3 days ago",
/// "Invalid", "New". One shape, one type size, one padding, so a row that shows
/// two of them side by side still reads as one row rather than two competing
/// badges.
struct StatusChip: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        // Intrinsic width so the chip can never be squeezed — the name beside it
        // truncates instead.
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The "already mailed" chip, shared by every list that shows contacts.
///
/// Three screens had grown their own copy of this — the company detail list, the
/// Suggested drawer, and (missing entirely) the compose recipient list — which is
/// why the same fact rendered three different ways, or not at all. One component
/// keeps the wording, colour and shape identical wherever a contact appears.
struct SentPill: View {
    let sentAt: Date?
    /// What to show for a contact that has never been mailed. Leave nil to render
    /// nothing at all, which is what a list of *pending* contacts wants.
    var unsentLabel: String? = nil

    var body: some View {
        if let sentAt {
            StatusChip(text: "Sent \(sentAt.activityLabel)",
                       systemImage: "clock.arrow.circlepath", color: .statusDone)
        } else if let unsentLabel {
            StatusChip(text: unsentLabel, systemImage: "sparkle", color: .accentColor)
        }
    }
}

/// The "ruled out" chip: this address bounces, or the person has left. Orange
/// rather than red — the contact isn't gone or broken, it's just been set aside,
/// and it can be put back with one swipe.
struct InvalidPill: View {
    var body: some View {
        StatusChip(text: "Invalid", systemImage: "exclamationmark.triangle.fill",
                   color: .statusInvalid)
    }
}
