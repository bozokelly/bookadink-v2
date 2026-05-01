import SwiftUI
import UIKit

/// Full "See All" screen for Games Near You.
///
/// Shows all active upcoming games within the next 14 days, ranked by:
///   1. Available spots before full games
///   2. Time bucket (today → this week → later)
///   3. Proximity within each bucket (nearest first)
///   4. Soonest time as a tiebreak
///
/// Presented as a sheet from HomeView. Reuses `UnifiedGameCard` and
/// `LocationService.sortByTimeBucketThenProximity` — no new distance logic.
struct NearbyGamesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTab: AppTab

    @State private var selectedGame: Game? = nil

    // MARK: - Derived data

    private var sortedGames: [Game] {
        let now = Date()
        let clubs = appState.clubs
        let candidates = appState.allUpcomingGames
            .filter { $0.dateTime >= now && $0.status == "upcoming" }

        let available = LocationService.sortByTimeBucketThenProximity(
            candidates.filter { !$0.isFull },
            from: locationManager.userLocation,
            venuesByClubID: appState.clubVenuesByClubID,
            clubs: clubs)
        let full = LocationService.sortByTimeBucketThenProximity(
            candidates.filter {  $0.isFull  },
            from: locationManager.userLocation,
            venuesByClubID: appState.clubVenuesByClubID,
            clubs: clubs)

        return available + full
    }

    private var locationUnavailable: Bool {
        locationManager.permissionStatus == .denied
            || locationManager.permissionStatus == .restricted
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.appBackground.ignoresSafeArea()

                if sortedGames.isEmpty {
                    // Show location hint at top when denied + no games found
                    VStack(spacing: 0) {
                        if locationUnavailable {
                            locationHint
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                        }
                        Spacer()
                        emptyState
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    gameList
                }
            }
            .navigationTitle("Games Near You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Brand.ink)
                }
            }
            .sheet(item: $selectedGame) { game in
                NavigationStack {
                    GameDetailView(game: game)
                }
            }
        }
    }

    // MARK: - Game List

    private var gameList: some View {
        ScrollView {
            if UIDevice.current.userInterfaceIdiom == .pad {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    if locationUnavailable {
                        locationHint.gridCellColumns(2)
                    }
                    ForEach(sortedGames) { game in
                        gameRow(for: game)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if locationUnavailable {
                        locationHint
                    }
                    ForEach(sortedGames) { game in
                        gameRow(for: game)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await appState.refreshUpcomingGames() }
    }

    @ViewBuilder
    private func gameRow(for game: Game) -> some View {
        let club          = appState.clubs.first { $0.id == game.clubID }
        let venues        = appState.clubVenuesByClubID[game.clubID] ?? []
        let distLabel     = LocationService.distanceLabel(from: locationManager.userLocation, game: game, venues: venues, clubs: appState.clubs)
        let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
        let bookingState  = appState.bookings.first { $0.game?.id == game.id }?.booking.state

        let isBooked: Bool = {
            if case .confirmed = bookingState { return true }
            return false
        }()
        let isWaitlisted: Bool = {
            if case .waitlisted = bookingState { return true }
            return false
        }()

        VStack(alignment: .leading, spacing: 4) {
            Button {
                selectedGame = game
            } label: {
                UnifiedGameCard(
                    game: game,
                    clubName: club?.name ?? "",
                    isBooked: isBooked,
                    isWaitlisted: isWaitlisted,
                    resolvedVenue: resolvedVenue
                )
            }
            .buttonStyle(.plain)

            // Distance shown below card (format/skill are now inside the card)
            if let dist = distLabel {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Brand.secondaryText.opacity(0.6))
                    Text(dist)
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sportscourt")
                .font(.system(size: 44))
                .foregroundStyle(Brand.secondaryText)

            VStack(spacing: 6) {
                Text("No nearby games available right now.")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                Text("Check back soon — new games are added regularly.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
                selectedTab = .clubs
            } label: {
                Text("Explore Clubs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Brand.primaryText, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Location Hint

    private var locationHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
            Text("Enable location in Settings for nearby game recommendations.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
