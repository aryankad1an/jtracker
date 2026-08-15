import SwiftUI

/// Shown after the first Gmail sign-in: collect the profile details used to fill
/// cold-mail templates, then save them to the database before entering the app.
struct OnboardingView: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section {
                    Text("Tell us about yourself. This fills in your cold-mail templates and is saved to your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ProfileFields(profile: $store.profile)

                Section {
                    Button {
                        Task { await store.save() }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Continue").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(store.profile.name.trimmingCharacters(in: .whitespaces).isEmpty || store.isSaving)
                }
            }
            .navigationTitle("Set Up Profile")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .alert(
                "Couldn't save profile",
                isPresented: Binding(get: { store.errorMessage != nil },
                                     set: { if !$0 { store.clearError() } })
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }
}

/// The shared profile fields, reused by onboarding and the Profile tab.
struct ProfileFields: View {
    @Binding var profile: Profile

    var body: some View {
        Section("About") {
            TextField("Name", text: $profile.name)
        }

        Section("Education") {
            Toggle("Currently studying?", isOn: $profile.isStudying)
            if profile.isStudying {
                TextField("College", text: $profile.college)
            }
        }

        Section("Work") {
            Toggle("Currently working?", isOn: $profile.isWorking)
            if profile.isWorking {
                TextField("Company", text: $profile.company)
                TextField("Position", text: $profile.position)
            }
        }

        Section("Resume") {
            TextField("Google Drive Link", text: $profile.resumeLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
    }
}
