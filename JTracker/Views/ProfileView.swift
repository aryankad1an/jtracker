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
            // The pencil is the bar's verb, and in edit mode the same slot is
            // Save — the ✎ morphs into the ✓ where the thumb already is, and a ✕
            // arrives on the leading edge to back out.
            .topBarActions(
                isEditing
                    ? TopBarPrimary(title: "Save", systemImage: "checkmark",
                                    isProminent: true, isBusy: store.isSaving) { save() }
                    : TopBarPrimary(title: "Edit Profile", systemImage: "pencil") {
                        withAnimation(Theme.Motion.liquid) {
                            draft = store.profile         // start from the current profile
                            isEditing = true
                        }
                    },
                // Cancel discards the draft — but not one already being written.
                onCancel: isEditing ? { if !store.isSaving { isEditing = false } } : nil
            ) {
                if replySync.needsReconnect {
                    Button { reconnect() } label: {
                        Label("Reconnect Gmail", systemImage: "arrow.trianglehead.clockwise")
                    }
                    .disabled(isReconnecting)
                    Divider()
                }
                Button(role: .destructive) { signOut() } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
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

                Button { reconnect() } label: {
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

    private func reconnect() {
        Haptics.press()
        isReconnecting = true
        Task {
            await gmail.connect()
            isReconnecting = false
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
