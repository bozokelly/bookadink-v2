import SwiftUI
import MapKit
import UIKit

// MARK: - NearbyDiscoveryView

/// Full-screen nearby discovery: an interactive map with club pins + a fixed
/// bottom panel listing nearby clubs sorted by proximity.
///
/// Presented as a sheet from Home. The map is the visual layer; the list
/// is the primary booking/navigation mechanism.
struct NearbyDiscoveryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedClub: Club? = nil
    @State private var panelDetent: PanelDetent = .collapsed

    private enum PanelDetent { case minimized, collapsed, expanded }

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

    /// Clubs that have a resolvable coordinate — either club-level or primary venue.
    /// Clubs with neither are excluded from map pins and the nearby list.
    private var clubsWithCoords: [Club] {
        appState.clubs.filter {
            LocationService.location(for: $0, venues: appState.clubVenuesByClubID[$0.id] ?? []) != nil
        }
    }

    /// Same set sorted nearest-first using venue fallback (no-op when user location is unavailable).
    private var nearbyClubs: [Club] {
        LocationService.sortByProximity(
            clubsWithCoords,
            from: locationManager.userLocation,
            venuesByClubID: appState.clubVenuesByClubID
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mapLayer
                bottomPanel
            }
            .ignoresSafeArea(edges: .top)
            .navigationTitle("Explore Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Brand.ink)
                }
            }
            .onAppear {
                setInitialCamera()
            }
            .task {
                // Fetch venues for any club that lacks club-level coordinates and
                // doesn't yet have cached venue data. This enables the primary-venue
                // coordinate fallback so those clubs appear in the list and on the map.
                let clubsNeedingVenues = appState.clubs.filter { club in
                    club.latitude == nil || club.longitude == nil
                }.filter { club in
                    appState.clubVenuesByClubID[club.id] == nil
                }
                await withTaskGroup(of: Void.self) { group in
                    for club in clubsNeedingVenues {
                        group.addTask { await appState.refreshVenues(for: club) }
                    }
                }
            }
        }
    }

    // MARK: - Map layer

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(clubsWithCoords) { club in
                if let coord = LocationService.location(
                    for: club,
                    venues: appState.clubVenuesByClubID[club.id] ?? []
                )?.coordinate {
                    Annotation(club.name, coordinate: coord, anchor: .center) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedClub = (selectedClub?.id == club.id) ? nil : club
                            }
                        } label: {
                            PickleballMapPin(isSelected: selectedClub?.id == club.id)
                        }
                    }
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drag handle
            HStack {
                Spacer()
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(width: 36, height: 4)
                Spacer()
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            let dy = value.translation.height
                            switch panelDetent {
                            case .collapsed:
                                if dy < -40 { panelDetent = .expanded }
                                else if dy > 40 { panelDetent = .minimized }
                            case .expanded:
                                if dy > 40 { panelDetent = .collapsed }
                            case .minimized:
                                if dy < -40 { panelDetent = .collapsed }
                            }
                        }
                    }
            )

            // Selected club callout — animates in when a pin is tapped
            if let club = selectedClub {
                selectedClubCallout(club)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Section header
            HStack(spacing: 8) {
                Text("Nearby Clubs")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                if !nearbyClubs.isEmpty {
                    Text("\(nearbyClubs.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Brand.secondarySurface, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Club list
            if nearbyClubs.isEmpty {
                emptyClubsState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(nearbyClubs) { club in
                            NavigationLink {
                                ClubDetailView(club: club)
                            } label: {
                                NearbyClubRow(
                                    club: club,
                                    distance: LocationService.distanceLabel(
                                        from: locationManager.userLocation,
                                        to: club,
                                        venues: appState.clubVenuesByClubID[club.id] ?? []
                                    ),
                                    isSelected: selectedClub?.id == club.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            Color(.systemBackground),
            in: UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 20,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.1), radius: 16, y: -4)
        .frame(height: panelHeight)
    }

    // MARK: - Selected club callout

    private func selectedClubCallout(_ club: Club) -> some View {
        NavigationLink {
            ClubDetailView(club: club)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(club.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                    if let dist = LocationService.distanceLabel(
                        from: locationManager.userLocation,
                        to: club,
                        venues: appState.clubVenuesByClubID[club.id] ?? []
                    ) {
                        HStack(spacing: 3) {
                            Image(systemName: "location.fill")
                                .font(.caption2)
                                .foregroundStyle(Brand.secondaryText.opacity(0.7))
                            Text(dist)
                                .font(.caption)
                                .foregroundStyle(Brand.secondaryText)
                        }
                    } else if let area = club.addressLine2 {
                        Text(area)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("View Club")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.emeraldAction, in: Capsule())
            }
            .padding(12)
            .background(
                Brand.secondarySurface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyClubsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map")
                .font(.system(size: 28))
                .foregroundStyle(Brand.secondaryText)
            Text("No clubs found")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
            Text("Clubs will appear here once location data is available.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
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
        } else if !clubsWithCoords.isEmpty {
            let coords = clubsWithCoords.compactMap { c -> CLLocationCoordinate2D? in
                LocationService.location(for: c, venues: appState.clubVenuesByClubID[c.id] ?? [])?.coordinate
            }
            let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
            let avgLng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng),
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            ))
        }
        // If neither is available, .automatic keeps the map at a world view
        // until data arrives — acceptable for V1
    }
}

// MARK: - Pickleball Map Pin

/// Custom map annotation styled as a pickleball.
/// Shared across NearbyDiscoveryView and the HomeView map preview.
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
            // Ball fill
            Circle()
                .fill(Color(hex: "80FF00"))

            // Perforations — 6 holes at 60° intervals
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

            // Border
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

// MARK: - Club list row

/// Compact club row for the NearbyDiscoveryView bottom panel.
private struct NearbyClubRow: View {
    let club: Club
    let distance: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Club initial badge
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.secondarySurface)
                Text(String(club.name.prefix(1)).uppercased())
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.secondaryText)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(club.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                subtitleText
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
        }
        .padding(12)
        .background(
            isSelected ? Brand.secondarySurface : Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Brand.pineTeal.opacity(0.35) : Brand.softOutline,
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var subtitleText: some View {
        let parts = [distance, club.addressLine2].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
        }
    }
}
