import SwiftUI

/// A pill-shaped Liquid Glass "Done" button for leaving a multi-select mode,
/// matching the glass icon buttons used elsewhere in the toolbars.
struct GlassDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
