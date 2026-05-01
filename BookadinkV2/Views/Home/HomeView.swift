import CoreLocation
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedTab: AppTab

    @EnvironmentObject private var locationManager: LocationManager

    @State private var selectedGame: Game? = nil
    @State private var errorDismissed = false
    @State private var showNearbyDiscovery = false
    @State private var suburbSearchText: String = ""
    @State private var suburbSearchLocation: CLLocation? = nil
    @State private var isGeocodingSuburb: Bool = false

    @StateObject private var newsService = PickleballNewsService()
    @State private var articleLink: ArticleLink? = nil

    private let isOnIPad = UIDevice.current.userInterfaceIdiom == .pad

    // MARK: - Derived data

    private var firstName: String {
        appState.profile?.fullName.components(separatedBy: " ").first ?? "there"
    }

    /// Number of additional confirmed bookings on the same calendar day as
    /// `nextUpcomingBooking`, after that game's start time. Zero when there
    /// is only one game that day (so the indicator stays hidden).
    private var sameDayFollowOnCount: Int {
        guard let next = nextUpcomingBooking, let nextGame = next.game else { return 0 }
        let cal = Calendar.current
        let now = Date()
        return appState.bookings.filter { item in
            guard let game = item.game,
                  game.id != nextGame.id,
                  game.dateTime > nextGame.dateTime,
                  game.dateTime >= now,
                  cal.isDate(game.dateTime, inSameDayAs: nextGame.dateTime) else { return false }
            if case .confirmed = item.booking.state { return true }
            return false
        }.count
    }

    private var nextUpcomingBooking: BookingWithGame? {
        let now = Date()
        return appState.bookings
            .filter { item in
                guard let game = item.game, game.dateTime >= now else { return false }
                if case .confirmed = item.booking.state { return true }
                return false
            }
            .min(by: {
                ($0.game?.dateTime ?? .distantFuture) < ($1.game?.dateTime ?? .distantFuture)
            })
    }

    /// Live or suburb-geocoded location used for distance filtering and sorting.
    private var effectiveUserLocation: CLLocation? {
        locationManager.userLocation ?? suburbSearchLocation
    }

    /// All active games in the next 7 days within 75 km (or all if no location),
    /// sorted soonest-first then nearest-first. Used to drive the carousel and
    /// determine whether a "More games" CTA is needed.
    private var allQualifyingNearbyGames: [Game] {
        let now     = Date()
        let window  = now.addingTimeInterval(7 * 24 * 3_600)
        let clubs   = appState.clubs
        let userLoc = effectiveUserLocation

        print("[HomeFilter] total=\(appState.allUpcomingGames.count) userLoc=\(userLoc != nil ? "SET" : "NIL")")

        // Only treat a booking as "active" if the user actually holds a spot or is waitlisted.
        // Cancelled and failed-payment bookings must not hide the game from this list.
        let bookedGameIDs = Set(appState.bookings.compactMap { item -> UUID? in
            switch item.booking.state {
            case .confirmed, .waitlisted: return item.game?.id
            default: return nil
            }
        })
        let timeFiltered: [Game] = appState.allUpcomingGames.filter {
            let inWindow  = $0.dateTime >= now && $0.dateTime <= window
            let isUpcoming = $0.status == "upcoming"
            let notBooked  = !bookedGameIDs.contains($0.id)
            if !inWindow || !isUpcoming || !notBooked {
                let days = Int($0.dateTime.timeIntervalSinceNow / 86_400)
                print("[HomeFilter]   DROP '\($0.title)' status=\($0.status) days=\(days) booked=\(!notBooked) inWindow=\(inWindow)")
            }
            return inWindow && isUpcoming && notBooked
        }
        print("[HomeFilter] after time+status filter: \(timeFiltered.count)")

        // When we have a user location, keep games within 75 km. Games whose
        // coordinates cannot be resolved (club has no lat/lng yet and venue
        // prefetch hasn't finished) are included so they don't silently vanish.
        let candidates: [Game] = timeFiltered.filter { game in
            guard let userLoc else { return true }
            guard let gameLoc = LocationService.location(
                for: game,
                venues: appState.clubVenuesByClubID[game.clubID] ?? [],
                clubs: clubs
            ) else {
                // Location unresolvable — include rather than silently drop.
                return true
            }
            let km = userLoc.distance(from: gameLoc) / 1_000
            if km > 75 { print("[HomeFilter]   DROP '\(game.title)' too far: \(String(format: "%.1f", km)) km") }
            return km <= 75
        }
        print("[HomeFilter] candidates=\(candidates.count)")

        let available = rankNearbyGames(candidates.filter { !$0.isFull }, from: userLoc)
        let full      = rankNearbyGames(candidates.filter { $0.isFull }, from: userLoc)

        return available + full
    }

    /// Up to 10 qualifying games shown in the carousel.
    private var upcomingNearbyGames: [Game] {
        Array(allQualifyingNearbyGames.prefix(10))
    }

    /// True when there are more than 10 qualifying games — triggers the "More games" CTA.
    private var hasMoreNearbyGames: Bool {
        allQualifyingNearbyGames.count > 10
    }

    /// Sorts games into today / this-week / later buckets, then within each bucket
    /// ranks by effective distance — actual distance minus a boost adjustment:
    ///   +2 boost (1 000 m) for clubs the user has already booked at
    ///   +1 boost (500 m)   for games matching the user's skill level
    /// When no user location is available, falls back to soonest-first within each bucket.
    private func rankNearbyGames(_ games: [Game], from userLoc: CLLocation?) -> [Game] {
        let boostedClubIDs = Set(appState.bookings.compactMap { $0.game?.clubID })
        let clubs = appState.clubs
        let venuesByClubID = appState.clubVenuesByClubID

        func effectiveDistance(_ game: Game) -> CLLocationDistance {
            guard let userLoc else { return .greatestFiniteMagnitude }
            let actual = LocationService.distance(
                from: userLoc,
                to: LocationService.location(for: game, venues: venuesByClubID[game.clubID] ?? [], clubs: clubs)
            ) ?? .greatestFiniteMagnitude
            var boost = 0
            if boostedClubIDs.contains(game.clubID) { boost += 2 }
       
            
            return max(0, actual - Double(boost) * 500)
        }

        let now   = Date()
        let in24h = now.addingTimeInterval(24 * 3_600)
        let in7d  = now.addingTimeInterval(7 * 24 * 3_600)

        func sortBucket(_ bucket: [Game]) -> [Game] {
            guard userLoc != nil else { return bucket.sorted { $0.dateTime < $1.dateTime } }
            return bucket.sorted { a, b in
                let da = effectiveDistance(a)
                let db = effectiveDistance(b)
                if da == db { return a.dateTime < b.dateTime }
                return da < db
            }
        }

        return sortBucket(games.filter { $0.dateTime < in24h })
             + sortBucket(games.filter { $0.dateTime >= in24h && $0.dateTime < in7d })
             + sortBucket(games.filter { $0.dateTime >= in7d })
    }

    private var showErrorBanner: Bool {
        !errorDismissed
            && appState.clubsLoadErrorMessage != nil
            && !appState.isUsingLiveClubData
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Brand.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    topBarSection

                    if showErrorBanner {
                        networkBanner
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .padding(.horizontal, 4)
                    }

                    heroSection

                    nextGameSection

                    nearbyGamesSection

                    newsSection

                    trustRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .onAppear { locationManager.requestPermissionIfNeeded() }
            .refreshable {
                async let clubsRefresh: Void   = appState.refreshClubs()
                async let bookingsRefresh: Void = appState.refreshBookings()
                async let gamesRefresh: Void    = appState.refreshUpcomingGames()
                _ = await (clubsRefresh, bookingsRefresh, gamesRefresh)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedGame) { game in
            NavigationStack {
                GameDetailView(game: game)
            }
        }
        // Explore Nearby — fullScreenCover on iPad, sheet on iPhone
        .sheet(isPresented: Binding(
            get: { showNearbyDiscovery && !isOnIPad },
            set: { showNearbyDiscovery = $0 }
        )) { NearbyDiscoveryView() }
        .fullScreenCover(isPresented: Binding(
            get: { showNearbyDiscovery && isOnIPad },
            set: { showNearbyDiscovery = $0 }
        )) { NearbyDiscoveryView() }
        // News article — always fullScreenCover; Safari VC is best full-screen on all devices
        .fullScreenCover(item: $articleLink) { link in
            SafariView(url: link.url)
                .ignoresSafeArea()
        }
        .task { await newsService.load() }
        .task(id: nextUpcomingBooking?.game?.id) {
            if let game = nextUpcomingBooking?.game {
                await appState.refreshAttendees(for: game)
            }
        }
    }

    // MARK: - Top Bar

    private var topBarSection: some View {
        HStack(alignment: .center) {
            Text("Bookadink")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Brand.secondaryText)
            Spacer()
            HStack(spacing: 8) {
                Button {
                    selectedTab = .clubs
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.primaryText)
                        .frame(width: 36, height: 36)
                        .background(Brand.cardBackground, in: Circle())
                        .overlay(Circle().stroke(Brand.softOutline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = .notifications
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Brand.primaryText)
                            .frame(width: 36, height: 36)
                            .background(Brand.cardBackground, in: Circle())
                            .overlay(Circle().stroke(Brand.softOutline, lineWidth: 1))
                        if appState.unreadNotificationCount > 0 {
                            Circle()
                                .fill(Color(hex: "FF6B5A"))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Brand.appBackground, lineWidth: 1.5))
                                .offset(x: 1, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome back, \(firstName)")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Brand.secondaryText)
                .padding(.bottom, 12)

            displayHeadline

            Text("Discover premium clubs, book social games, and meet players at your level.")
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(Brand.secondaryText)
                .lineSpacing(3)
                .padding(.top, 14)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var displayHeadline: some View {
        let suburb = nextGameSuburb ?? "your area"
        VStack(alignment: .leading, spacing: 0) {
            Text("Your next game")
                .font(.system(size: 42, weight: .bold))
                .tracking(-1.5)
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .bottom, spacing: 0) {
                Text("is waiting in ")
                    .font(.system(size: 42, weight: .bold))
                    .tracking(-1.5)
                    .foregroundStyle(Brand.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Brand.accentGreen.opacity(0.65))
                        .frame(height: 9)
                        .offset(y: -3)
                    Text(suburb + ".")
                        .font(.system(size: 42, weight: .bold))
                        .tracking(-1.5)
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    /// Suburb of the next upcoming confirmed game's club.
    private var nextGameSuburb: String? {
        guard let item = nextUpcomingBooking, let game = item.game else { return nil }
        // Try primary venue suburb first
        if let venue = appState.clubVenuesByClubID[game.clubID]?.first(where: { $0.isPrimary }),
           let suburb = venue.suburb, !suburb.trimmingCharacters(in: .whitespaces).isEmpty {
            return suburb
        }
        // Fall back to club's suburb
        if let club = appState.clubs.first(where: { $0.id == game.clubID }),
           let suburb = club.suburb, !suburb.trimmingCharacters(in: .whitespaces).isEmpty {
            return suburb
        }
        return nil
    }

    // MARK: - Network Banner

    private var networkBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
            Text(AppCopy.friendlyError(appState.clubsLoadErrorMessage ?? ""))
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { errorDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss network warning")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    // MARK: - Search Bar

    private var searchBarButton: some View {
        Button {
            selectedTab = .clubs
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Brand.secondaryText)
                Text("Search games, clubs or location")
                    .foregroundStyle(Brand.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .glassCard(cornerRadius: 20, tint: Brand.cardBackground)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Your Next Game

    @ViewBuilder
    private var nextGameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(Color(hex: "1A8A2E"))
                    .frame(width: 6, height: 6)
                Text("Your next game · \(nextUpcomingBooking.flatMap { $0.game }.map { relativeDateLabel(for: $0.dateTime) } ?? "upcoming")")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.secondaryText)
            }
            .padding(.horizontal, 4)

            if let item = nextUpcomingBooking, let game = item.game {
                let nextClub = appState.clubs.first(where: { $0.id == game.clubID })
                let clubName = nextClub?.name ?? ""
                let nextVenues = appState.clubVenuesByClubID[game.clubID] ?? []
                let nextResolvedVenue = LocationService.resolvedVenue(for: game, venues: nextVenues)
                VStack(alignment: .leading, spacing: 8) {
                    let distLabel = LocationService.distanceLabel(
                        from: locationManager.userLocation,
                        game: game,
                        venues: appState.clubVenuesByClubID[game.clubID] ?? [],
                        clubs: appState.clubs)
                    HomeNextGameCard(
                        game: game,
                        clubName: clubName,
                        isBooked: true,
                        resolvedVenue: nextResolvedVenue,
                        distanceLabel: distLabel,
                        attendeePreviews: appState.attendeesByGameID[game.id] ?? [],
                        onTap: { selectedGame = game }
                    )

                    // Same-day follow-on indicator — only shown when the user has
                    // additional confirmed games later today beyond the hero card
                    if sameDayFollowOnCount > 0 {
                        moreTodayIndicator(count: sameDayFollowOnCount)
                    }
                }
            } else {
                nextGameEmptyState
            }
        }
    }

    @ViewBuilder
    private func nextGameContextStrip(_ game: Game) -> some View {
        let venues = appState.clubVenuesByClubID[game.clubID] ?? []
        let dist   = LocationService.distanceLabel(from: locationManager.userLocation, game: game, venues: venues, clubs: appState.clubs)

        if let dist {
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

    private func moreTodayIndicator(count: Int) -> some View {
        Button {
            selectedTab = .bookings
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.caption2.weight(.semibold))
                Text("+\(count) more today")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Brand.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Brand.secondarySurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var nextGameEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 26))
                    .foregroundStyle(Brand.secondaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No upcoming games")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                    Text("Browse clubs and book your next session.")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            Button {
                selectedTab = .clubs
            } label: {
                Text("Find a Game")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Brand.primaryText, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, tint: Brand.cardBackground)
    }

    // MARK: - Games Near You

    private var nearbyGamesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Games · Perth")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.secondaryText)
                    Text("Games near you")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Brand.primaryText)
                }
                Spacer()
                Button { showNearbyDiscovery = true } label: {
                    Text("See all")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Brand.secondarySurface, in: Capsule())
                        .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if upcomingNearbyGames.isEmpty {
                if effectiveUserLocation == nil {
                    nearbyGamesSuburbSearch
                } else {
                    nearbyGamesEmptyState
                }
            } else {
                // Horizontal carousel — breaks out of parent 16pt padding so cards
                // reach the screen edges, then re-applies the leading inset inside.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(upcomingNearbyGames) { game in
                            nearbyGameCard(game)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -16)

                if hasMoreNearbyGames {
                    Button { showNearbyDiscovery = true } label: {
                        HStack {
                            Text("More games in the next week")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Brand.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Subtle hint when location access is denied — only shown once, non-intrusive
            if locationManager.permissionStatus == .denied
                || locationManager.permissionStatus == .restricted {
                locationPermissionHint
            }
        }
    }

    private var nearbyGamesEmptyState: some View {
        Button { showNearbyDiscovery = true } label: {
            VStack(spacing: 14) {
                Image(systemName: "map")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Brand.sportPop)
                VStack(spacing: 5) {
                    Text("Open map to explore games")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Brand.ink)
                    Text("Discover courts and games near you")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.secondaryText)
                }
                Text("Explore")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Brand.sportPop, in: Capsule())
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 16)
            .glassCard(cornerRadius: 16, tint: Brand.cardBackground)
        }
        .buttonStyle(.plain)
    }

    /// Carousel card — identical pattern to BookingCard in BookingsListView.
    @ViewBuilder
    private func nearbyGameCard(_ game: Game) -> some View {
        let club          = appState.clubs.first(where: { $0.id == game.clubID })
        let venues        = appState.clubVenuesByClubID[game.clubID] ?? []
        let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
        let isMembersOnly = (club?.membersOnly == true) && !nearbyCardIsUserMember(of: club)
        let bookingEntry  = appState.bookings.first(where: { $0.game?.id == game.id })
        let isBooked      = nearbyCardIsBooked(bookingEntry?.booking.state)
        let isWaitlisted  = nearbyCardIsWaitlisted(bookingEntry?.booking.state)

        Button { selectedGame = game } label: {
            HomeNearbyGameCard(
                game: game,
                clubName: club?.name ?? "",
                isBooked: isBooked,
                isWaitlisted: isWaitlisted,
                isMembersOnly: isMembersOnly,
                resolvedVenue: resolvedVenue,
                distanceLabel: LocationService.distanceLabel(
                    from: locationManager.userLocation,
                    game: game,
                    venues: venues,
                    clubs: appState.clubs)
            )
        }
        .buttonStyle(.plain)
    }

    private func nearbyCardIsUserMember(of club: Club?) -> Bool {
        guard let club else { return false }
        if appState.isClubAdmin(for: club) { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown: return true
        default: return false
        }
    }

    private func nearbyCardIsBooked(_ state: BookingState?) -> Bool {
        guard let state else { return false }
        if case .confirmed = state { return true }
        return false
    }

    private func nearbyCardIsWaitlisted(_ state: BookingState?) -> Bool {
        guard let state else { return false }
        if case .waitlisted = state { return true }
        return false
    }

    /// Shown when no live location and no suburb has been geocoded yet.
    private var nearbyGamesSuburbSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.secondaryText)
                TextField("Search by suburb…", text: $suburbSearchText)
                    .font(.subheadline)
                    .submitLabel(.search)
                    .onSubmit { geocodeSuburb() }
                if isGeocodingSuburb {
                    ProgressView().scaleEffect(0.75)
                }
            }
            .padding(12)
            .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Enable location or enter a suburb to see games near you.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 2)
        }
    }

    private func geocodeSuburb() {
        let query = suburbSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isGeocodingSuburb = true
        CLGeocoder().geocodeAddressString(query) { placemarks, _ in
            DispatchQueue.main.async {
                self.suburbSearchLocation = placemarks?.first?.location
                self.isGeocodingSuburb = false
            }
        }
    }

    private var locationPermissionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
            Text("Enable location in Settings to see games nearest to you.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Trust Row

    private var trustRow: some View {
        HStack(spacing: 0) {
            Spacer()
            trustItem(icon: "lock", label: "Server-secured")
            Spacer()
            Rectangle().fill(Brand.softOutline).frame(width: 1, height: 16)
            Spacer()
            trustItem(icon: "bolt", label: "Instant holds")
            Spacer()
            Rectangle().fill(Brand.softOutline).frame(width: 1, height: 16)
            Spacer()
            trustItem(icon: "person.2", label: "12.4k players")
            Spacer()
        }
        .padding(.vertical, 14)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
    }

    private func trustItem(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.secondaryText)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.secondaryText)
        }
    }

    // MARK: - News (From The Dink)

    @ViewBuilder
    private var newsSection: some View {
        if newsService.isLoading {
            VStack(alignment: .leading, spacing: 10) {
                newsSectionHeader
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.secondarySurface)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(ProgressView().tint(Brand.secondaryText))
            }
        } else if !newsService.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                newsSectionHeader

                // Featured article (first item)
                if let featured = newsService.items.first {
                    Button {
                        articleLink = ArticleLink(url: featured.url)
                    } label: {
                        NewsCardFeatured(article: featured)
                    }
                    .buttonStyle(.plain)
                }

                // List articles in a card container
                if newsService.items.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(Array(newsService.items.dropFirst().prefix(3).enumerated()), id: \.element.id) { idx, article in
                            Button {
                                articleLink = ArticleLink(url: article.url)
                            } label: {
                                NewsListRow(article: article, showTopDivider: idx > 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
                }

                // More button
                if newsService.items.count > 1 {
                    HStack {
                        Spacer()
                        Text("More from The Dink")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Brand.primaryText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.primaryText)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
                }
            }
        }
        // Empty on feed failure — no orphaned header
    }

    private var newsSectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(Brand.accentGreen).frame(width: 6, height: 6)
                    Text("From The Dink")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.secondaryText)
                }
                Text("Pickleball reads")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Brand.primaryText)
            }
            Spacer()
            Text("All stories")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Brand.secondarySurface, in: Capsule())
                .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
        }
    }

    // MARK: - Helpers

    private func relativeDateLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if let inSevenDays = cal.date(byAdding: .day, value: 7, to: Date()), date < inSevenDays {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            return "This \(fmt.string(from: date))"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM"
        return fmt.string(from: date)
    }

}

