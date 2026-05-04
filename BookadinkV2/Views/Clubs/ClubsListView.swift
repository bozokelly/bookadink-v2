import SwiftUI

struct ClubsListView: View {
    @EnvironmentObject private var appState: AppState
    let clubs: [Club]

    @State private var searchText = ""
    @State private var selectedFilter: ClubsFilter = .myClubs
    @State private var isShowingCreateClubSheet = false
    @State private var createdClubNavigationTarget: Club? = nil
    @State private var favouriteSelectedClub: Club? = nil
    @AppStorage("clubs_tip_dismissed") private var tipDismissed = false

    // FIX (Performance): Single-pass filter combining membership + search,
    // and a single reduce for header counts — avoids redundant array traversals.
    private var filteredClubs: [Club] {
        clubs.filter { matchesMembershipFilter($0) && matchesSearch($0) }
    }

    // FIX (Performance): Compute admin/member counts in one pass instead of two.
    private var clubStats: (admin: Int, member: Int) {
        clubs.reduce(into: (admin: 0, member: 0)) { counts, club in
            if appState.isClubAdmin(for: club) {
                counts.admin += 1
            } else {
                switch appState.membershipState(for: club) {
                case .approved, .unknown:
                    counts.member += 1
                default:
                    break
                }
            }
        }
    }

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !tipDismissed {
                        iPadTipBanner
                    }

