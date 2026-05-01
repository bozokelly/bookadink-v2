import SwiftUI
import MapKit
import UIKit
import CoreLocation

// MARK: - NearbyDiscoveryView

/// Game-first nearby discovery: an interactive map with availability-colored game pins
/// + a draggable bottom panel listing nearby games sorted by time then proximity.
///
/// Presented as a sheet from Home. Pins are color-coded by spots remaining.
/// Tapping a pin scrolls the list and highlights the card. Tapping a card
/// centers the map on that pin. Tapping the card opens game detail.
struct NearbyDiscoveryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedGameID: UUID? = nil
    @State private var selectedGameForDetail: Game? = nil
    @State private var panelDetent: PanelDetent = .collapsed

    // Filters
    @State private var distanceFilter: DistanceFilter = .all
    @State private var skillFilter: String? = nil
    @State private var dayFilter: DayFilter = .all

    private enum PanelDetent { case minimized, collapsed, expanded }

    enum DistanceFilter: String, CaseIterable, Identifiable {
        case all  = "Any Distance"
        case km5  = "5 km"
        case km10 = "10 km"
        case km25 = "25 km"
        var id: Self { self }
        var meters: Double? {
            switch self {
            case .all:  return nil
            case .km5:  return 5_000
            case .km10: return 10_000
            case .km25: return 25_000
            }
        }
    }

    enum DayFilter: String, CaseIterable, Identifiable {
        case all      = "Any Day"
        case today    = "Today"
        case thisWeek = "This Week"
        var id: Self { self }
    }

    private let minimizedHeight: CGFloat = 72
    private let collapsedHeight: CGFloat = 320
    private var expandedHeight: CGFloat { UIScreen.main.bounds.height * 0.82 }
    private var panelHeight: CGFloat {
        switch panelDetent {
        case .minimized: return minimizedHeight
        case .collapsed: return collapsedHeight
        case .expanded:  return expandedHeight
        }
    }

    // MARK: - Derived data

    /// Upcoming games within the next 7 days, sorted: available today → available soon
    /// → full games last. Capped at 50.
    private var filteredGames: [Game] {
        let now    = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400)
        var games  = appState.allUpcomingGames
            .filter { $0.dateTime >= now && $0.status == "upcoming" && !$0.isScheduled && $0.dateTime <= cutoff }

        // Day filter
        switch dayFilter {
        case .all: break
        case .today:
            games = games.filter { Calendar.current.isDateInToday($0.dateTime) }
        case .thisWeek:
            games = games.filter { $0.dateTime <= cutoff }
        }

        // Skill filter
        if let skill = skillFilter {
            games = games.filter { $0.skillLevel == skill || $0.skillLevel == "all" }
        }

        // Distance filter
        if let maxMeters = distanceFilter.meters, let userLoc = locationManager.userLocation {
            games = games.filter { game in
                let venues = appState.clubVenuesByClubID[game.clubID] ?? []
                guard let loc = LocationService.location(for: game, venues: venues, clubs: appState.clubs) else {
                    return true // no coord — include by default
                }
                return loc.distance(from: userLoc) <= maxMeters
            }
        }

        // Sort: available before full, then by time bucket + proximity
        let userLoc = locationManager.userLocation
        let available = LocationService.sortByTimeBucketThenProximity(
            games.filter { !$0.isFull },
            from: userLoc,
            venuesByClubID: appState.clubVenuesByClubID,
            clubs: appState.clubs
        )
        let full = LocationService.sortByTimeBucketThenProximity(
            games.filter { $0.isFull },
            from: userLoc,
            venuesByClubID: appState.clubVenuesByClubID,
            clubs: appState.clubs
        )
        return Array((available + full).prefix(50))
    }

    /// Games resolved to map coordinates, with jitter applied to co-located games.
    private var gamesWithCoords: [(game: Game, coordinate: CLLocationCoordinate2D, jittered: CLLocationCoordinate2D)] {
        var countByKey: [String: Int] = [:]
        return filteredGames.compactMap { game in
            let venues = appState.clubVenuesByClubID[game.clubID] ?? []
            guard let loc = LocationService.location(for: game, venues: venues, clubs: appState.clubs) else {
                return nil
            }
            let coord = loc.coordinate
            let key   = String(format: "%.5f,%.5f", coord.latitude, coord.longitude)
            let idx   = countByKey[key, default: 0]
            countByKey[key] = idx + 1
            // Radial jitter for co-located games (~13m per step)
            let angle    = Double(idx) * (.pi * 2 / 6)
            let offset   = idx == 0 ? 0.0 : 0.00012
            let jittered = CLLocationCoordinate2D(
                latitude:  coord.latitude  + cos(angle) * offset,
                longitude: coord.longitude + sin(angle) * offset
            )
            return (game: game, coordinate: coord, jittered: jittered)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    HStack(spacing: 0) {
                        mapLayer
                        iPadSidePanel
                            .frame(width: 360)
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        mapLayer
                        bottomPanel
                    }
                    .ignoresSafeArea(edges: .top)
                }
            }
            .navigationTitle("Explore Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Brand.ink)
                }
            }
            .onAppear { setInitialCamera() }
            .task {
                if appState.allUpcomingGames.isEmpty {
                    await appState.refreshUpcomingGames()
                }
                // Load venues for coordinate resolution on any club that lacks them
                let clubsNeedingVenues = appState.clubs.filter {
                    appState.clubVenuesByClubID[$0.id] == nil
                }
                await withTaskGroup(of: Void.self) { group in
                    for club in clubsNeedingVenues {
                        group.addTask { await appState.refreshVenues(for: club) }
                    }
                }
            }
            .sheet(item: $selectedGameForDetail) { game in
                NavigationStack { GameDetailView(game: game) }
            }
        }
    }

    // MARK: - Map layer

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(gamesWithCoords, id: \.game.id) { entry in
                let isSelected = selectedGameID == entry.game.id
                Annotation("", coordinate: entry.jittered, anchor: .bottom) {
                    Button {
                        selectGame(entry.game, openDetail: false)
                    } label: {
                        GameMapPin(game: entry.game, isSelected: isSelected)
                    }
                    .zIndex(isSelected ? 1 : 0)
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedGameID) { _, newID in
            guard let id = newID,
                  let entry = gamesWithCoords.first(where: { $0.game.id == id }) else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: entry.jittered,
                    latitudinalMeters: 3_000,
                    longitudinalMeters: 3_000
                ))
            }
        }
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            dragHandle

            filterRow
                .padding(.bottom, 12)

            panelSectionHeader
                .padding(.bottom, 10)

            if filteredGames.isEmpty {
                emptyGamesState
            } else {
                gameList
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            Brand.appBackground,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 26,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 26,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.12), radius: 24, y: -6)
        .frame(height: panelHeight)
    }

    // MARK: - iPad Side Panel

    private var iPadSidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow
                .padding(.top, 16)
                .padding(.bottom, 12)

            Rectangle()
                .fill(Brand.softOutline)
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            panelSectionHeader
                .padding(.bottom, 10)

            if filteredGames.isEmpty {
                emptyGamesState
            } else {
                gameList
            }
        }
        .background(Brand.appBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Brand.softOutline)
                .frame(width: 1)
        }
    }

    private var dragHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Brand.softOutline)
                .frame(width: 40, height: 3)
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        let dy = value.translation.height
                        switch panelDetent {
                        case .collapsed:
                            if dy < -40      { panelDetent = .expanded  }
                            else if dy > 40  { panelDetent = .minimized }
                        case .expanded:
                            if dy > 40       { panelDetent = .collapsed }
                        case .minimized:
                            if dy < -40      { panelDetent = .collapsed }
                        }
                    }
                }
        )
    }

    private var panelSectionHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEARBY")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(Brand.secondaryText)
                Text("Games near you")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Brand.ink)
            }
            if !filteredGames.isEmpty {
                Text("\(filteredGames.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Brand.secondarySurface, in: Capsule())
                    .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DayFilter.allCases) { day in
                    FilterPill(label: day.rawValue, isActive: dayFilter == day) {
                        dayFilter = day
                    }
                }

                Rectangle()
                    .fill(Brand.softOutline)
                    .frame(width: 1, height: 20)

                FilterPill(label: "All Levels", isActive: skillFilter == nil) {
                    skillFilter = nil
                }
                ForEach(SkillLevel.allCases.filter { $0 != .all }, id: \.rawValue) { skill in
                    FilterPill(label: skill.label, isActive: skillFilter == skill.rawValue) {
                        skillFilter = (skillFilter == skill.rawValue) ? nil : skill.rawValue
                    }
                }

                Rectangle()
                    .fill(Brand.softOutline)
                    .frame(width: 1, height: 20)

                ForEach(DistanceFilter.allCases.filter { $0 != .all }) { dist in
                    FilterPill(label: dist.rawValue, isActive: distanceFilter == dist) {
                        distanceFilter = (distanceFilter == dist) ? .all : dist
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var gameList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(filteredGames) { game in
                        nearbyDiscoveryRow(for: game)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .onChange(of: selectedGameID) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func nearbyDiscoveryRow(for game: Game) -> some View {
        let club          = appState.clubs.first { $0.id == game.clubID }
        let venues        = appState.clubVenuesByClubID[game.clubID] ?? []
        let dist          = LocationService.distanceLabel(
            from: locationManager.userLocation,
            game: game,
            venues: venues,
            clubs: appState.clubs
        )
        let venue         = LocationService.resolvedVenue(for: game, venues: venues)
        let bookingState  = appState.bookings.first { $0.game?.id == game.id }?.booking.state
        let isBooked: Bool = {
            if case .confirmed = bookingState { return true }
            return false
        }()
        let isWaitlisted: Bool = {
            if case .waitlisted = bookingState { return true }
            return false
        }()
        let isSelected = selectedGameID == game.id

        VStack(alignment: .leading, spacing: 4) {
            UnifiedGameCard(
                game: game,
                clubName: club?.name ?? "",
                isBooked: isBooked,
                isWaitlisted: isWaitlisted,
                resolvedVenue: venue
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: "80FF00").opacity(isSelected ? 0.55 : 0), lineWidth: 1.5)
            )
            .shadow(
                color: isSelected ? Color(hex: "80FF00").opacity(0.12) : .clear,
                radius: isSelected ? 10 : 0,
                y: 0
            )
            .contentShape(Rectangle())
            .onTapGesture { selectGame(game, openDetail: true) }
            .animation(.easeInOut(duration: 0.15), value: isSelected)

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
        .id(game.id)
    }

    // MARK: - Empty state

    private var emptyGamesState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sportscourt")
                .font(.system(size: 32))
                .foregroundStyle(Brand.tertiaryText)

            VStack(spacing: 5) {
                Text("No games nearby")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.ink)
                Text("Try a wider distance or different day filter.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button { dismiss() } label: {
                Text("Explore Clubs")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.sportPop)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Brand.sportStatement, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Camera setup

    private func setInitialCamera() {
        if let userLoc = locationManager.userLocation {
            cameraPosition = .region(MKCoordinateRegion(
                center: userLoc.coordinate,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            ))
        } else if !gamesWithCoords.isEmpty {
            let coords  = gamesWithCoords.map(\.coordinate)
            let avgLat  = coords.map(\.latitude).reduce(0, +)  / Double(coords.count)
            let avgLng  = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng),
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            ))
        }
    }

    // MARK: - Selection helper

    private func selectGame(_ game: Game, openDetail: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            selectedGameID = (selectedGameID == game.id) ? nil : game.id
        }
        if panelDetent == .minimized {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                panelDetent = .collapsed
            }
        }
        if openDetail {
            selectedGameForDetail = game
        }
    }
}