// MARK: - News Support Models

private struct ArticleLink: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - HomeNextGameCard — hero card for "Your next game" slot

private struct HomeNextGameCard: View {
    let game: Game
    let clubName: String
    var isBooked: Bool = false
    var isWaitlisted: Bool = false
    var resolvedVenue: ClubVenue? = nil
    var distanceLabel: String? = nil
    var attendeePreviews: [GameAttendee] = []
    var onTap: (() -> Void)? = nil

    // MARK: Formatters

    private static let heroDateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEE d MMM"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f
    }()

    // MARK: Derived

    private var heroDateText: String {
        let date = Self.heroDateFmt.string(from: game.dateTime).uppercased()
        let time = Self.timeFmt.string(from: game.dateTime).uppercased()
        return "\(date) · \(time)"
    }

    private var endTime: Date {
        Calendar.current.date(byAdding: .minute, value: game.durationMinutes, to: game.dateTime) ?? game.dateTime
    }

    private var timeRangeText: String {
        "\(Self.timeFmt.string(from: game.dateTime)) – \(Self.timeFmt.string(from: endTime))"
    }

    private var venueName: String {
        if let v = resolvedVenue?.venueName, !v.isEmpty { return v }
        return clubName
    }

    private var venueSuburb: String {
        resolvedVenue?.suburb?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private var venueSubLine: String {
        let sub = venueSuburb
        if let dist = distanceLabel, !sub.isEmpty { return "\(sub) · \(dist)" }
        if !sub.isEmpty { return sub }
        return distanceLabel ?? ""
    }

    private var heroChipText: String {
        clubName.uppercased()
    }

    private var timeSubLine: String {
        var parts: [String] = []
        switch game.gameFormat.lowercased() {
        case "round_robin": parts.append("Round-robin")
        case "king_of_court": parts.append("King of Court")
        case "open_play": break
        case "random": parts.append("Random")
        default:
            let s = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
            if !s.isEmpty { parts.append(s) }
        }
        switch game.gameType.lowercased() {
        case "doubles": parts.append("doubles")
        case "singles": parts.append("singles")
        case "mixed": parts.append("mixed")
        default: break
        }
        switch game.skillLevel.lowercased() {
        case "beginner":     parts.append("2.0 – 3.0")
        case "intermediate": parts.append("3.0 – 4.0")
        case "advanced":     parts.append("4.0+")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private var ctaLabel: String {
        if game.status == "cancelled" { return "Cancelled" }
        if isBooked    { return "You're in" }
        if isWaitlisted { return "On waitlist" }
        if game.isFull  { return "Game is full" }
        return "I'm in"
    }

    private var ctaBackground: Color {
        if game.status == "cancelled" { return Brand.secondarySurface }
        if isBooked || !game.isFull   { return Brand.accentGreen }
        return Brand.secondarySurface
    }

    private var ctaForeground: Color {
        if game.status == "cancelled" || game.isFull { return Brand.secondaryText }
        return Brand.primaryText
    }

    // Tonal gradient picked from clubID hash so it's stable per club
    private var gradient: LinearGradient {
        let palettes: [(Color, Color)] = [
            (Brand.tonalNavyBase, Brand.tonalNavyDeep),
            (Brand.tonalCharcoalBase, Brand.tonalCharcoalDeep),
            (Brand.tonalForestBase, Brand.tonalForestDeep),
            (Brand.tonalTanBase, Brand.tonalTanDeep),
            (Brand.tonalRoseBase, Brand.tonalRoseDeep),
            (Brand.tonalSlateBase, Brand.tonalSlateDeep),
        ]
        let (base, deep) = palettes[abs(game.clubID.hashValue) % palettes.count]
        return LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            heroArea
            detailArea
        }
        .background(Brand.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    // MARK: Hero

    private var heroArea: some View {
        ZStack(alignment: .bottom) {
            gradient
            stripeOverlay
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.06), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.22), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                // Top: date · time — status pill
                HStack(alignment: .top) {
                    Text(heroDateText)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    heroStatusPill
                }
                Spacer(minLength: 8)
                // Title
                Text(game.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                // Bottom: club chip + avatar stack
                HStack(alignment: .center, spacing: 0) {
                    darkGlassChip(heroChipText)
                    Spacer()
                    avatarStackRow
                }
            }
            .padding(14)
        }
        .frame(height: 186)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
    }

    private var stripeOverlay: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                ctx.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
                x += 14
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var heroStatusPill: some View {
        if game.status == "cancelled" {
            heroPill("Cancelled", bg: .black.opacity(0.55), fg: .white)
        } else if isBooked {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("You're in").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Brand.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Brand.accentGreen, in: Capsule())
        } else if isWaitlisted {
            heroPill("Waitlist", bg: .black.opacity(0.55), fg: .white)
        } else if game.isFull {
            heroPill("Full", bg: .black.opacity(0.55), fg: .white)
        } else if let left = game.spotsLeft, left <= 5 {
            heroPill(left == 1 ? "1 spot left" : "\(left) spots left",
                     bg: Color(hex: "FFDE96").opacity(0.92), fg: Color(hex: "7A4A00"))
        }
    }

    private func heroPill(_ label: String, bg: Color, fg: Color) -> some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bg, in: Capsule())
    }

    private func darkGlassChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private static func initials(for name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    private var avatarStackRow: some View {
        // Show up to 4 confirmed attendees; hide the row entirely if none are loaded yet
        let confirmed = attendeePreviews.filter {
            if case .confirmed = $0.booking.state { return true }
            return false
        }
        let visible = Array(confirmed.prefix(4))
        guard !visible.isEmpty else { return AnyView(EmptyView()) }

        let diameter: CGFloat = 24
        let overlap: CGFloat = 14
        let totalWidth = diameter + CGFloat(visible.count - 1) * overlap + 4

        return AnyView(
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    ForEach(visible.indices, id: \.self) { i in
                        let attendee = visible[i]
                        Circle()
                            .fill(AvatarGradients.resolveGradient(forKey: attendee.avatarColorKey))
                            .frame(width: diameter, height: diameter)
                            .overlay {
                                Text(Self.initials(for: attendee.userName))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1.5))
                            .offset(x: CGFloat(i) * overlap)
                    }
                }
                .frame(width: totalWidth, alignment: .leading)

                if let count = game.confirmedCount {
                    Text("\(count)/\(game.maxSpots) going")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        )
    }

    // MARK: Detail area

    private var detailArea: some View {
        VStack(spacing: 0) {
            // Two-column grid: VENUE | TIME
            HStack(alignment: .top, spacing: 12) {
                detailColumn(label: "VENUE",
                             main: venueName,
                             sub: venueSubLine.isEmpty ? nil : venueSubLine)
                Rectangle().fill(Brand.softOutline).frame(width: 1).padding(.vertical, 4)
                detailColumn(label: "TIME",
                             main: timeRangeText,
                             sub: timeSubLine.isEmpty ? nil : timeSubLine)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // CTA row
            HStack(spacing: 8) {
                Button {
                    onTap?()
                } label: {
                    Text(ctaLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ctaForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(ctaBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(game.status == "cancelled")

                iconActionButton(systemImage: "calendar")
                iconActionButton(systemImage: "square.and.arrow.up")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func detailColumn(label: String, main: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Brand.tertiaryText)
            Text(main)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let sub {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconActionButton(systemImage: String) -> some View {
        Button { } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.primaryText)
                .frame(width: 46, height: 46)
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - HomeNearbyGameCard — compact swipe card for "Games near you" carousel

private struct HomeNearbyGameCard: View {
    let game: Game
    let clubName: String
    var isBooked: Bool = false
    var isWaitlisted: Bool = false
    var isMembersOnly: Bool = false
    var resolvedVenue: ClubVenue? = nil
    var distanceLabel: String? = nil

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEE d MMM"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f
    }()

    private var dateTimeText: String {
        "\(Self.dateFmt.string(from: game.dateTime).uppercased()) · \(Self.timeFmt.string(from: game.dateTime).uppercased())"
    }

    private var venueName: String {
        if let v = resolvedVenue?.venueName, !v.isEmpty { return v }
        return clubName
    }

    private var venueSubLine: String {
        let sub = resolvedVenue?.suburb?.trimmingCharacters(in: .whitespaces) ?? ""
        if let dist = distanceLabel, !sub.isEmpty { return "\(sub) · \(dist)" }
        if !sub.isEmpty { return sub }
        return distanceLabel ?? ""
    }

    private var heroChipText: String {
        let sub = resolvedVenue?.suburb?.trimmingCharacters(in: .whitespaces) ?? ""
        return sub.isEmpty ? clubName.uppercased() : sub.uppercased()
    }

    private var priceText: String {
        if let fee = game.feeAmount, fee > 0 {
            return fee.truncatingRemainder(dividingBy: 1) == 0 ? "$\(Int(fee))" : String(format: "$%.2f", fee)
        }
        return "Free"
    }

    private var skillLabel: String? {
        switch game.skillLevel.lowercased() {
        case "beginner":     return "Beginner"
        case "intermediate": return "Intermediate"
        case "advanced":     return "Advanced"
        default: return nil
        }
    }

    private var formatLabel: String? {
        switch game.gameFormat.lowercased() {
        case "open_play", "": return nil
        case "round_robin":   return "Round Robin"
        case "king_of_court": return "King of Court"
        case "random":        return "Random"
        default:
            let s = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
            return s.isEmpty ? nil : s
        }
    }

    private var gradient: LinearGradient {
        let palettes: [(Color, Color)] = [
            (Brand.tonalNavyBase, Brand.tonalNavyDeep),
            (Brand.tonalCharcoalBase, Brand.tonalCharcoalDeep),
            (Brand.tonalForestBase, Brand.tonalForestDeep),
            (Brand.tonalTanBase, Brand.tonalTanDeep),
            (Brand.tonalRoseBase, Brand.tonalRoseDeep),
            (Brand.tonalSlateBase, Brand.tonalSlateDeep),
        ]
        let (base, deep) = palettes[abs(game.clubID.hashValue) % palettes.count]
        return LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            heroArea
            // Content
            contentArea
        }
        .frame(width: 248)
        .background(Brand.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
    }

    private var heroArea: some View {
        ZStack(alignment: .bottom) {
            gradient
            Canvas { ctx, size in
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    ctx.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
                    x += 14
                }
            }
            .allowsHitTesting(false)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.22), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Club chip + status pill overlaid
            VStack {
                HStack {
                    Spacer()
                    compactStatusPill
                }
                .padding(.top, 10)
                .padding(.trailing, 10)
                Spacer()
                HStack {
                    Text(heroChipText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            // Members only badge
            if isMembersOnly {
                Text("Members only")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.orange, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
        }
        .frame(height: 132)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
    }

    @ViewBuilder
    private var compactStatusPill: some View {
        if isBooked {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                Text("You're in").font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Brand.primaryText)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Brand.accentGreen, in: Capsule())
        } else if isWaitlisted {
            Text("Waitlist")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
        } else if game.isFull {
            Text("Full")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
        } else if let left = game.spotsLeft, left <= 5 {
            Text(left == 1 ? "1 spot" : "\(left) spots")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(hex: "7A4A00"))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(hex: "FFDE96").opacity(0.92), in: Capsule())
        }
    }

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Date/time
            Text(dateTimeText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)

            // Title
            Text(game.title)
                .font(.system(size: 15.5, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Brand.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Venue
            if !venueName.isEmpty || !venueSubLine.isEmpty {
                Text([venueName, venueSubLine].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }

            // Format/skill chips
            HStack(spacing: 5) {
                if let f = formatLabel { metaChip(f) }
                if let s = skillLabel  { metaChip(s) }
            }

            // Footer: avatars + price
            HStack(alignment: .center) {
                // Mini avatar stack (3 circles)
                HStack(spacing: 0) {
                    ForEach([Color(hex: "2A3A52"), Color(hex: "1F3D2C"), Color(hex: "3A3D40")].indices, id: \.self) { i in
                        let colors: [Color] = [Color(hex: "2A3A52"), Color(hex: "1F3D2C"), Color(hex: "3A3D40")]
                        Circle()
                            .fill(colors[i])
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Brand.cardBackground, lineWidth: 1.5))
                            .offset(x: CGFloat(-i * 5))
                            .zIndex(Double(3 - i))
                    }
                }
                .frame(width: 36, alignment: .leading)

                if let count = game.confirmedCount {
                    Text("\(count)/\(game.maxSpots)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                }

                Spacer()

                Text(priceText)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.primaryText)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private func metaChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Brand.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.softOutline, lineWidth: 1))
    }
}

// MARK: - Featured news card (first article, full-width)

private struct NewsCardFeatured: View {
    let article: PickleballNewsItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero image / tonal placeholder
            ZStack {
                if let imgURL = article.imageURL {
                    AsyncImage(url: imgURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            tonalPlaceholder
                        }
                    }
                } else {
                    tonalPlaceholder
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 170)
            .clipped()

            // Text
            VStack(alignment: .leading, spacing: 8) {
                Text(article.title)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(article.source)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Brand.tertiaryText)
                    if let date = article.publishedAt {
                        Text("·")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Brand.tertiaryText)
                        Text(date.relativeDisplay())
                            .font(.system(size: 11.5))
                            .foregroundStyle(Brand.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .background(Brand.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
    }

    private var tonalPlaceholder: some View {
        LinearGradient(
            colors: [Brand.tonalNavyBase, Brand.tonalNavyDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "newspaper.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.2))
        )
    }
}

// MARK: - News list row (articles 2–4)

private struct NewsListRow: View {
    let article: PickleballNewsItem
    let showTopDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showTopDivider {
                Divider().background(Brand.dividerColor)
            }

            HStack(alignment: .top, spacing: 12) {
                // Thumbnail — frame applied inside phase switch to prevent layout overflow
                if let imgURL = article.imageURL {
                    AsyncImage(url: imgURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        default:
                            thumbnailPlaceholder
                        }
                    }
                } else {
                    thumbnailPlaceholder
                }

                // Text stack
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.source.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.tertiaryText)
                        .kerning(0.4)

                    Text(article.title)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.tertiaryText)
                        if let date = article.publishedAt {
                            Text(date.relativeDisplay())
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.tertiaryText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var thumbnailPlaceholder: some View {
        LinearGradient(
            colors: [Brand.tonalForestBase, Brand.tonalForestDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// Helper to make a view not collapse vertically
private extension View {
    func flexibleFloor() -> some View { self }
}
