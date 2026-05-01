import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject private var appState: AppState

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var favoriteClub = ""
    @State private var skillLevel: SkillLevel = .beginner

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
                    inputField("Home club (optional)", text: $favoriteClub, icon: "building.2.fill")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Skill level")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.ink)

                        Picker("Skill Level", selection: $skillLevel) {
                            ForEach(SkillLevel.allCases.filter { $0 != .all }) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .glassCard(cornerRadius: 18, tint: Brand.cardBackground)

                    Button {
                        guard canSubmit else { return }
                        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let club = favoriteClub.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await appState.completeProfile(
                                firstName: first,
                                lastName: last,
                                homeClub: club.isEmpty ? nil : club,
                                skillLevel: skillLevel
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 20)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .clipped()
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