// MARK: - Game Map Pin

/// Availability-driven map annotation for a game.
/// Color encodes spots remaining; a time label is shown inside the pill.
///
/// Design:
/// - Pill-shaped label showing start time only (no floating title text)
/// - Green (6+ spots) / Orange (2–5 or <3hrs) / Red (1) / Grey (full)
/// - Pulsing ring when game starts within 3 hours
/// - 1.2x scale + deeper shadow when selected
/// - Triangle pointer at bottom
struct GameMapPin: View {
    let game: Game
    let isSelected: Bool

    @State private var pulsing = false

    private var isUrgent: Bool {
        let hours = game.dateTime.timeIntervalSinceNow / 3_600
        return hours > 0 && hours < 3
    }

    private var pinColor: Color {
        if game.isFull { return Color(.systemGray4) }
        if isUrgent    { return Color(hex: "FF9500") }
        guard let spots = game.spotsLeft else { return Color(hex: "34C759") }
        if spots >= 6  { return Color(hex: "34C759") }
        if spots >= 2  { return Color(hex: "FF9500") }
        return Color(hex: "FF3B30")
    }

    private var labelColor: Color {
        game.isFull ? Color(.systemGray) : .white
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Pulse ring — shown behind the pill for urgent games.
            // onAppear/onDisappear are on the outer ZStack (not the Capsule) so the
            // repeatForever animation is explicitly stopped before MapKit tears down the
            // annotation's Metal layer. Without onDisappear the GPU command buffer holds
            // a reference to the drawable after it is deallocated → Metal assertion crash.
            if isUrgent {
                Capsule()
                    .fill(pinColor.opacity(0.35))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
                    .scaleEffect(pulsing ? 1.55 : 1.0)
                    .opacity(pulsing ? 0 : 1)
                    .animation(
                        pulsing
                            ? .easeInOut(duration: 1.3).repeatForever(autoreverses: false)
                            : .linear(duration: 0),   // instant reset so GPU releases the drawable
                        value: pulsing
                    )
            }

            VStack(spacing: 0) {
                // Pill label — time only
                Text(game.dateTime, format: .dateTime.hour().minute())
                    .font(.system(size: isSelected ? 11 : 9, weight: .bold, design: .rounded))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(pinColor, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))

                // Pointer
                GamePinTriangle()
                    .fill(pinColor)
                    .frame(width: 8, height: 5)
            }
        }
        .onAppear   { if isUrgent { pulsing = true  } }
        .onDisappear{               pulsing = false   }
        .opacity(isSelected ? 1.0 : 0.85)
        .scaleEffect(isSelected ? 1.2 : 1.0)
        .shadow(
            color: .black.opacity(isSelected ? 0.35 : 0.18),
            radius: isSelected ? 6 : 3,
            y: 1.5
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

private struct GamePinTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Pickleball Map Pin

/// Classic pickleball-ball map pin used for the HomeView map preview.
/// Shared across HomeView non-interactive map preview and legacy club pins.
///
/// Design:
/// - 20 pt default / 26 pt selected (spring-animated)
/// - Flagship lime (#80FF00) fill
/// - Six 2.5 pt perforation holes arranged in a hexagonal ring
/// - 1.5 pt black border for contrast on any map background
/// - Subtle drop shadow; deeper shadow when selected
struct PickleballMapPin: View {
    let isSelected: Bool

    var body: some View {
        let size: CGFloat     = isSelected ? 26 : 20
        let holeSize: CGFloat = 2.5
        let holeRadius        = size * 0.28

        ZStack {
            Circle()
                .fill(Color(hex: "80FF00"))

            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * (.pi / 3)
                Circle()
                    .fill(Color.black.opacity(0.2))
                    .frame(width: holeSize, height: holeSize)
                    .offset(
                        x: CGFloat(cos(angle)) * holeRadius,
                        y: CGFloat(sin(angle)) * holeRadius
                    )
            }

            Circle()
                .strokeBorder(Color.black.opacity(0.75), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .shadow(
            color: .black.opacity(isSelected ? 0.35 : 0.22),
            radius: isSelected ? 6 : 3,
            y: 1.5
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Filter Pill

private struct FilterPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.1)
                .foregroundStyle(isActive ? Brand.sportPop : Brand.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isActive ? Brand.sportStatement : Brand.cardBackground,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        isActive ? Brand.sportStatement : Brand.softOutline,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}
