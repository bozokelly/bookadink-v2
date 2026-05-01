import SwiftUI

struct ProfileDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showEditProfile = false
    @State private var showSignOutAlert = false
    @State private var appeared = false
#if DEBUG
    @State private var jwtCopied = false
#endif

    // MARK: - Credits

    private var clubCreditRows: [(clubID: UUID, clubName: String, balanceCents: Int)] {
        appState.creditBalanceByClubID
            .filter { $0.value > 0 }
            .map { clubID, balance in
                let name = appState.clubs.first(where: { $0.id == clubID })?.name ?? "Club"
                return (clubID: clubID, clubName: name, balanceCents: balance)
            }
            .sorted { $0.clubName < $1.clubName }
    }

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

                    if !clubCreditRows.isEmpty {
                        creditsCard
                            .cardAppear(index: 2, appeared: appeared)
                    }

                    if let profile = appState.profile {
                        DUPRHistoryCard()
                            .cardAppear(index: 3, appeared: appeared)

                        GamesPlayedCard()
                            .cardAppear(index: 4, appeared: appeared)

                        BadgesCard(profile: profile)
                            .cardAppear(index: 5, appeared: appeared)
                    }

#if DEBUG
                    debugJWTButton
                        .cardAppear(index: 6, appeared: appeared)
#endif
                    signOutButton
                        .cardAppear(index: 7, appeared: appeared)
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
                let clubIDs = Set(appState.bookings.compactMap { $0.game?.clubID })
                await withTaskGroup(of: Void.self) { group in
                    for clubID in clubIDs {
                        group.addTask { await appState.refreshCreditBalance(for: clubID) }
                    }
                }
            }
        }
        .task {
            let clubIDs = Set(appState.bookings.compactMap { $0.game?.clubID })
            await withTaskGroup(of: Void.self) { group in
                for clubID in clubIDs {
                    group.addTask { await appState.refreshCreditBalance(for: clubID) }
                }
            }
        }
        .onChange(of: appState.lastCancellationCredit) { _, result in
            guard let clubID = result?.clubID else { return }
            Task { await appState.refreshCreditBalance(for: clubID) }
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
        VStack(spacing: 0) {
            if let profile = appState.profile {
                HStack(spacing: 14) {
                    // Avatar — clipped to circle
                    ProfileAvatarBadge(initials: initials(for: profile.fullName), colorKey: profile.avatarColorKey)
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Brand.softOutline, lineWidth: 1.5))

                    // Name / email / skill + DUPR
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.fullName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text(profile.email)
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                            .lineLimit(1)

                        // Skill + DUPR as plain text — skill label derived from DUPR
                        Group {
                            let liveRating = appState.duprDoublesRating ?? profile.duprRating
                            let skill = duprSkillLabel(for: liveRating, fallback: profile.skillLevel.label)
                            if let r = liveRating {
                                Text("\(skill) · DUPR \(String(format: "%.3f", r))")
                            } else {
                                Text(skill)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .padding(.top, 2)
                    }

                    Spacer()

                    // Edit icon
                    Button { showEditProfile = true } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.pineTeal)
                            .frame(width: 36, height: 36)
                            .background(Brand.pineTeal.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)

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
                .padding(16)
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    // MARK: - Credits

    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.slateBlue)
                Text("Club Credits")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ForEach(Array(clubCreditRows.enumerated()), id: \.element.clubID) { index, row in
                HStack(spacing: 0) {
                    Text(row.clubName)
                        .font(.subheadline)
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "$%.2f", Double(row.balanceCents) / 100))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.slateBlue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                if index < clubCreditRows.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }

            Divider()

            Text("Credits apply automatically at checkout and are club-specific.")
                .font(.caption)
                .foregroundStyle(Brand.mutedText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    // MARK: - Sign Out

    private var signOutButton: some View {
        Button { showSignOutAlert = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline)
                Text("Sign Out")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Brand.mutedText)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

#if DEBUG
    // MARK: - Debug JWT Copy (remove before release)
    private var debugJWTButton: some View {
        Button {
            if let token = appState.authAccessToken, !token.isEmpty {
                UIPasteboard.general.string = token
                jwtCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { jwtCopied = false }
            } else {
                jwtCopied = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: jwtCopied ? "checkmark.circle.fill" : "key.fill")
                    .font(.subheadline)
                Text(appState.authAccessToken != nil ? (jwtCopied ? "JWT copied" : "Copy JWT") : "No active session")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(jwtCopied ? Color.green : Color.orange)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(appState.authAccessToken == nil)
    }
#endif

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
