import SwiftUI

/// A pill-shaped Liquid Glass "Done" button for leaving a multi-select mode,
/// matching the glass icon buttons used elsewhere in the toolbars.
struct GlassDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        // Glass already reacts to a touch; the dip and the knock are what say the
        // tap registered rather than merely landed.
        .buttonStyle(BouncyPress(scale: 0.92))
    }
}