                    if let error = appState.clubsLoadErrorMessage, !appState.isUsingLiveClubData {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                            Text("Using preview data. \(AppCopy.friendlyError(error))")
                        }
                        .font(.footnote)
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.horizontal, 6)
                    }

                    // ── Favourites section ──────────────────────────────
                    FavouriteClubsSection(
                        clubs: clubs,
                        pinnedIDs: appState.pinnedClubIDs,
                        selectedClub: $favouriteSelectedClub,
                        onTogglePin: { club in appState.togglePinClub(club) },
                        nextGame: { club in nextUpcomingGame(for: club) }
                    )

                    // ── Divider ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All clubs")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(Brand.primaryText)
                        Text("\(clubStats.admin + clubStats.member) joined · \(clubs.filter { appState.membershipState(for: $0) == .none && !appState.isClubAdmin(for: $0) }.count) nearby")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .padding(.top, 4)

                    searchField
                    segmentBar

                    if filteredClubs.isEmpty {
                        emptyResultsCard
                    } else {
                        ForEach(filteredClubs) { club in
                            Button {
                                appState.navigate(to: .club(club.id))
                            } label: {
                                ClubRowCard(
                                    club: club,
                                    membershipState: appState.membershipState(for: club),
                                    isAdmin: appState.isClubAdmin(for: club),
                                    isOwner: appState.isClubOwner(for: club),
                                    primaryVenue: appState.clubVenuesByClubID[club.id]?.first(where: { $0.isPrimary }),
                                    nextGame: nextUpcomingGame(for: club)
                                )
                            }
                            .buttonStyle(.plain)
                            .task(id: club.id) {
                                guard appState.clubVenuesByClubID[club.id] == nil else { return }
                                await appState.refreshVenues(for: club)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await appState.refreshClubs()
            }
        }
        .navigationTitle("Clubs")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if appState.authState == .signedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingCreateClubSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Create new club")
                }
            }
        }
        .sheet(isPresented: $isShowingCreateClubSheet) {
            StartClubSheet { createdClub in
                createdClubNavigationTarget = createdClub
            }
        }
        .navigationDestination(item: $createdClubNavigationTarget) { createdClub in
            ClubDetailView(club: createdClub)
        }
        // Lifted out of FavouriteClubsSection so the modifier sits outside the
        // parent LazyVStack — SwiftUI ignores navigationDestination(item:) attached
        // inside a lazy container.
        .navigationDestination(item: $favouriteSelectedClub) { club in
            ClubDetailView(club: club)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var iPadTipBanner: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Brand.secondaryText)
                Text("Tap any club to view details, book games, or manage members.")
                    .font(.footnote)
                    .foregroundStyle(Brand.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        tipDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss tip")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassCard(cornerRadius: 16, tint: Brand.cardBackground)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.secondaryText)
            TextField("Search clubs or location", text: $searchText)
                .textInputAutocapitalization(.words)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.plain)
                // FIX (Accessibility): Label clear button for VoiceOver.
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 20, tint: Brand.cardBackground)
    }

    private var segmentBar: some View {
        HStack(spacing: 6) {
            ForEach(ClubsFilter.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.title)
                        .frame(maxWidth: .infinity)
                        .segmentPillStyle(active: selectedFilter == filter)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyResultsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Brand.secondaryText)
                Text("No clubs match your filters")
                    .font(.headline)
                    .foregroundStyle(Brand.primaryText)
            }

            Text("Try clearing the search or switching to Explore.")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)

            HStack(spacing: 10) {
                Button {
                    searchText = ""
                } label: {
                    Text("Clear Search")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .actionBorder(cornerRadius: 12, color: Brand.softOutline)

                Button {
                    selectedFilter = .explore
                } label: {
                    Text("Show All Clubs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 20, tint: Brand.cardBackground)
    }

    // MARK: - Filter Logic

    private func matchesSearch(_ club: Club) -> Bool {
        guard !searchText.isEmpty else { return true }
        return club.name.localizedCaseInsensitiveContains(searchText) ||
            (club.venueName?.localizedCaseInsensitiveContains(searchText) == true) ||
            (club.suburb?.localizedCaseInsensitiveContains(searchText) == true) ||
            club.city.localizedCaseInsensitiveContains(searchText) ||
            club.region.localizedCaseInsensitiveContains(searchText) ||
            club.address.localizedCaseInsensitiveContains(searchText)
    }

    /// First upcoming, published, non-past game for the given club.
    /// Uses allUpcomingGames (already filtered for publish_at by AppState).
    private func nextUpcomingGame(for club: Club) -> Game? {
        let now = Date()
        return appState.allUpcomingGames
            .filter { $0.clubID == club.id && $0.dateTime >= now && $0.status == "upcoming" }
            .min(by: { $0.dateTime < $1.dateTime })
    }

    private func matchesMembershipFilter(_ club: Club) -> Bool {
        switch selectedFilter {
        case .explore:
            return true
        case .pending:
            return appState.membershipState(for: club) == .pending
        case .myClubs:
            if appState.isClubAdmin(for: club) { return true }
            switch appState.membershipState(for: club) {
            case .approved, .unknown:
                return true
            case .none, .pending, .rejected:
                return false
            }
        }
    }
} // closes ClubsListView

// MARK: - Start Club Sheet

private struct StartClubSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Club) -> Void
    @State private var draft = ClubOwnerEditDraft()
    @State private var showCreateSuccess = false
    @State private var pendingDismissTask: Task<Void, Never>?

    /// Local draft for the first venue — not saved to DB until club is created.
    @State private var pendingVenue: ClubVenueDraft? = nil
    /// Working copy while the venue form is open; committed on save.
    @State private var editingVenueDraft = ClubVenueDraft()
    @State private var showVenueForm = false

    var body: some View {
        NavigationStack {
            Form {
                if showCreateSuccess {
                    Section {
                        Label("Club created.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.pineTeal)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(Brand.errorRed)
                    }
                }

                // MARK: Required
                Section {
                    NavigationLink {
                        ClubInfoSettingsView(draft: $draft)
                    } label: {
                        HStack(spacing: 0) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Club Info")
                                    if draft.name.isEmpty {
                                        Text("Name required")
                                            .font(.caption)
                                            .foregroundStyle(Brand.errorRed)
                                    } else {
                                        Text(draft.name)
                                            .font(.caption)
                                            .foregroundStyle(Brand.mutedText)
                                            .lineLimit(1)
                                    }
                                }
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                            Spacer(minLength: 8)
                            if !draft.name.isEmpty {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Brand.pineTeal)
                            }
                        }
                    }

                    Button {
                        editingVenueDraft = pendingVenue ?? ClubVenueDraft()
                        editingVenueDraft.isPrimary = true
                        showVenueForm = true
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Venue")
                                    if let venue = pendingVenue, !venue.venueName.isEmpty {
                                        Text(venue.venueName)
                                            .font(.caption)
                                            .foregroundStyle(Brand.mutedText)
                                            .lineLimit(1)
                                    } else {
                                        Text("Required · Not added yet")
                                            .font(.caption)
                                            .foregroundStyle(Brand.errorRed)
                                    }
                                }
                            } icon: {
                                Image(systemName: "mappin.and.ellipse")
                            }
                            Spacer(minLength: 8)
                            if pendingVenue != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Brand.pineTeal)
                                    .padding(.trailing, 4)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.mutedText.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.ink)
                } footer: {
                    Text("Club name and a venue are required to create your club.")
                }

                // MARK: Optional
                Section {
                    NavigationLink {
                        ClubGamesRulesSettingsView(draft: $draft)
                    } label: {
                        Label("Games & Rules", systemImage: "sportscourt")
                    }
                } footer: {
                    Text("Payments, appearance, and billing can be configured in Club Settings after creating.")
                }
            }
            .navigationTitle("Start a Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            showCreateSuccess = false
                            guard let created = await appState.createClub(draft: draft) else { return }

                            // Create the first venue, ensuring it is marked primary
                            if var venueDraft = pendingVenue {
                                venueDraft.isPrimary = true
                                _ = await appState.createVenue(for: created, draft: venueDraft)
                            }

                            showCreateSuccess = true
                            onCreated(created)
                            pendingDismissTask?.cancel()
                            pendingDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 800_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run { dismiss() }
                            }
                        }
                    } label: {
                        if appState.isCreatingClub { ProgressView() }
                        else { Text("Create").fontWeight(.semibold) }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreateDisabled)
                }
            }
            .onAppear {
                appState.ownerToolsErrorMessage = nil
                appState.ownerToolsInfoMessage = nil
            }
            .onDisappear { pendingDismissTask?.cancel() }
            .sheet(isPresented: $showVenueForm) {
                PendingVenueFormSheet(draft: $editingVenueDraft) {
                    pendingVenue = editingVenueDraft
                }
            }
        }
    }

    /// Create is blocked until: club name present + primary venue draft added.
    private var isCreateDisabled: Bool {
        let nameOK = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let venueOK = pendingVenue != nil
        return appState.isCreatingClub || !nameOK || !venueOK
    }
}

