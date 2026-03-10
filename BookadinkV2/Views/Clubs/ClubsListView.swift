import SwiftUI

struct ClubsListView: View {
    @EnvironmentObject private var appState: AppState
    let clubs: [Club]

    @State private var searchText = ""
    @State private var selectedFilter: ClubsFilter = .myClubs
    @State private var isShowingCreateClubSheet = false
    @State private var createdClubNavigationTarget: Club? = nil

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
                            .foregroundStyle(.white)
                        Spacer()
                        if appState.authState == .signedIn {
                            Button {
                                isShowingCreateClubSheet = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Create new club")
                        }
                    }
                    .padding(.horizontal, 4)

                    header

                    if let error = appState.clubsLoadErrorMessage, !appState.isUsingLiveClubData {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                            Text("Using preview data. \(AppCopy.friendlyError(error))")
                        }
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.92))
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
                                    isAdmin: appState.isClubAdmin(for: club)
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

    private var header: some View {
        let firstName = appState.profile?.fullName.components(separatedBy: " ").first ?? "Player"
        return Text("Hey, \(firstName) 👋")
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.pineTeal)
            TextField("Search clubs or location", text: $searchText)
                .textInputAutocapitalization(.words)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Brand.mutedText)
                }
                .buttonStyle(.plain)
                // FIX (Accessibility): Label clear button for VoiceOver.
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 20, tint: Color.white.opacity(0.5))
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
                    .foregroundStyle(Brand.pineTeal)
                Text("No clubs match your filters")
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
            }

            Text("Try clearing the search or switching to Explore.")
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)

            HStack(spacing: 10) {
                Button {
                    searchText = ""
                } label: {
                    Text("Clear Search")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .actionBorder(cornerRadius: 12, color: Brand.slateBlue.opacity(0.22))

                Button {
                    selectedFilter = .explore
                } label: {
                    Text("Show All Clubs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Brand.slateBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .actionBorder(cornerRadius: 12, color: Brand.lightCyan.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 20, tint: Color.white.opacity(0.62))
    }

    // MARK: - Filter Logic

    private func matchesSearch(_ club: Club) -> Bool {
        guard !searchText.isEmpty else { return true }
        return club.name.localizedCaseInsensitiveContains(searchText) ||
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

    // FIX (Code Quality): Inline field validation errors for better UX.
    @State private var emailError: String? = nil
    @State private var websiteError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Club") {
                    TextField("Club Name", text: $draft.name)
                    TextField("Location", text: $draft.location, axis: .vertical)
                        .lineLimit(2...3)
                    Toggle("Require Approval To Join", isOn: $draft.membersOnly)
                }

                Section("Club Profile Picture") {
                    Text("Choose one of 9 profile pictures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                        spacing: 8
                    ) {
                        ForEach(ClubProfileImagePresets.all) { preset in
                            Button {
                                draft.profilePicturePresetID = preset.id
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
                                .background(tileBackground(isSelected: draft.profilePicturePresetID == preset.id))
                                .overlay(tileBorder(isSelected: draft.profilePicturePresetID == preset.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Contact") {
                    // FIX (Code Quality): Validate email format inline.
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Contact Email", text: $draft.contactEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .onChange(of: draft.contactEmail) { _, new in
                                emailError = (!new.isEmpty && !new.contains("@"))
                                    ? "Enter a valid email address"
                                    : nil
                            }
                        if let emailError {
                            Text(emailError)
                                .font(.caption)
                                .foregroundStyle(Brand.errorRed)
                        }
                    }

                    TextField("Manager Name", text: $draft.managerName)

                    // FIX (Code Quality): Validate URL format inline.
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Website", text: $draft.website)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: draft.website) { _, new in
                                websiteError = (!new.isEmpty && URL(string: new) == nil)
                                    ? "Enter a valid URL (e.g. https://myclub.com)"
                                    : nil
                            }
                        if let websiteError {
                            Text(websiteError)
                                .font(.caption)
                                .foregroundStyle(Brand.errorRed)
                        }
                    }
                }

                Section("Description") {
                    TextField("About the club", text: $draft.description, axis: .vertical)
                        .lineLimit(4...8)
                }

                if showCreateSuccess {
                    Section {
                        Label("Club created.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.pineTeal)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.errorRed)
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

                            showCreateSuccess = true
                            onCreated(created)

                            pendingDismissTask?.cancel()
                            pendingDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 800_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        if appState.isCreatingClub {
                            ProgressView()
                        } else {
                            Text("Create")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isCreateDisabled)
                }
            }
            .onAppear {
                appState.ownerToolsErrorMessage = nil
                appState.ownerToolsInfoMessage = nil
            }
            .onDisappear {
                pendingDismissTask?.cancel()
            }
        }
    }

    // FIX (Code Quality): Validate email and URL in addition to name.
    private var isCreateDisabled: Bool {
        let nameOK = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let emailOK = draft.contactEmail.isEmpty || draft.contactEmail.contains("@")
        let urlOK = draft.website.isEmpty || URL(string: draft.website) != nil
        return appState.isCreatingClub || !nameOK || !emailOK || !urlOK
    }

    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Brand.emeraldAction.opacity(0.12) : Color.white.opacity(0.88))
    }

    private func tileBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isSelected ? Brand.emeraldAction : Brand.slateBlue.opacity(0.14),
                lineWidth: isSelected ? 2 : 1
            )
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

private struct ClubRowCard: View {
    let club: Club
    let membershipState: ClubMembershipState
    let isAdmin: Bool

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

                Text(club.locationDisplay)
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(2)

                HStack(alignment: .bottom) {
                    Text("\(club.memberCount) members")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)

                    Spacer(minLength: 8)

                    if isAdmin {
                        badgeView(title: "Admin", fill: Brand.pineTeal, text: .white)
                            .accessibilityLabel("Membership status: Admin")
                    } else if membershipState != .none {
                        badgeView(
                            title: badgeTitle(for: membershipState),
                            fill: membershipState == .approved ? Brand.brandPrimary : Color.white.opacity(0.88),
                            text: membershipState == .approved ? .white : Brand.brandPrimary
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

private struct ClubImageBadge: View {
    let club: Club

    var body: some View {
        ZStack {
            if let preset = ClubProfileImagePresets.preset(for: club.imageURL) {
                ProfileAvatarArtwork(preset: preset, variant: .club)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.brandPrimaryDark.opacity(0.95))
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
                            .fill(Brand.brandPrimaryDark.opacity(0.4))
                            .overlay(
                                ProgressView()
                                    .tint(.white.opacity(0.4))
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
