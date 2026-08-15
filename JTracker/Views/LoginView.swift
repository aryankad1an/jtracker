import SwiftUI

/// The splash / sign-in screen. The app is gated behind a Gmail connection —
/// everything (companies, sent state, profile) is keyed to the signed-in address.
struct LoginView: View {
    @Environment(GmailAuthStore.self) private var gmail

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("JTracker")
                    .font(.largeTitle.bold())
                Text("Track and send cold mails from your Gmail.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task { await gmail.connect() }
            } label: {
                HStack(spacing: 8) {
                    if gmail.isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "envelope.badge")
                    }
                    Text(gmail.isConnecting ? "Connecting…" : "Sign in with Gmail")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(gmail.isConnecting)

            Text("You need to sign in to continue.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .alert(
            "Couldn't connect Gmail",
            isPresented: Binding(get: { gmail.errorMessage != nil },
                                 set: { if !$0 { gmail.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(gmail.errorMessage ?? "")
        }
    }
}
