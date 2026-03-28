import SwiftUI

struct ProfileDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showEditProfile = false
    @State private var showSignOutAlert = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 16) {
                    Text("My Profile")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .cardAppear(index: 0, appeared: appeared)

                    profileHeader
                        .cardAppear(index: 1, appeared: appeared)

                    if let profile = appState.profile {
                        DUPRHistoryCard()
                            .cardAppear(index: 2, appeared: appeared)

                        GamesPlayedCard()
                            .cardAppear(index: 3, appeared: appeared)

                        BadgesCard(profile: profile)
                            .cardAppear(index: 4, appeared: appeared)
                    }

                    signOutButton
                        .cardAppear(index: 5, appeared: appeared)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await appState.refreshProfile()
                await appState.refreshBookings(silent: true)
                await appState.refreshMemberships()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet()
        }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                appeared = true
            }
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 14) {
            if let profile = appState.profile {
                // Avatar
                ProfileAvatarBadge(
                    presetID: profile.avatarPresetID,
                    fallbackInitials: initials(for: profile.fullName)
                )
                .frame(width: 72, height: 72)
                .overlay(
                    Circle()
                        .stroke(Brand.softOutline, lineWidth: 2)
                )

                // Name + email
                VStack(spacing: 4) {
                    Text(profile.fullName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Text(profile.email)
                        .font(.subheadline)
                        .foregroundStyle(Brand.mutedText)
                        .lineLimit(1)
                }

                // Pills
                HStack(spacing: 8) {
                    pillBadge(
                        icon: "chart.bar.fill",
                        text: profile.skillLevel.rawValue,
                        color: Brand.slateBlue
                    )
                    if let rating = appState.duprDoublesRating ?? profile.duprRating {
                        pillBadge(
                            icon: "checkmark.shield.fill",
                            text: String(format: "DUPR %.3f", rating),
                            color: Brand.pineTeal
                        )
                    }
                }

                Divider()

                // Edit button
                Button {
                    showEditProfile = true
                } label: {
                    Label("Edit Profile", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .actionBorder(cornerRadius: 12, color: Brand.softOutline)
                }
                .buttonStyle(.plain)

            } else if appState.authState == .signedIn {
                VStack(spacing: 6) {
                    Text(appState.authEmail ?? "Signed in")
                        .font(.headline)
                        .foregroundStyle(Brand.ink)
                    Text("No profile found.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.mutedText)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private func pillBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Sign Out

    private var signOutButton: some View {
        Button {
            showSignOutAlert = true
        } label: {
            Text("Sign Out")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Brand.errorRed, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func initials(for name: String) -> String {
        let chars = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").prefix(2).compactMap(\.first)
        return chars.isEmpty ? "P" : String(chars)
    }
}

// MARK: - Card Appear Modifier

private struct CardAppearModifier: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: appeared ? 0 : 30)
            .opacity(appeared ? 1 : 0)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.8)
                    .delay(Double(index) * 0.07),
                value: appeared
            )
    }
}

extension View {
    func cardAppear(index: Int, appeared: Bool) -> some View {
        modifier(CardAppearModifier(index: index, appeared: appeared))
    }
}