// MARK: - Pending Venue Form Sheet

/// Captures the first venue draft during club creation using the same
/// search-first flow as OwnerVenueFormSheet. No DB operations — commits
/// to the parent's state via `onSave`.
private struct PendingVenueFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = ApplePlaceSearchService()
    @Binding var draft: ClubVenueDraft
    let onSave: () -> Void

    @State private var entryMode: PendingVenueEntryMode = .search
    @State private var searchQuery = ""

    private enum PendingVenueEntryMode { case search, resolved, manual }

    var body: some View {
        NavigationStack {
            Form {
                switch entryMode {
                case .search:  searchContent
                case .resolved: resolvedContent
                case .manual:  manualContent
                }

                Section {
                    Text("This will be the club's primary venue — used for maps, directions, and distance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Primary Venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .buttonStyle(.plain)
                    .disabled(draft.venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: search.state) { _, newState in
                if case .resolved(let place) = newState {
                    applyPlace(place)
                    entryMode = .resolved
                    search.clear()
                }
            }
        }
    }

    // MARK: - Search content

    @ViewBuilder
    private var searchContent: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyinglass").foregroundStyle(.secondary)
                TextField("Search venue or address", text: $searchQuery)
                    .autocorrectionDisabled()
                    .onChange(of: searchQuery) { _, new in search.search(query: new) }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        switch search.state {
        case .idle:
            Section { manualFallbackButton }

        case .searching, .resolving:
            Section {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text(search.state == .resolving ? "Loading location…" : "Searching…")
                        .foregroundStyle(.secondary)
                }
            }

        case .results(let suggestions):
            if suggestions.isEmpty {
                Section {
                    Text("No results found.").foregroundStyle(.secondary)
                    manualFallbackButton
                }
            } else {
                Section("Results") {
                    ForEach(suggestions) { suggestion in
                        Button {
                            Task { await search.resolve(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section { manualFallbackButton }
            }

        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button("Try again") { searchQuery = ""; search.clear() }
                manualFallbackButton
            }

        case .resolved:
            EmptyView()
        }
    }

    private var manualFallbackButton: some View {
        Button("Enter address manually") {
            entryMode = .manual
            search.clear()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Resolved content

    @ViewBuilder
    private var resolvedContent: some View {
        Section("Location") {
            VStack(alignment: .leading, spacing: 4) {
                let street = draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let locality = [draft.suburb, draft.state, draft.postcode]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !street.isEmpty { Text(street).font(.subheadline) }
                if !locality.isEmpty {
                    Text(locality).font(.subheadline).foregroundStyle(.secondary)
                }
                if street.isEmpty && locality.isEmpty {
                    Text(draft.venueName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Button("Change location") {
                entryMode = .search
                searchQuery = ""
                search.clear()
                draft.resolvedLatitude = nil
                draft.resolvedLongitude = nil
            }
            .foregroundColor(.accentColor)
        }

        Section("Venue Name") {
            TextField("e.g. Kwinana Recreation Centre", text: $draft.venueName)
        }
    }

    // MARK: - Manual content

    @ViewBuilder
    private var manualContent: some View {
        Section {
            Button {
                entryMode = .search
                search.clear()
                searchQuery = ""
            } label: {
                Label("Search instead", systemImage: "magnifyinglass")
            }
            .foregroundColor(.accentColor)
        } footer: {
            Text("Search finds precise coordinates automatically. Manual entry geocodes the address at save time.")
        }

        Section("Venue Details") {
            TextField("Venue name", text: $draft.venueName)
            TextField("Street address", text: $draft.streetAddress)
            TextField("Suburb", text: $draft.suburb)
            HStack(spacing: 12) {
                TextField("State", text: $draft.state)
                TextField("Postcode", text: $draft.postcode)
                    .keyboardType(.numberPad)
            }
            Picker("Country", selection: $draft.country) {
                Text("Australia").tag("Australia")
                Text("New Zealand").tag("New Zealand")
                Text("United States").tag("United States")
                Text("United Kingdom").tag("United Kingdom")
                Text("Canada").tag("Canada")
                Text("Other").tag("Other")
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Helpers

    private func applyPlace(_ place: ResolvedPlace) {
        draft.venueName = place.name
        draft.streetAddress = place.thoroughfare ?? ""
        draft.suburb = place.locality ?? ""
        draft.state = place.administrativeArea ?? ""
        draft.postcode = place.postalCode ?? ""
        draft.country = mappedCountry(place.country)
        draft.resolvedLatitude = place.coordinate.latitude
        draft.resolvedLongitude = place.coordinate.longitude
    }

    private func mappedCountry(_ country: String?) -> String {
        let known = ["Australia", "New Zealand", "United States", "United Kingdom", "Canada"]
        guard let c = country, known.contains(c) else { return "Other" }
        return c
    }
}

// MARK: - Filter Enum

// FIX (Code Quality): Kept at file-private scope (appropriate size),
// but named ClubsFilter to make its ownership clear.
private enum ClubsFilter: String, CaseIterable, Identifiable {
    case explore
    case pending
    case myClubs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .pending: return "Pending"
        case .myClubs: return "My Clubs"
        }
    }
}

// MARK: - Club Row Card

struct ClubRowCard: View {
    let club: Club
    let membershipState: ClubMembershipState
    let isAdmin: Bool
    var isOwner: Bool = false
    /// Primary ClubVenue loaded from club_venues (Apple Maps structured data).
    var primaryVenue: ClubVenue? = nil
    /// Next upcoming game for this club.
    var nextGame: Game? = nil

    // Static formatters — created once, not per-render.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ClubImageBadge(club: club)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 5) {
                // Line 1: Club name
                Text(club.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.brandPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Line 2: location icon + venue name, suburb
                locationRow

                // Line 3: calendar icon + next game, or plain "No upcoming games"
                gameInfoRow

                // Line 4: Member count + role badge
                HStack(alignment: .center, spacing: 8) {
                    Text("\(club.memberCount) members")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isAdmin {
                        badgeView(title: isOwner ? "Owner" : "Admin", fill: Brand.primaryText, text: .white)
                            .accessibilityLabel("Membership status: \(isOwner ? "Owner" : "Admin")")
                    } else if membershipState != .none {
                        badgeView(
                            title: badgeTitle(for: membershipState),
                            fill: membershipState == .approved ? Brand.primaryText : Brand.secondarySurface,
                            text: membershipState == .approved ? .white : Brand.primaryText
                        )
                        .accessibilityLabel("Membership status: \(badgeTitle(for: membershipState))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glassCard(cornerRadius: 22, tint: Brand.frostedSurfaceStrong)
    }

    // MARK: - Line helpers

    /// Line 2: mappin icon + venue name, suburb.
    /// Suburb sourced exclusively from ClubVenue.suburb (club_venues.suburb = place.locality).
    /// club.suburb (legacy clubs column) is never used here.
    @ViewBuilder
    private var locationRow: some View {
        let text = resolvedLocationText
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "mappin.and.ellipse")
                .font(.footnote)
                .foregroundStyle(Brand.mutedText)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Builds the location string — no emoji, icon is rendered separately.
    private var resolvedLocationText: String {
        if let venue = primaryVenue {
            let name = venue.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
            let suburb = venue.suburb?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !suburb.isEmpty { return "\(name), \(suburb)" }
            return name.isEmpty ? "—" : name
        }
        // Venue data not yet loaded — use club.venueName (written-through from primary venue).
        // No suburb appended: club.suburb is the legacy column and must not be used.
        if let name = club.venueName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "—"
    }

    /// Line 3: calendar icon + next game summary, or plain text when no game.
    @ViewBuilder
    private var gameInfoRow: some View {
        if let game = nextGame {
            let day = Self.dayFormatter.string(from: game.dateTime)
            let time = Self.timeFormatter.string(from: game.dateTime)
            let priceText = (game.feeAmount ?? 0) > 0 ? "$ \(Int(game.feeAmount!))" : "Free"
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "calendar")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                Text("Next game · \(day) \(time) · \(priceText)")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text("No upcoming games")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
        }
    }

    private func badgeTitle(for state: ClubMembershipState) -> String {
        switch state {
        case .approved: return "Member"
        case .pending:  return "Pending"
        case .rejected: return "Declined"
        case .unknown:  return "Member"
        case .none:     return ""
        }
    }

    private func badgeView(title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
    }
}

// MARK: - Club Image Badge

struct ClubImageBadge: View {
    let club: Club

    private var hasUploadedImage: Bool {
        club.imageURL.map { isAllowedRemoteImageURL($0) } == true
    }

    var body: some View {
        ZStack {
            if let url = club.imageURL, isAllowedRemoteImageURL(url) {
                // Custom uploaded avatar
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.secondarySurface)
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView().tint(Brand.secondaryText)
                    case .failure:
                        initialsIcon
                    @unknown default:
                        initialsIcon
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                // Initials-based avatar — subtle border signals "no uploaded logo"
                initialsIcon
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    hasUploadedImage ? Color.clear : Brand.softOutline,
                    lineWidth: 1
                )
        )
    }

    private var initialsIcon: some View {
        ZStack {
            avatarBackground
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(clubInitials(club.name))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// Up to 5 letters — first letter of each word (up to 5 words).
    private func clubInitials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(5)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    private var avatarBackground: LinearGradient {
        // DB palette key → liveCache → static arrays → Midnight Navy default
        AvatarGradients.resolveGradient(forKey: club.avatarBackgroundColor)
    }

    private func isAllowedRemoteImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host else { return false }
        if let supabaseHost = URL(string: SupabaseConfig.urlString)?.host,
           host == supabaseHost { return true }
        let allowedHosts = [
            "cdn.bookadink.com",
            "storage.googleapis.com",
            "firebasestorage.googleapis.com"
        ]
        return allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }
}

// MARK: - Favourite Clubs Section

private struct FavouriteClubsSection: View {
    let clubs: [Club]
    let pinnedIDs: [UUID]
    @Binding var selectedClub: Club?
    let onTogglePin: (Club) -> Void
    let nextGame: (Club) -> Game?

    @State private var showPickerForSlot: Int? = nil

    private func pinnedClub(at slot: Int) -> Club? {
        guard slot < pinnedIDs.count, let id = pinnedIDs[safe: slot] else { return nil }
        return clubs.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section eyebrow
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Circle().fill(Brand.accentGreen).frame(width: 6, height: 6)
                    Text("Favourites · 2 slots")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer()
                Text("\(min(pinnedIDs.count, 2))/2")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Brand.tertiaryText)
            }

            // Two slot cards
            HStack(spacing: 10) {
                FavouriteSlotCard(
                    slotIndex: 0,
                    club: pinnedClub(at: 0),
                    nextGame: pinnedClub(at: 0).flatMap { nextGame($0) },
                    onAdd: { showPickerForSlot = 0 },
                    onSwap: { showPickerForSlot = 0 },
                    onRemove: { if let c = pinnedClub(at: 0) { onTogglePin(c) } },
                    onTap: { if let c = pinnedClub(at: 0) { selectedClub = c } }
                )
                FavouriteSlotCard(
                    slotIndex: 1,
                    club: pinnedClub(at: 1),
                    nextGame: pinnedClub(at: 1).flatMap { nextGame($0) },
                    onAdd: { showPickerForSlot = 1 },
                    onSwap: { showPickerForSlot = 1 },
                    onRemove: { if let c = pinnedClub(at: 1) { onTogglePin(c) } },
                    onTap: { if let c = pinnedClub(at: 1) { selectedClub = c } }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { showPickerForSlot != nil },
            set: { if !$0 { showPickerForSlot = nil } }
        )) {
            if let slot = showPickerForSlot {
                FavouritePickerSheet(
                    clubs: clubs,
                    pinnedIDs: pinnedIDs,
                    slotIndex: slot,
                    onPick: { club in
                        // Pin: toggle if not already pinned
                        if !pinnedIDs.contains(club.id) {
                            // If this slot is occupied, remove that club first
                            if let existing = pinnedClub(at: slot) {
                                onTogglePin(existing)
                            }
                            onTogglePin(club)
                        }
                        showPickerForSlot = nil
                    },
                    onClose: { showPickerForSlot = nil }
                )
            }
        }
    }
}

// MARK: - Favourite slot card (filled or empty)

private struct FavouriteSlotCard: View {
    let slotIndex: Int
    let club: Club?
    let nextGame: Game?
    let onAdd: () -> Void
    let onSwap: () -> Void
    let onRemove: () -> Void
    var onTap: () -> Void = {}

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f
    }()

    var body: some View {
        if let club {
            filledCard(club)
        } else {
            emptyCard
        }
    }

    private var emptyCard: some View {
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Slot \(slotIndex + 1)")
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Brand.tertiaryText)
                    Spacer()
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(Brand.softOutline, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                        .frame(width: 38, height: 38)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a favourite")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Brand.primaryText)
                    Text("Pin a club for one-tap booking")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Brand.softOutline, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
        }
        .buttonStyle(.plain)
    }

    private func filledCard(_ club: Club) -> some View {
        VStack(spacing: 0) {
            // Tonal gradient hero — tapping opens club detail
            Button(action: onTap) {
                ZStack(alignment: .topLeading) {
                    AvatarGradients.resolveGradient(forKey: club.avatarBackgroundColor)
                        .overlay(
                            // Diagonal stripe overlay
                            Canvas { ctx, size in
                                var x: CGFloat = -size.height
                                while x < size.width + size.height {
                                    var path = Path()
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                                    ctx.stroke(path, with: .color(.white.opacity(0.05)), lineWidth: 1)
                                    x += 14
                                }
                            }
                        )
                        .overlay(
                            // Bottom fade
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.18)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .overlay(
                            // Watermark initials
                            Text(clubInitials(club.name))
                                .font(.system(size: 36, weight: .bold))
                                .tracking(-1.5)
                                .foregroundStyle(.white.opacity(0.22))
                        )

                    // Heart badge (top-left)
                    Circle()
                        .fill(Brand.accentGreen)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: "heart.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.primaryText)
                        )
                        .padding(10)

                    // Slot badge (top-right)
                    Text(String(format: "0%d", slotIndex + 1))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: 92)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Club name + next game — tapping opens club detail
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(club.name)
                            .font(.system(size: 13.5, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(Brand.primaryText)
                            .lineLimit(1)
                        if let game = nextGame {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Brand.tertiaryText)
                                Text("Next \(Self.timeFormatter.string(from: game.dateTime))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Brand.secondaryText)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("No upcoming games")
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.tertiaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                // Action row
                HStack(spacing: 6) {
                    Button(action: onTap) {
                        HStack(spacing: 4) {
                            Text("Book")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button(action: onSwap) {
                        Image(systemName: "arrow.2.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.primaryText)
                            .frame(width: 30, height: 30)
                            .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.primaryText)
                            .frame(width: 30, height: 30)
                            .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.cardBackground)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
            .overlay(
                UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    private func clubInitials(_ name: String) -> String {
        name.split(separator: " ").prefix(3).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

// MARK: - Favourite picker bottom sheet

private struct FavouritePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clubs: [Club]
    let pinnedIDs: [UUID]
    let slotIndex: Int
    let onPick: (Club) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Brand.accentGreen).frame(width: 6, height: 6)
                        Text("Slot \(slotIndex + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    Text("Pick a favourite")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Brand.primaryText)
                    Text("Pinning replaces what's currently in slot \(slotIndex + 1).")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(clubs) { club in
                            let isCurrent = pinnedIDs.safe(slotIndex) == club.id
                            let inOtherSlot = pinnedIDs.contains(club.id) && !isCurrent

                            Button {
                                if !isCurrent { onPick(club) }
                            } label: {
                                HStack(spacing: 12) {
                                    // Club avatar
                                    ZStack {
                                        AvatarGradients.resolveGradient(forKey: club.avatarBackgroundColor)
                                        Text(club.name.split(separator: " ").prefix(2)
                                            .compactMap { $0.first.map { String($0).uppercased() } }
                                            .joined())
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.85))
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(club.name)
                                            .font(.system(size: 14.5, weight: .semibold))
                                            .tracking(-0.3)
                                            .foregroundStyle(Brand.primaryText)
                                            .lineLimit(1)
                                        Text(club.city)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Brand.secondaryText)
                                    }
                                    Spacer()
                                    if isCurrent {
                                        Text("In slot")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .tracking(0.4)
                                            .textCase(.uppercase)
                                            .foregroundStyle(Brand.primaryText)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Brand.accentGreen, in: Capsule())
                                    } else if inOtherSlot {
                                        Text("Will swap")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(Brand.secondaryText)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    isCurrent ? Brand.secondarySurface : Brand.cardBackground,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(isCurrent ? Brand.accentGreen.opacity(0.6) : Brand.softOutline, lineWidth: 1)
                                )
                                .opacity(isCurrent ? 0.7 : 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(isCurrent)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { onClose() }
                        .foregroundStyle(Brand.primaryText)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Array safe subscript helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
    func safe(_ index: Int) -> Element? { self[safe: index] }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ClubsListView(clubs: MockData.clubs)
            .environmentObject(AppState())
    }
}
