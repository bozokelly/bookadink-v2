import SwiftUI
import os

struct ClubDetailView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BookadinkV2", category: "ClubDetailView")
    private static let maxRenderableDetailTextLength = 1600
    private static let maxDisplayNameLength = 120
    private static let maxAddressLength = 260
    private static let maxDescriptionLength = 2000
    private static let maxContactLength = 320
    private static let maxWebsiteLength = 260
    private static let maxManagerLength = 160
    private static let maxTagLength = 40

    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let club: Club

    @State private var selectedTab: ClubDetailTab = .games
    @State private var searchText = ""

    @State private var showPastGamesHistory = false
    @State private var ownerToolSheet: OwnerToolSheet?
    @State private var editingOwnerGame: Game?
    @State private var ownerDeleteGameCandidate: Game?
    @State private var duplicatingGame: Game?
    @State private var membersSortByDUPRDescending = false

    private var displayedMembers: [ClubMember] {
        guard !searchText.isEmpty else { return club.topMembers }
        return club.topMembers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var allClubGames: [Game] {
        appState.games(for: club)
    }

    private var safeClubName: String {
        cappedDisplayText(club.name, maxLength: Self.maxDisplayNameLength)
    }

    private var safeAddress: String {
        cappedDisplayText(club.address, maxLength: Self.maxAddressLength)
    }

    private var safeDescription: String {
        cappedDisplayText(club.description, maxLength: Self.maxDescriptionLength)
    }

    private var safeContactEmail: String {
        cappedDisplayText(club.contactEmail, maxLength: Self.maxContactLength)
    }

    private var safeWebsite: String? {
        trimmedOptional(cappedDisplayText(club.website ?? "", maxLength: Self.maxWebsiteLength))
    }

    private var safeManagerName: String? {
        trimmedOptional(cappedDisplayText(club.managerName ?? "", maxLength: Self.maxManagerLength))
    }

    private var safeLocationDisplay: String {
        cappedDisplayText(club.locationDisplay, maxLength: Self.maxAddressLength)
    }

    private var filteredClubGames: [Game] {
        let canSeePastGames = isClubAdminUser && showPastGamesHistory
        return allClubGames
            .filter { canSeePastGames || $0.dateTime >= Date() }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var isClubAdminUser: Bool {
        appState.isClubAdmin(for: club)
    }

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                heroCard
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                ScrollView {
                    VStack(spacing: 10) {
                        if let membershipMessage = membershipFeedbackMessage {
                            HStack(spacing: 10) {
                                Image(systemName: membershipMessage.isError ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(membershipMessage.isError ? Brand.errorRed : Brand.emeraldAction)
                                Text(membershipMessage.isError ? AppCopy.friendlyError(membershipMessage.text) : membershipMessage.text)
                                    .font(.footnote.weight(membershipMessage.isError ? .regular : .semibold))
                                    .foregroundStyle(membershipMessage.isError ? Brand.errorRed : Color.white.opacity(0.92))
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(membershipMessage.isError ? Brand.errorRed.opacity(0.12) : Color.white.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(membershipMessage.isError ? Brand.errorRed.opacity(0.24) : Color.white.opacity(0.14), lineWidth: 1)
                            )
                        }

                        tabPicker

                        tabContentSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isClubAdminUser {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        ownerToolSheet = .createGame
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            ownerToolSheet = .joinRequests
                        } label: {
                            Label("Join Requests", systemImage: "person.badge.plus")
                        }
                        Button {
                            ownerToolSheet = .members
                        } label: {
                            Label("Members", systemImage: "person.3.sequence.fill")
                        }
                        Button {
                            ownerToolSheet = .editClub
                        } label: {
                            Label("Club Settings", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            Self.logger.info("open_club_detail club_id=\(club.id.uuidString, privacy: .public) name=\(safeClubName, privacy: .public)")
            Task { await appState.refreshMemberships() }
        }
        .onDisappear {
            Self.logger.info("close_club_detail club_id=\(club.id.uuidString, privacy: .public)")
        }
        .onChange(of: selectedTab) { _, tab in
            Self.logger.info("club_detail_tab_change club_id=\(club.id.uuidString, privacy: .public) tab=\(tab.rawValue, privacy: .public)")
            Task { await loadDataIfNeeded(for: tab) }
        }
        .onChange(of: appState.clubs) { _, newClubs in
            if !newClubs.contains(where: { $0.id == club.id }) {
                dismiss()
            }
        }
        .navigationDestination(for: Game.self) { game in
            GameDetailView(game: game)
        }
        .sheet(item: $ownerToolSheet) { sheet in
            switch sheet {
            case .joinRequests:
                OwnerJoinRequestsSheet(club: club)
                    .environmentObject(appState)
            case .createGame:
                OwnerCreateGameSheet(club: club)
                    .environmentObject(appState)
            case .editClub:
                OwnerEditClubSheet(club: club)
                    .environmentObject(appState)
            case .members:
                OwnerMembersSheet(club: club)
                    .environmentObject(appState)
            }
        }
        .sheet(item: $editingOwnerGame) { game in
            OwnerEditGameSheet(club: club, game: game)
                .environmentObject(appState)
        }
        .sheet(item: $duplicatingGame) { game in
            OwnerCreateGameSheet(club: club, initialDraft: nextWeekDraft(from: game))
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete Game?",
            isPresented: Binding(
                get: { ownerDeleteGameCandidate != nil },
                set: { if !$0 { ownerDeleteGameCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let game = ownerDeleteGameCandidate {
                if game.recurrenceGroupID != nil {
                    Button("Delete This Event", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .singleEvent)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                    Button("Delete This & Future", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .thisAndFuture)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                    Button("Delete Entire Series", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .entireSeries)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                } else {
                    Button("Delete Game", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .singleEvent)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                ownerDeleteGameCandidate = nil
            }
        } message: {
            Text(ownerDeleteGameCandidate?.title ?? "This cannot be undone.")
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 14) {
                // Avatar + info row
                HStack(alignment: .top, spacing: 12) {
                    heroArtwork
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .accessibilityLabel("\(club.name) club avatar")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(safeClubName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if !safeLocationDisplay.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "mappin")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.pineTeal)
                                Text(safeLocationDisplay.normalizedAddress())
                                    .font(.subheadline)
                                    .foregroundStyle(Color.white.opacity(0.75))
                                    .lineLimit(1)
                            }
                            .accessibilityLabel("Location: \(safeLocationDisplay.normalizedAddress())")
                        }

                        HStack(spacing: 5) {
                            Image(systemName: "person.2")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.pineTeal)
                            Text("\(club.memberCount) members")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.6))
                            if isClubAdminUser {
                                Text("·")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.35))
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Brand.pineTeal)
                                Text("Admin")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Brand.pineTeal)
                            }
                        }
                        .accessibilityLabel(isClubAdminUser ? "\(club.memberCount) members · Admin" : "\(club.memberCount) members")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                heroButtonRow
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 20, tint: Color.white.opacity(0.08))
    }

    private var membershipFeedbackMessage: (text: String, isError: Bool)? {
        if let error = appState.membershipErrorMessage, !error.isEmpty {
            return (error, true)
        }
        if let info = appState.membershipInfoMessage, !info.isEmpty {
            return (info, false)
        }
        return nil
    }

    // MARK: - Hero Button Row

    private var isMemberOrAdmin: Bool {
        if isClubAdminUser { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown: return true
        default: return false
        }
    }

    @ViewBuilder
    private var heroButtonRow: some View {
        let state = appState.membershipState(for: club)
        let isBusy = appState.isRequestingMembership(for: club) || appState.isRemovingMembership(for: club)

        if case .pending = state {
            // Pending — single muted non-interactive pill
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text("Request Pending")
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .accessibilityLabel("Request Pending")
        } else if isMemberOrAdmin {
            // Member or admin — Member chip menu + Invite
            HStack(spacing: 8) {
                heroMembershipMenu(state: state, isBusy: isBusy)
                heroInviteButton
            }
        } else {
            // Not a member — full-width Join button
            Button {
                Task { await appState.requestMembership(for: club) }
            } label: {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "person.badge.plus")
                    }
                    Text(isBusy ? "Joining..." : "Join Club")
                        .fontWeight(.bold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("Join Club")
        }
    }

    private func heroMembershipMenu(state: ClubMembershipState, isBusy: Bool) -> some View {
        let isRequesting = appState.isRequestingMembership(for: club)
        let isRemoving = appState.isRemovingMembership(for: club)

        return Menu {
            switch state {
            case .none, .rejected:
                Button(isRequesting ? "Joining..." : state.actionTitle) {
                    Task { await appState.requestMembership(for: club) }
                }
                .disabled(isRequesting)
            case .pending:
                Button(isRemoving ? "Cancelling..." : "Cancel Request", role: .destructive) {
                    Task { await appState.removeMembership(for: club) }
                }
                .disabled(isRemoving)
            case .approved, .unknown:
                Button(isRemoving ? "Leaving..." : "Leave Club", role: .destructive) {
                    Task { await appState.removeMembership(for: club) }
                }
                .disabled(isRemoving)
            }
        } label: {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(isBusy ? "Updating..." : "Member")
                    .fontWeight(.semibold)
                if !isBusy {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Member")
    }

    private var heroInviteButton: some View {
        ShareLink(item: "Join \(club.name) on Book A Dink! bookadink://clubs/\(club.id)") {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                Text("Invite")
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Invite member")
    }


    private func statusTitle(for state: ClubMembershipState, isBusy: Bool) -> String {
        if isBusy {
            if appState.isRequestingMembership(for: club) { return "Updating..." }
            if appState.isRemovingMembership(for: club) { return "Updating..." }
        }
        switch state {
        case .approved: return "Member"
        case .pending: return "Pending"
        case .none: return "Join to Book"
        case .rejected: return "Join to Book"
        case .unknown: return "Member"
        }
    }

    private var tabPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(ClubDetailTab.allCases) { tab in
                    clubTabButton(tab)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    clubTabButton(.games).frame(maxWidth: .infinity)
                    clubTabButton(.clubNews).frame(maxWidth: .infinity)
                }
                HStack(spacing: 6) {
                    clubTabButton(.members).frame(maxWidth: .infinity)
                    clubTabButton(.info).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clubTabButton(_ tab: ClubDetailTab) -> some View {
        let isActive = selectedTab == tab
        let foreground: Color = isActive ? .white : Color.white.opacity(0.72)
        let fill = isActive ? Brand.brandPrimaryLight.opacity(0.9) : Color.white.opacity(0.12)
        let stroke = isActive ? Color.white.opacity(0.22) : Color.white.opacity(0.14)

        return Button {
            selectedTab = tab
        } label: {
            Text(tab.pillTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var membershipManagementPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            membershipManagementActionButton

            if let info = appState.membershipInfoMessage, !info.isEmpty {
                Text(info)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }

            if let error = appState.membershipErrorMessage, !error.isEmpty {
                Text(AppCopy.friendlyError(error))
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 18, tint: Color.white.opacity(0.08))
    }

    private var showsMembershipPanel: Bool {
        hasMembershipManagementAction ||
        ((appState.membershipInfoMessage?.isEmpty == false) || (appState.membershipErrorMessage?.isEmpty == false))
    }

    private var hasMembershipManagementAction: Bool {
        let state = appState.membershipState(for: club)
        switch state {
        case .pending, .approved, .unknown:
            return true
        case .none, .rejected:
            return false
        }
    }

    @ViewBuilder
    private var membershipManagementActionButton: some View {
        if let membershipManagementButton {
            membershipManagementButton
        }
    }

    private var membershipManagementButton: AnyView? {
        let state = appState.membershipState(for: club)
        let isBusy = appState.isRequestingMembership(for: club) || appState.isRemovingMembership(for: club)

        switch state {
        case .pending:
            return AnyView(
                Button {
                    Task { await appState.removeMembership(for: club) }
                } label: {
                    HStack(spacing: 8) {
                        if appState.isRemovingMembership(for: club) {
                            ProgressView().tint(Brand.pineTeal)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                        Text(appState.isRemovingMembership(for: club) ? "Cancelling..." : "Cancel Membership Request")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(Brand.pineTeal)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.8 : 1)
                    .actionBorder(cornerRadius: 14, color: Brand.slateBlue.opacity(0.22))
            )
        case .approved, .unknown:
            return AnyView(
                Button {
                    Task { await appState.removeMembership(for: club) }
                } label: {
                    HStack(spacing: 8) {
                        if appState.isRemovingMembership(for: club) {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        Text(appState.isRemovingMembership(for: club) ? "Leaving..." : "Leave Club")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Brand.slateBlue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .opacity(isBusy ? 0.8 : 1)
                    .actionBorder(cornerRadius: 14, color: Brand.lightCyan.opacity(0.45))
            )
        case .none, .rejected:
            return nil
        }
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch selectedTab {
            case .games:
                gamesContent
            case .clubNews:
                clubNewsContent
            case .members:
                membersContent
            case .info:
                infoContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 24, tint: Color.white.opacity(0.66))
    }

    @ViewBuilder
    private var tabContentSection: some View {
        if selectedTab == .clubNews {
            clubNewsContent
        } else {
            contentCard
        }
    }

    private var clubNewsContent: some View {
        ClubNewsView(club: club, isClubModerator: appState.isClubAdmin(for: club))
            .environmentObject(appState)
    }

    private var ownerToolsPanel: some View {
        let pendingCount = appState.ownerJoinRequests(for: club).count

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    adminToolsHeaderLabel
                    Spacer(minLength: 8)
                    adminToolsRolePill
                }

                VStack(alignment: .leading, spacing: 8) {
                    adminToolsHeaderLabel
                    adminToolsRolePill
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Manage your club with quick tools for admins and owners.")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            ownerOnboardingChecklist

            if let info = appState.ownerToolsInfoMessage, !info.isEmpty {
                Text(verbatim: softWrappedDisplayText(info))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(verbatim: softWrappedDisplayText(AppCopy.friendlyError(error)))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
                    .appErrorCardStyle(cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                            Text(verbatim: softWrappedDisplayText(AppCopy.friendlyError(error)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
                    .appErrorCardStyle(cornerRadius: 12)
                }
            }

            VStack(spacing: 6) {
                Button {
                    ownerToolSheet = .joinRequests
                } label: {
                    ownerToolRow(
                        title: "Manage Join Requests",
                        subtitle: pendingCount == 0 ? "Review pending membership requests and approvals." : "\(pendingCount) pending request\(pendingCount == 1 ? "" : "s") ready for review.",
                        icon: "person.badge.plus"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    ownerToolSheet = .createGame
                } label: {
                    ownerToolRow(
                        title: "Create Game",
                        subtitle: "Publish a new session with time, capacity, fee, and notes.",
                        icon: "calendar.badge.plus"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    ownerToolSheet = .editClub
                } label: {
                    ownerToolRow(
                        title: "Club Settings",
                        subtitle: "Update contact info, join approval settings, and club details.",
                        icon: "slider.horizontal.3"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    ownerToolSheet = .members
                } label: {
                    ownerToolRow(
                        title: "Members",
                        subtitle: "View approved members and manage admin access.",
                        icon: "person.3.sequence.fill"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 20, tint: Brand.frostedSurfaceSoft)
    }

    private var ownerOnboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Club launch checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            ownerChecklistRow(
                title: "Set club profile picture",
                isComplete: ClubProfileImagePresets.presetID(from: club.imageURL) != nil
            )
            ownerChecklistRow(
                title: "Publish first game",
                isComplete: !appState.games(for: club).isEmpty
            )
            ownerChecklistRow(
                title: "Post first Club Chat update",
                isComplete: !appState.clubNewsPosts(for: club).isEmpty
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private func ownerChecklistRow(title: String, isComplete: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Brand.lightCyan : Color.white.opacity(0.72))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.95))
            Spacer(minLength: 0)
        }
    }

    private var adminToolsHeaderLabel: some View {
        Label("Admin Tools", systemImage: "crown.fill")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var adminToolsRolePill: some View {
        Text("Admins")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    private var gamesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Club Games")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    gamesRefreshControl
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Club Games")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    gamesRefreshControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isClubAdminUser {
                Button {
                    showPastGamesHistory.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showPastGamesHistory ? "clock.arrow.circlepath" : "clock")
                        Text(showPastGamesHistory ? "Showing Past + Upcoming" : "Show Past Games")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(showPastGamesHistory ? .white : Brand.pineTeal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        (showPastGamesHistory ? Brand.slateBlue : Color.white.opacity(0.9)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .actionBorder(
                    cornerRadius: 12,
                    color: showPastGamesHistory ? Brand.lightCyan.opacity(0.4) : Brand.slateBlue.opacity(0.22)
                )
            }

            if let error = appState.clubGamesError(for: club) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(AppCopy.friendlyError(error))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Retry") {
                            Task { await appState.refreshGames(for: club) }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                    }
                    .appErrorCardStyle(cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                            Text(AppCopy.friendlyError(error))
                                .lineLimit(3)
                        }
                        Button("Retry") {
                            Task { await appState.refreshGames(for: club) }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                    }
                    .appErrorCardStyle(cornerRadius: 12)
                }
            }

            if filteredClubGames.isEmpty, !appState.isLoadingGames(for: club) {
                Text("No games scheduled yet.")
                    .foregroundStyle(Brand.mutedText)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredClubGames) { game in
                        VStack(alignment: .leading, spacing: 8) {
                            NavigationLink {
                                GameDetailView(game: game)
                            } label: {
                                ClubGameRow(
                                    game: game,
                                    bookingState: appState.bookingState(for: game)
                                )
                            }
                            .buttonStyle(.plain)

                            if isClubAdminUser {
                                ownerGameQuickActions(game)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rankingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Doubles Ranking")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            searchBar

            ForEach(displayedMembers) { member in
                HStack(spacing: 12) {
                    Text("\(member.rank)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.spicyOrange)
                        .frame(width: 28)

                    Circle()
                        .fill(Brand.rosyTaupe.opacity(0.9))
                        .overlay(
                            Text(initials(member.name))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        )
                        .frame(width: 34, height: 34)

                    Text(member.name)
                        .font(.headline)
                        .foregroundStyle(Brand.ink)

                    Spacer(minLength: 8)

                    reliabilityRing(member.reliability)

                    Text(String(format: "%.3f", member.rating))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Brand.pineTeal)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Brand.rosyTaupe.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var membersContent: some View {
        let loadedMembers = appState.clubDirectoryMembers(for: club)
        let members = membersSortByDUPRDescending
            ? loadedMembers.sorted { lhs, rhs in
                let l = lhs.duprRating ?? -1
                let r = rhs.duprRating ?? -1
                if l == r {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return l > r
            }
            : loadedMembers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Members")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    membersSortToggle
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Members")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    membersSortToggle
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = appState.clubDirectoryError(for: club), !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(AppCopy.friendlyError(error))
                }
                .font(.footnote)
                .foregroundStyle(Brand.errorRed)
                .appErrorCardStyle(cornerRadius: 12)
            }

            if appState.isLoadingClubDirectory(for: club), members.isEmpty {
                ProgressView("Loading members...")
                    .tint(Brand.pineTeal)
            } else if members.isEmpty {
                Text("No approved members yet.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
            } else {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        Text(member.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.ink)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(member.duprRating.map { String(format: "%.3f", $0) } ?? "No DUPR")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(member.duprRating == nil ? Brand.mutedText : Brand.pineTeal)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            locationInfoSection("Address", body: safeAddress)
            infoSection("Club Contact", body: safeContactEmail)
            if let managerName = safeManagerName, !managerName.isEmpty {
                infoSection("Manager", body: managerName)
            }
            if let website = safeWebsite, !website.isEmpty {
                infoSection("Website", body: website)
            }
            infoSection("About The Club", body: safeDescription)
        }
    }

    private func prettify(_ raw: String) -> String {
        if raw.caseInsensitiveCompare("ladder") == .orderedSame ||
            raw.caseInsensitiveCompare("king_of_court") == .orderedSame {
            return "King of the Court"
        }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func filterMenuLabel(title: String, value: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Brand.mutedText)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .filterChipStyle(selected: isSelected, cornerRadius: 12)
    }

    private func ownerToolRow(title: String, subtitle: String, icon: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ownerToolIcon(icon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(softWrappedDisplayText(subtitle))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ownerToolChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ownerToolIcon(icon)
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ownerToolChevron
                }
                Text(softWrappedDisplayText(subtitle))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ownerToolIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var ownerToolChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.top, 2)
            .fixedSize()
    }

    private func ownerGameQuickActions(_ game: Game) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                editGameButton(game)
                duplicateGameButton(game)
                deleteGameButton(game)
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    editGameButton(game)
                    duplicateGameButton(game)
                }
                deleteGameButton(game)
            }
        }
    }

    private func nextWeekDraft(from game: Game) -> ClubOwnerGameDraft {
        var draft = ClubOwnerGameDraft(game: game)
        draft.startDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: game.dateTime) ?? game.dateTime
        draft.repeatWeekly = false
        draft.repeatCount = 1
        return draft
    }

    private func duplicateGameButton(_ game: Game) -> some View {
        Button {
            duplicatingGame = game
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text("Duplicate")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Brand.slateBlue)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isOwnerSavingGame(game) || appState.isOwnerDeletingGame(game))
        .actionBorder(cornerRadius: 12, color: Brand.slateBlue.opacity(0.22))
    }

    private var gamesRefreshControl: some View {
        Group {
            if appState.isLoadingGames(for: club) {
                ProgressView()
            } else {
                Button {
                    Task { await appState.refreshGames(for: club) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(Brand.brandPrimaryDark)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.88))
                    )
                }
                .buttonStyle(.plain)
                .actionBorder(cornerRadius: 12, color: Brand.brandPrimary.opacity(0.16))
            }
        }
    }

    private var membersSortToggle: some View {
        Button {
            membersSortByDUPRDescending.toggle()
        } label: {
            Text(membersSortByDUPRDescending ? "A-Z" : "Highest DUPR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(membersSortByDUPRDescending ? .white : Brand.pineTeal)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    (membersSortByDUPRDescending ? Brand.slateBlue : Color.white.opacity(0.92)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .actionBorder(
            cornerRadius: 12,
            color: membersSortByDUPRDescending ? Brand.lightCyan.opacity(0.4) : Brand.slateBlue.opacity(0.22)
        )
    }

    private func editGameButton(_ game: Game) -> some View {
        Button {
            editingOwnerGame = game
        } label: {
            HStack(spacing: 6) {
                if appState.isOwnerSavingGame(game) {
                    ProgressView().tint(Brand.pineTeal)
                } else {
                    Image(systemName: "square.and.pencil")
                }
                Text("Edit Game")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Brand.pineTeal)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isOwnerDeletingGame(game))
        .actionBorder(cornerRadius: 12, color: Brand.slateBlue.opacity(0.22))
    }

    private func deleteGameButton(_ game: Game) -> some View {
        Button {
            ownerDeleteGameCandidate = game
        } label: {
            HStack(spacing: 6) {
                if appState.isOwnerDeletingGame(game) {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "trash")
                }
                Text(appState.isOwnerDeletingGame(game) ? "Deleting..." : "Delete")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Brand.coralBlaze, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isOwnerSavingGame(game))
        .actionBorder(cornerRadius: 12, color: Brand.lightCyan.opacity(0.45))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.pineTeal)
            TextField("Search members", text: $searchText)
        }
        .padding()
        .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Brand.rosyTaupe.opacity(0.6), lineWidth: 1)
        )
    }

    private func reliabilityRing(_ value: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Brand.rosyTaupe.opacity(0.35), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(value) / 100)
                .stroke(Brand.spicyOrange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(.caption2.bold())
                .foregroundStyle(Brand.pineTeal)
        }
        .frame(width: 34, height: 34)
    }

    private func infoSection(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.ink)
            Text(verbatim: softWrappedDisplayText(body))
                .foregroundStyle(Brand.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func softWrappedDisplayText(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let cappedRaw: String
        if raw.count > Self.maxRenderableDetailTextLength {
            cappedRaw = String(raw.prefix(Self.maxRenderableDetailTextLength)) + "..."
        } else {
            cappedRaw = raw
        }

        let breakAfter = CharacterSet(charactersIn: "/._-?&=:@,")
        let whitespace = CharacterSet.whitespacesAndNewlines
        var output = String.UnicodeScalarView()
        var runLength = 0

        for scalar in cappedRaw.unicodeScalars {
            output.append(scalar)

            if whitespace.contains(scalar) {
                runLength = 0
                continue
            }

            runLength += 1

            if breakAfter.contains(scalar) || runLength >= 18 {
                output.append(UnicodeScalar(0x200B)!)
                runLength = 0
            }
        }

        return String(output)
    }

    private func cappedDisplayText(_ raw: String, maxLength: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    private func trimmedOptional(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func locationInfoSection(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.ink)

            if let url = MapNavigationURL.directions(to: body) {
                Button {
                    openURL(url)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.top, 3)
                        Text(verbatim: softWrappedDisplayText(body))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Brand.pineTeal)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: softWrappedDisplayText(body))
                    .foregroundStyle(Brand.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let chars = parts.prefix(2).compactMap { $0.first }
        return String(chars)
    }

    private var heroArtwork: some View {
        ZStack {
            if let preset = ClubProfileImagePresets.preset(for: club.imageURL) {
                ProfileAvatarArtwork(preset: preset, variant: .club)
            } else if let url = club.imageURL, isRemoteImageURL(url) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Brand.pineTeal.opacity(0.95))
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        fallbackHeroIcon
                    @unknown default:
                        fallbackHeroIcon
                    }
                }
            } else {
                fallbackHeroIcon
            }
        }
    }

    private var fallbackHeroIcon: some View {
        Image(systemName: club.imageSystemName)
            .font(.system(size: 34))
            .foregroundStyle(Brand.rosyTaupe.opacity(0.95))
    }

    private func isRemoteImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func iconName(for state: ClubMembershipState, isRequesting: Bool) -> String {
        if isRequesting { return "hourglass" }
        switch state {
        case .none, .rejected:
            return "plus.circle.fill"
        case .pending:
            return "clock.badge.checkmark.fill"
        case .approved, .unknown:
            return "checkmark.circle.fill"
        }
    }

    private func loadDataIfNeeded(for tab: ClubDetailTab) async {
        if tab == .games, appState.games(for: club).isEmpty {
            await appState.refreshGames(for: club)
        }
        if tab == .members, appState.clubDirectoryMembers(for: club).isEmpty {
            await appState.refreshClubDirectoryMembers(for: club)
        }
        if tab == .clubNews, appState.clubNewsPosts(for: club).isEmpty {
            await appState.refreshClubNews(for: club)
        }
    }
}


#Preview {
    NavigationStack {
        ClubDetailView(club: MockData.clubs[0])
            .environmentObject({
                let state = AppState()
                state.signInPreview()
                let previewID = state.authUserID ?? UUID()
                state.profile = UserProfile(
                    id: previewID,
                    fullName: "Brayden Kelly",
                    email: "preview@bookadink.app",
                    favoriteClubName: nil,
                    skillLevel: .intermediate
                )
                return state
            }())
    }
}
