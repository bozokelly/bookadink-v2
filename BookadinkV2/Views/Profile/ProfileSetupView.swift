import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject private var appState: AppState

    @State private var fullName = ""
    @State private var favoriteClub = ""
    @State private var skillLevel: SkillLevel = .beginner
    @State private var avatarPresetID: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Set up your profile")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.primaryText)

                Text("This will be your first step before joining clubs and booking courts.")
                    .foregroundStyle(Brand.secondaryText)

                VStack(spacing: 14) {
                    inputField("Full name", text: $fullName, icon: "person.fill")
                    inputField("Home club (optional)", text: $favoriteClub, icon: "building.2.fill")
                    avatarPickerSection

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Skill level")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.ink)

                        Picker("Skill Level", selection: $skillLevel) {
                            ForEach(SkillLevel.allCases) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .glassCard(cornerRadius: 18, tint: Brand.cardBackground)

                    Button {
                        guard !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        let club = favoriteClub.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await appState.completeProfile(
                                name: fullName,
                                homeClub: club.isEmpty ? nil : club,
                                skillLevel: skillLevel,
                                avatarPresetID: avatarPresetID
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
                    .disabled(fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isSavingProfile)
                    .opacity((fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isSavingProfile) ? 0.55 : 1)
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

    private var avatarPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile picture")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)

            HStack(spacing: 12) {
                ProfileAvatarBadge(
                    presetID: avatarPresetID,
                    fallbackInitials: initialsForPreview
                )
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text(avatarPresetTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                    Text("Choose one of 9 avatars or leave it empty.")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                    if avatarPresetID != nil {
                        Button("Remove picture") {
                            avatarPresetID = nil
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                Button {
                    avatarPresetID = nil
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Brand.secondarySurface)
                            .overlay {
                                Image(systemName: "person.crop.circle.badge.xmark")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(Brand.mutedText)
                            }
                            .frame(height: 72)

                        Text("No Picture")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(tileBackground(isSelected: avatarPresetID == nil))
                    .overlay(tileBorder(isSelected: avatarPresetID == nil))
                }
                .buttonStyle(.plain)

                ForEach(ProfileAvatarPresets.all) { preset in
                    Button {
                        avatarPresetID = preset.id
                    } label: {
                        VStack(spacing: 6) {
                            ProfileAvatarArtwork(preset: preset)
                                .frame(height: 72)
                            Text(preset.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 20, alignment: .top)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(tileBackground(isSelected: avatarPresetID == preset.id))
                        .overlay(tileBorder(isSelected: avatarPresetID == preset.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .glassCard(cornerRadius: 18, tint: Brand.cardBackground)
    }

    private var avatarPresetTitle: String {
        ProfileAvatarPresets.preset(for: avatarPresetID)?.name ?? "No profile picture"
    }

    private var initialsForPreview: String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Player" : trimmed
        let chars = source
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        return chars.isEmpty ? "P" : String(chars)
    }

    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Brand.accentGreen.opacity(0.12) : Brand.secondarySurface)
    }

    private func tileBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? Brand.primaryText : Brand.softOutline, lineWidth: isSelected ? 2 : 1)
    }
}

#Preview {
    ProfileSetupView()
        .environmentObject(AppState())
        .background(Brand.pageGradient)
}
