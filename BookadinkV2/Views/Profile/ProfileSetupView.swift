import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject private var appState: AppState

    @State private var firstName = ""
    @State private var lastName = ""
    /// Phase 2A.4: Home Club and Skill Level were removed from onboarding.
    /// `EditProfileSheet` still exposes both for post-onboarding edits. New
    /// rows default to `skillLevel = .beginner` (existing server fallback at
    /// `SupabaseService.swift:1544` and `AppState.swift:4233`) and a nil home
    /// club, matching the pre-2A.4 server behaviour for empty inputs.
    /// Escape hatch — without this, a user who signed up with the wrong email
    /// (or wanted to log into an existing account instead) is trapped on this
    /// screen with no way back to AuthWelcomeView. Confirmation prevents an
    /// accidental tap from discarding typed form values.
    @State private var showSignOutConfirm = false

    private var canSubmit: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Set up your profile")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.primaryText)

                Text("This will be your first step before joining clubs and booking courts.")
                    .foregroundStyle(Brand.secondaryText)

                VStack(spacing: 14) {
                    inputField("First name", text: $firstName, icon: "person.fill")
                    inputField("Last name", text: $lastName, icon: "person.fill")

                    Button {
                        guard canSubmit else { return }
                        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Phase 2A.4: server defaults for Home Club + Skill Level.
                        // Both remain editable in EditProfileSheet post-onboarding.
                        Task {
                            await appState.completeProfile(
                                firstName: first,
                                lastName: last,
                                homeClub: nil,
                                skillLevel: .beginner
                            )
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if appState.isSavingProfile {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(appState.isSavingProfile ? "Saving..." : "Continue to Clubs")
                                .font(.headline)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Brand.emeraldAction, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(!canSubmit || appState.isSavingProfile)
                    .opacity((!canSubmit || appState.isSavingProfile) ? 0.55 : 1)
                    .buttonStyle(.plain)
                    .actionBorder(cornerRadius: 16, color: Brand.softOutline)

                    if let error = appState.profileSaveErrorMessage, !error.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                            Text(AppCopy.friendlyError(error))
                        }
                        .font(.footnote)
                        .foregroundStyle(Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appErrorCardStyle(cornerRadius: 12)
                    }
                }
                .padding(18)
                .glassCard(cornerRadius: 24, tint: Brand.rosyTaupe.opacity(0.18))

                Button {
                    showSignOutConfirm = true
                } label: {
                    Text("Use a different account")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(appState.isSavingProfile)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 20)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .clipped()
        .confirmationDialog(
            "Use a different account?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                appState.signOut()
            }
            Button("Keep setting up", role: .cancel) {}
        } message: {
            Text("You'll return to the sign-in screen. Anything you've typed here won't be saved.")
        }
    }

    private func inputField(_ title: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Brand.pineTeal)
            TextField(title, text: text)
        }
        .padding()
        .glassCard(cornerRadius: 18, tint: Brand.cardBackground)
    }
}

#Preview {
    ProfileSetupView()
        .environmentObject(AppState())
        .background(Brand.pageGradient)
}
