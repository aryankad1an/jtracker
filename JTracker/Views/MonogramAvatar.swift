import SwiftUI

/// A circular avatar whose color is derived deterministically from `text`, so
/// the same name always gets the same color across launches. Shows the first
/// letter by default, or an SF Symbol when `systemImage` is provided (e.g. a
/// building glyph for companies).
struct MonogramAvatar: View {
    let text: String
    var size: CGFloat = Theme.Avatar.medium
    var systemImage: String? = nil

    private var monogram: String {
        String(text.first ?? "?").uppercased()
    }

    private var accent: Color { .monogram(for: text) }

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.4, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(accent.gradient, in: Circle())
    }
}
