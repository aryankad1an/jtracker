import SwiftUI

/// The app's root: a bottom tab bar (Home, Companies, Activity, Templates,
/// Profile). Owns the shared stores and injects them into the environment.
struct RootView: View {
    @State private var jobStore = JobStore()
    @State private var profileStore = ProfileStore()
    @State private var templateStore = TemplateStore()
    @State private var gmailAuth = GmailAuthStore()
    @State private var mailQueue = MailQueue()
    @State private var selectedTab: Tab = .home

    private enum Tab: Hashable { case home, companies, activity, templates, profile }

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
        .environment(mailQueue)
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
        // Surface any write/load failure from any tab. All three stores report
        // here: template and profile failures used to set an `errorMessage` that
        // no view was bound to, so a save that never reached the database looked
        // exactly like one that did.
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { activeError != nil }, set: { if !$0 { clearErrors() } })
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(activeError ?? "")
        }
    }

    private var activeError: String? {
        jobStore.errorMessage ?? templateStore.errorMessage ?? profileStore.errorMessage
    }

    private func clearErrors() {
        jobStore.clearError()
        templateStore.clearError()
        profileStore.clearError()
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
            tabs.task {
                connectMailQueue()
                await jobStore.load()
            }
        }
    }

    /// Hand the queue the two things it deliberately doesn't own: how to deliver a
    /// mail, and what to do with the sends once a run finishes.
    private func connectMailQueue() {
        mailQueue.sender = { mail, fromName in
            try await gmailAuth.send(to: mail.recipient, subject: mail.subject,
                                     body: mail.body, fromName: fromName)
        }
        mailQueue.onCompletion = { records in
            await jobStore.markContactsSent(records)
        }
    }

    private func loadingSplash(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The accessory shelf is applied only while the queue has something to say.
    /// An `if` *inside* `tabViewBottomAccessory` doesn't work: the modifier still
    /// reserves the shelf and draws an empty capsule above the tab bar. Applying
    /// the modifier conditionally restructures the TabView, which is why the
    /// selection is bound — without it, a send starting would knock the user back
    /// to the first tab.
    @ViewBuilder
    private var tabs: some View {
        if mailQueue.isActive {
            tabStack.tabViewBottomAccessory { SendQueueBar() }
        } else {
            tabStack
        }
    }

    private var tabStack: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            CompaniesView()
                .tabItem { Label("Companies", systemImage: "building.2") }
                .tag(Tab.companies)

            ActivityView()
                .tabItem { Label("Activity", systemImage: "tray.full") }
                .tag(Tab.activity)

            TemplatesView()
                .tabItem { Label("Templates", systemImage: "doc.plaintext") }
                .tag(Tab.templates)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
                .tag(Tab.profile)
        }
    }
}

#Preview {
    RootView()
}
