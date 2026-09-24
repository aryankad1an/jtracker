import SwiftUI

/// The Profile tab: personal details (read-only until you tap the pencil),
/// plus the Gmail connection.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(JobStore.self) private var jobStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(ReplySync.self) private var replySync

    @State private var isEditing = false
    @State private var draft = Profile()
    @State private var isReconnecting = false

    var body: some View {
        NavigationStack {
            PaperForm {
                // Editable only in edit mode; otherwise a read-only snapshot.
                ProfileFields(profile: isEditing ? $draft : .constant(store.profile),
                              isEditing: isEditing)

                if gmail.isConnected { gmailSection }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.Motion.bouncy) {
                            if isEditing {
                                isEditing = false            // cancel, discard the draft
                            } else {
                                draft = store.profile         // start from the current profile
                                isEditing = true
                            }
                        }
                    } label: {
                        Image(systemName: isEditing ? "xmark" : "pencil")
                            // The pencil and the cross are the same slot, so the
                            // swap between them bounces rather than cross-fading.
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(isEditing ? "Cancel editing" : "Edit profile")
                    .disabled(store.isSaving)
                }
                // Save sits on the trailing edge, matching every other editable
                // screen in the app and the platform convention.
                if isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: {
                            if store.isSaving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                        }
                        .disabled(store.isSaving)
                    }
                }
            }
        }
    }

    /// The connected account, plus the one repair this app can need: a token
    /// minted before reply tracking existed has no permission to read mail, and
    /// only a fresh consent can grant it. Reconnecting keeps the same account and
    /// the same data — it just re-runs the Google sheet.
    @ViewBuilder
    private var gmailSection: some View {
        Section {
            LabeledContent("Account", value: gmail.connectedEmail ?? "")

            if replySync.needsReconnect {
                Label {
                    Text("Reply tracking needs permission to read your mail.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.statusInvalid)
                }

                Button {
                    Haptics.press()
                    isReconnecting = true
                    Task {
                        await gmail.connect()
                        isReconnecting = false
                    }
                } label: {
                    if isReconnecting {
                        ProgressView()
                    } else {
                        Label("Reconnect Gmail", systemImage: "arrow.trianglehead.clockwise")
                    }
                }
                .disabled(isReconnecting)
            }

            Button("Sign Out", role: .destructive) { signOut() }
        } header: {
            Label("Gmail", systemImage: "envelope.fill")
        } footer: {
            Text(replySync.needsReconnect
                 ? "Reconnecting signs in to the same account and grants read access. Nothing is deleted."
                 : "Used to send your mails and to check which ones were answered.")
        }
    }

    /// Only leave edit mode once the write actually lands. A failed save used to
    /// exit anyway, leaving the screen showing the edited values it had already
    /// written locally — so a lost edit looked identical to a saved one until the
    /// next load quietly restored the old profile.
    private func save() {
        Task {
            let previous = store.profile
            store.profile = draft
            if await store.save() {
                Haptics.success()
                withAnimation(Theme.Motion.bouncy) { isEditing = false }
            } else {
                // The alert says what went wrong; the buzz says *that* something
                // did, while the user is still looking at the fields they typed.
                Haptics.failure()
                store.profile = previous
            }
        }
    }

    private func signOut() {
        Haptics.press()
        store.reset()
        jobStore.userEmail = nil
        gmail.disconnect()
    }

}

#Preview {
    ProfileView()
        .environment(ProfileStore())
        .environment(JobStore())
        .environment(GmailAuthStore())
        .environment(ReplySync())
}
