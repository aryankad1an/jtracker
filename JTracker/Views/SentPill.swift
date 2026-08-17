import SwiftUI

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
            chip("Sent \(sentAt.activityLabel)",
                 systemImage: "clock.arrow.circlepath",
                 color: .statusDone)
        } else if let unsentLabel {
            chip(unsentLabel, systemImage: "sparkle", color: .accentColor)
        }
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
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
