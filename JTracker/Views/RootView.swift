import SwiftUI

/// The app's root: a bottom tab bar (Home, Companies, Activity, Templates,
/// Profile). Owns the shared stores and injects them into the environment.
struct RootView: View {
    @State private var jobStore = JobStore()
    @State private var profileStore = ProfileStore()
    @State private var templateStore = TemplateStore()
    @State private var gmailAuth = GmailAuthStore()

    var body: some View {
        Group {
            if let email = gmailAuth.connectedEmail {
                signedInContent
                    // Load this user's profile on sign-in, and reload if the
                    // connected account changes.
                    .task(id: email) {
                        jobStore.userEmail = email
                        await profileStore.load(email: email)
                        await templateStore.load(email: email)
                    }
            } else {
                LoginView()
            }
        }
        .environment(jobStore)
        .environment(profileStore)
        .environment(templateStore)
        .environment(gmailAuth)
        // Block interaction and show a loading state while a change is being
        // written to the database and reloaded, so the two never drift.
        .overlay {
            if jobStore.isSaving || templateStore.isSaving {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView("Saving…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: jobStore.isSaving)
        .animation(.easeInOut(duration: 0.15), value: templateStore.isSaving)
        // Surface any write/load failure from any tab.
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { jobStore.errorMessage != nil },
                                 set: { if !$0 { jobStore.clearError() } })
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(jobStore.errorMessage ?? "")
        }
    }

    /// Signed-in flow: wait for the profile to load, onboard first-time users,
    /// then show the tabs (which load the user's companies).
    @ViewBuilder
    private var signedInContent: some View {
        if !profileStore.loaded {
            loadingSplash("Loading your profile…")
        } else if !profileStore.hasProfile {
            OnboardingView()
        } else {
            tabs.task { await jobStore.load() }
        }
    }

    private func loadingSplash(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabs: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }

            CompaniesView()
                .tabItem { Label("Companies", systemImage: "building.2") }

            ActivityView()
                .tabItem { Label("Activity", systemImage: "tray.full") }

            TemplatesView()
                .tabItem { Label("Templates", systemImage: "doc.plaintext") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
        }
    }
}

#Preview {
    RootView()
}
