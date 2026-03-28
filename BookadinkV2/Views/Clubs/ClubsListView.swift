import SwiftUI

struct ClubsListView: View {
    @EnvironmentObject private var appState: AppState
    let clubs: [Club]

    @State private var searchText = ""
    @State private var selectedFilter: ClubsFilter = .myClubs
    @State private var isShowingCreateClubSheet = false
    @State private var createdClubNavigationTarget: Club? = nil
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
                    // Title row with inline action button
                    HStack(alignment: .center) {
                        Text("Clubs")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.primaryText)
                        Spacer()
                        if appState.authState == .signedIn {
                            Button {
                                isShowingCreateClubSheet = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(Brand.primaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Create new club")
                        }
                    }
                    .padding(.horizontal, 4)

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

                    searchField
                    segmentBar

                    if filteredClubs.isEmpty {
                        emptyResultsCard
                    } else {
                        ForEach(filteredClubs) { club in
                            NavigationLink {
                                ClubDetailView(club: club)
                            } label: {
                                ClubRowCard(
                                    club: club,
                                    membershipState: appState.membershipState(for: club),
                                    isAdmin: appState.isClubAdmin(for: club),
                                    isOwner: appState.isClubOwner(for: club)
                                )
                            }
                            .buttonStyle(.plain)
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
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingCreateClubSheet) {
            StartClubSheet { createdClub in
                createdClubNavigationTarget = createdClub
            }
        }
        .navigationDestination(item: $createdClubNavigationTarget) { createdClub in
            ClubDetailView(club: createdClub)
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
                ClubFormBody(
                    draft: $draft,
                    club: nil,
                    pendingVenue: pendingVenue,
                    onAddPendingVenue: {
                        editingVenueDraft = ClubVenueDraft()
                        editingVenueDraft.isPrimary = true
                        showVenueForm = true
                    },
                    onEditPendingVenue: {
                        editingVenueDraft = pendingVenue ?? ClubVenueDraft()
                        editingVenueDraft.isPrimary = true
                        showVenueForm = true
                    },
                    onRemovePendingVenue: {
                        pendingVenue = nil
                    }
                )

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
    /// Email and URL validated if provided.
    private var isCreateDisabled: Bool {
        let nameOK = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let emailOK = draft.contactEmail.isEmpty || draft.contactEmail.contains("@")
        let urlOK = draft.website.isEmpty || URL(string: draft.website) != nil
        let venueOK = pendingVenue != nil
        return appState.isCreatingClub || !nameOK || !emailOK || !urlOK || !venueOK
    }
}

// MARK: - Pending Venue Form Sheet

/// Captures the first venue draft during club creation.
/// No DB operations — commits to the parent's state via `onSave`.
private struct PendingVenueFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: ClubVenueDraft
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
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
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ClubImageBadge(club: club)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(club.name)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.brandPrimary)
                    .lineSpacing(1)
                    .lineLimit(2)

                Text(club.addressLine1)
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(2)

                HStack(alignment: .bottom) {
                    Text("\(club.memberCount) members")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)

                    Spacer(minLength: 8)

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

    var body: some View {
        ZStack {
            if let preset = ClubProfileImagePresets.preset(for: club.imageURL) {
                ProfileAvatarArtwork(preset: preset, variant: .club)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.secondarySurface)
            }

            if let url = club.imageURL,
               ClubProfileImagePresets.presetID(from: url) == nil,
               isAllowedRemoteImageURL(url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    // FIX (UX): Show a muted shimmer while loading,
                    // and only show the fallback icon on actual failure.
                    case .empty:
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Brand.secondarySurface)
                            .overlay(
                                ProgressView()
                                    .tint(Brand.secondaryText)
                            )
                    case .failure:
                        fallbackIcon
                    @unknown default:
                        fallbackIcon
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                if ClubProfileImagePresets.presetID(from: club.imageURL) == nil {
                    fallbackIcon
                }
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: club.imageSystemName)
            .font(.system(size: 26))
            .foregroundStyle(.white)
    }

    // FIX (Security): Require HTTPS and restrict to known CDN hosts.
    // Add or update entries in `allowedHosts` as your infrastructure changes.
    private func isAllowedRemoteImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host else { return false }
        let allowedHosts = [
            "cdn.bookadink.com",
            "storage.googleapis.com",
            "firebasestorage.googleapis.com"
        ]
        return allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ClubsListView(clubs: MockData.clubs)
            .environmentObject(AppState())
    }
}
