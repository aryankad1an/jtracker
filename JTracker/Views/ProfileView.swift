import SwiftUI

/// The Profile tab: personal details (read-only until you tap the pencil),
/// plus the Gmail connection.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(JobStore.self) private var jobStore
    @Environment(GmailAuthStore.self) private var gmail

    @State private var isEditing = false
    @State private var draft = Profile()

    var body: some View {
        NavigationStack {
            Form {
                // Editable only in edit mode; otherwise a read-only snapshot.
                ProfileFields(profile: isEditing ? $draft : .constant(store.profile),
                              isEditing: isEditing)

                if gmail.isConnected {
                    Section {
                        Button("Sign Out", role: .destructive) { signOut() }
                    } footer: {
                        Text("Signed in as \(gmail.connectedEmail ?? "").")
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if isEditing {
                            isEditing = false            // cancel, discard the draft
                        } else {
                            draft = store.profile         // start from the current profile
                            isEditing = true
                        }
                    } label: {
                        Image(systemName: isEditing ? "xmark" : "pencil")
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

    /// Only leave edit mode once the write actually lands. A failed save used to
    /// exit anyway, leaving the screen showing the edited values it had already
    /// written locally — so a lost edit looked identical to a saved one until the
    /// next load quietly restored the old profile.
    private func save() {
        Task {
            let previous = store.profile
            store.profile = draft
            if await store.save() {
                isEditing = false
            } else {
                store.profile = previous
            }
        }
    }

    private func signOut() {
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
}
