import CoreLocation
import MapKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedTab: AppTab

    @EnvironmentObject private var locationManager: LocationManager

    @State private var selectedGame: Game? = nil
    @State private var selectedClub: Club? = nil
    @State private var errorDismissed = false
    @State private var showNearbyDiscovery = false
    @State private var showNearbyGames = false
    @State private var suburbSearchText: String = ""
    @State private var suburbSearchLocation: CLLocation? = nil
    @State private var isGeocodingSuburb: Bool = false

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

        let timeFiltered: [Game] = appState.allUpcomingGames.filter {
            $0.dateTime >= now && $0.dateTime <= window && $0.status == "upcoming"
        }
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
            return userLoc.distance(from: gameLoc) <= 75_000
        }

        let available = LocationService.sortByTimeBucketThenProximity(
            candidates.filter { !$0.isFull },
            from: userLoc,
            venuesByClubID: appState.clubVenuesByClubID,
            clubs: clubs)
        let full = LocationService.sortByTimeBucketThenProximity(
            candidates.filter { $0.isFull },
            from: userLoc,
            venuesByClubID: appState.clubVenuesByClubID,
            clubs: clubs)

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

    private var myClubs: [Club] {
        Array(
            appState.clubs
                .filter { club in
                    if appState.isClubAdmin(for: club) { return true }
                    switch appState.membershipState(for: club) {
                    case .approved, .unknown: return true
                    default: return false
                    }
                }
                .prefix(3)
        )
    }

    private var recentNotifications: [AppNotification] {
        Array(
            appState.notifications
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                .prefix(3)
        )
    }

    private var isAdminOfAnyClub: Bool {
        appState.clubs.contains { appState.isClubAdmin(for: $0) }
    }

    private var totalPendingJoinRequests: Int {
        appState.ownerJoinRequestsByClubID.values
            .flatMap { $0 }
            .filter { $0.status == .pending }
            .count
    }

    private var showErrorBanner: Bool {
        !errorDismissed
            && appState.clubsLoadErrorMessage != nil
            && !appState.isUsingLiveClubData
    }

    /// Clubs that have a resolvable coordinate — club-level or primary venue fallback.
    private var clubsWithCoords: [Club] {
        appState.clubs.filter {
            LocationService.location(for: $0, venues: appState.clubVenuesByClubID[$0.id] ?? []) != nil
        }
    }

    /// Camera region for the compact Home preview.
    /// Priority: user location → centroid of clubs with coords → Australia default.
    private var previewCameraPosition: MapCameraPosition {
        if let userLoc = locationManager.userLocation {
            return .region(MKCoordinateRegion(
                center: userLoc.coordinate,
                latitudinalMeters: 15_000,
                longitudinalMeters: 15_000
            ))
        }
        let coords = clubsWithCoords.compactMap { c -> CLLocationCoordinate2D? in
            LocationService.location(for: c, venues: appState.clubVenuesByClubID[c.id] ?? [])?.coordinate
        }
        guard !coords.isEmpty else {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: -25.3, longitude: 133.8),
                latitudinalMeters: 3_000_000,
                longitudinalMeters: 3_000_000
            ))
        }
        let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let avgLng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng),
            latitudinalMeters: 25_000,
            longitudinalMeters: 25_000
        ))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Brand.appBackground.ignoresSafeArea()

            ScrollView {
                // Sections are spaced at 32pt for a calmer, easier-to-scan layout.
                VStack(alignment: .leading, spacing: 32) {
                    headerSection

                    if showErrorBanner {
                        networkBanner
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    searchBarButton

                    nextGameSection

                    nearbyGamesSection

                    mapPreviewSection

                    if !myClubs.isEmpty {
                        yourClubsSection
                    }

                    quickActionsSection

                    if !recentNotifications.isEmpty {
                        recentUpdatesSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
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
        .sheet(item: $selectedClub) { club in
            NavigationStack {
                ClubDetailView(club: club)
            }
        }
        .sheet(isPresented: $showNearbyDiscovery) {
            NearbyDiscoveryView()
        }
        .sheet(isPresented: $showNearbyGames) {
            NearbyGamesView(selectedTab: $selectedTab)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            Text("Hey, \(firstName) 👋")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
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
            sectionHeader("Your Next Game")

            if let item = nextUpcomingBooking, let game = item.game {
                let nextClub = appState.clubs.first(where: { $0.id == game.clubID })
                let clubName = nextClub?.name ?? ""
                let nextVenues = appState.clubVenuesByClubID[game.clubID] ?? []
                let nextResolvedVenue = LocationService.resolvedVenue(for: game, venues: nextVenues)
                VStack(alignment: .leading, spacing: 8) {
                    // Friendly date chip — soft green, not neon
                    Text(relativeDateLabel(for: game.dateTime))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(hex: "1A6B2E"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "80FF00").opacity(0.14), in: Capsule())
                        .padding(.horizontal, 4)

                    Button {
                        selectedGame = game
                    } label: {
                        UnifiedGameCard(game: game, clubName: clubName, isBooked: true,
                                        resolvedVenue: nextResolvedVenue,
                                        onClubTap: nextClub.map { c in { selectedClub = c } })
                    }
                    .buttonStyle(.plain)

                    // Supplementary context strip — venue, duration, skill level
                    // Only shown when there is something meaningful to add beyond the card
                    nextGameContextStrip(game)

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
                sectionHeader("Games Near You")
                Spacer()
                Button { showNearbyGames = true } label: {
                    Text("See All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
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
                                .frame(width: 290)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, -16)

                if hasMoreNearbyGames {
                    Button { showNearbyGames = true } label: {
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
        let totalLoaded = appState.allUpcomingGames.count
        let subtitle: String = totalLoaded == 0
            ? "No games have loaded yet — pull to refresh."
            : "No games found within 75 km. Try pulling to refresh."
        return HStack(spacing: 12) {
            Image(systemName: "sportscourt")
                .font(.system(size: 24))
                .foregroundStyle(Brand.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text("No upcoming games")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, tint: Brand.cardBackground)
    }

    /// Carousel card: game card + members-only badge overlay + distance label below.
    @ViewBuilder
    private func nearbyGameCard(_ game: Game) -> some View {
        let club          = appState.clubs.first(where: { $0.id == game.clubID })
        let venues        = appState.clubVenuesByClubID[game.clubID] ?? []
        let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
        let dist          = LocationService.distanceLabel(from: effectiveUserLocation, game: game, venues: venues, clubs: appState.clubs)
        let isMembersOnly = (club?.membersOnly == true) && !nearbyCardIsUserMember(of: club)
        let bookingEntry  = appState.bookings.first(where: { $0.game?.id == game.id })
        let isBooked      = nearbyCardIsBooked(bookingEntry?.booking.state)
        let isWaitlisted  = nearbyCardIsWaitlisted(bookingEntry?.booking.state)

        VStack(alignment: .leading, spacing: 5) {
            Button { selectedGame = game } label: {
                UnifiedGameCard(
                    game: game,
                    clubName: club?.name ?? "",
                    isBooked: isBooked,
                    isWaitlisted: isWaitlisted,
                    resolvedVenue: resolvedVenue,
                    onClubTap: club.map { c in { selectedClub = c } }
                )
                .overlay(alignment: .topTrailing) {
                    if isMembersOnly {
                        Text("Members only")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange, in: Capsule())
                            .padding(10)
                    }
                }
            }
            .buttonStyle(.plain)

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

    // MARK: - Map / Explore Nearby Preview

    @ViewBuilder
    private var mapPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Explore Nearby")
                Spacer()
                Button {
                    showNearbyDiscovery = true
                } label: {
                    Text("See All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if clubsWithCoords.isEmpty && locationManager.userLocation == nil {
                // Fallback: no coordinate data and no user location — show icon card
                Button { showNearbyDiscovery = true } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Brand.secondarySurface)
                                .frame(width: 52, height: 52)
                            Image(systemName: "map.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Clubs Near You")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.ink)
                            Text("Find clubs and games near you")
                                .font(.caption)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 16, tint: Brand.cardBackground)
                }
                .buttonStyle(.plain)
            } else {
                // Real map preview — non-interactive, tap opens NearbyDiscoveryView
                Button { showNearbyDiscovery = true } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Map(position: .constant(previewCameraPosition)) {
                            ForEach(clubsWithCoords) { club in
                                if let coord = LocationService.location(
                                    for: club,
                                    venues: appState.clubVenuesByClubID[club.id] ?? []
                                )?.coordinate {
                                    Annotation("", coordinate: coord, anchor: .center) {
                                        PickleballMapPin(isSelected: false)
                                    }
                                }
                            }
                            UserAnnotation()
                        }
                        .mapStyle(.standard(pointsOfInterest: .excludingAll))
                        .frame(height: 160)
                        .allowsHitTesting(false)

                        // "Explore Nearby" pill
                        HStack(spacing: 5) {
                            Text("Explore Nearby")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Brand.softOutline, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Your Clubs

    private var yourClubsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Your Clubs")
                Spacer()
                Button {
                    selectedTab = .clubs
                } label: {
                    Text("View All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.plain)
            }

            ForEach(myClubs) { club in
                NavigationLink {
                    ClubDetailView(club: club)
                } label: {
                    ClubRowCard(
                        club: club,
                        membershipState: appState.membershipState(for: club),
                        isAdmin: appState.isClubAdmin(for: club)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Quick Actions")

            let actions = buildQuickActions()
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(actions) { action in
                    Button { action.perform() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: action.icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Brand.ink)
                            Text(action.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.ink)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Brand.softOutline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func buildQuickActions() -> [HomeQuickAction] {
        var actions: [HomeQuickAction] = [
            HomeQuickAction(label: "Book a Game", icon: "calendar.badge.plus") {
                selectedTab = .clubs
            },
            HomeQuickAction(label: "My Bookings", icon: "calendar.circle") {
                selectedTab = .bookings
            },
            HomeQuickAction(label: "Explore Clubs", icon: "building.2") {
                selectedTab = .clubs
            },
        ]
        if isAdminOfAnyClub && totalPendingJoinRequests > 0 {
            let count = totalPendingJoinRequests
            actions.append(HomeQuickAction(label: "Requests (\(count))", icon: "person.badge.clock") {
                selectedTab = .clubs
            })
        }
        return actions
    }

    // MARK: - Recent Updates

    private var recentUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Recent Updates")
                Spacer()
                Button {
                    selectedTab = .notifications
                } label: {
                    Text("See All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                ForEach(Array(recentNotifications.enumerated()), id: \.element.id) { index, notification in
                    Button {
                        selectedTab = .notifications
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            let accent = notificationAccentColor(notification.type)
                            Circle()
                                .fill(accent.opacity(0.12))
                                .overlay(
                                    Image(systemName: notification.type.iconName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(accent)
                                )
                                .frame(width: 34, height: 34)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(notification.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.ink)
                                    .lineLimit(1)
                                Text(notification.body)
                                    .font(.caption)
                                    .foregroundStyle(Brand.secondaryText)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if !notification.read {
                                Circle()
                                    .fill(Brand.pineTeal)
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)

                    if index < recentNotifications.count - 1 {
                        Divider().padding(.horizontal, 14)
                    }
                }
            }
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.bold))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 4)
    }

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

    /// Formats duration in minutes as a compact human-readable string.
    /// Examples: 45 → "45 min", 60 → "1 hr", 90 → "1h 30m", 120 → "2 hrs"
    private func durationText(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remaining = minutes % 60
        if remaining == 0 {
            return hours == 1 ? "1 hr" : "\(hours) hrs"
        }
        return "\(hours)h \(remaining)m"
    }

    /// Returns a display label for skill level, or nil when the level is "all"
    /// (meaning all skill levels are welcome — not meaningful to surface on its own).
    private func skillLevelLabel(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "all", "": return nil
        case "beginner":     return "Beginner"
        case "intermediate": return "Intermediate"
        case "advanced":     return "Advanced"
        default:             return raw.capitalized
        }
    }

    private func notificationAccentColor(_ type: AppNotification.NotificationType) -> Color {
        switch type.accentColorName {
        case "pineTeal":      return Brand.pineTeal
        case "errorRed":      return Brand.errorRed
        case "slateBlue":     return Brand.slateBlue
        case "spicyOrange":   return Brand.spicyOrange
        case "emeraldAction": return Brand.emeraldAction
        default:              return Brand.brandPrimary
        }
    }
}

// MARK: - Quick Action Model

private struct HomeQuickAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    private let _perform: () -> Void

    init(label: String, icon: String, perform: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self._perform = perform
    }

    func perform() { _perform() }
}
