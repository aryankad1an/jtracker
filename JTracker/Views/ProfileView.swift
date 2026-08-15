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
                ProfileFields(profile: isEditing ? $draft : .constant(store.profile))
                    .disabled(!isEditing)

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
                    .disabled(store.isSaving)
                }
                if isEditing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { save() } label: {
                            if store.isSaving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                        }
                        .disabled(store.isSaving)
                    }
                }
            }
        }
    }

    private func save() {
        store.profile = draft
        Task {
            await store.save()
            isEditing = false
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
