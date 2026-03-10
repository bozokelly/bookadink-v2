import Combine
import Foundation
import os
import UIKit
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    private enum StorageKeys {
        static let authSession = "bookadink.auth.session"
        static let checkedInBookingIDs = "bookadink.owner.checkedInBookingIDs"
        static let clubNewsNotificationsEnabled = "bookadink.clubNews.notificationsEnabled"
        static let duprIDByUserID = "bookadink.profile.duprIDByUserID"
        static let duprRatingsByUserID = "bookadink.profile.duprRatingsByUserID"
        static let duprHistoryByUserID = "bookadink.profile.duprHistoryByUserID"
    }

    private let dataProvider: ClubDataProviding
    private let telemetryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BookadinkV2", category: "ClubTelemetry")

    /// Reminder and calendar-export state lives here to limit re-render scope.
    /// Inject as a separate @EnvironmentObject so only views that need it re-render.
    let scheduleStore = GameScheduleStore()

    @Published var pendingDeepLink: DeepLink? = nil
    @Published var authState: AuthState = .signedOut
    @Published var authUserID: UUID? = nil
    @Published var authEmail: String? = nil
    @Published var authAccessToken: String? = nil
    @Published var authRefreshToken: String? = nil
    @Published var profile: UserProfile? = nil
    @Published var clubs: [Club] = MockData.clubs
    @Published var gamesByClubID: [UUID: [Game]] = [:]
    @Published var bookings: [BookingWithGame] = []
    @Published var attendeesByGameID: [UUID: [GameAttendee]] = [:]
    @Published var membershipStatesByClubID: [UUID: ClubMembershipState] = [:]
    @Published var ownerJoinRequestsByClubID: [UUID: [ClubJoinRequest]] = [:]
    @Published var ownerMembersByClubID: [UUID: [ClubOwnerMember]] = [:]
    @Published var clubDirectoryMembersByClubID: [UUID: [ClubDirectoryMember]] = [:]
    @Published var clubNewsPostsByClubID: [UUID: [ClubNewsPost]] = [:]
    @Published var clubNewsReportsByClubID: [UUID: [ClubNewsModerationReport]] = [:]
    @Published var clubAdminRoleByClubID: [UUID: String] = [:]
    @Published var requestingMembershipClubIDs: Set<UUID> = []
    @Published var removingMembershipClubIDs: Set<UUID> = []
    @Published var loadingOwnerJoinRequestClubIDs: Set<UUID> = []
    @Published var loadingOwnerMembersClubIDs: Set<UUID> = []
    @Published var loadingClubDirectoryClubIDs: Set<UUID> = []
    @Published var ownerMembershipDecisionRequestIDs: Set<UUID> = []
    @Published var ownerAdminUpdatingUserIDs: Set<UUID> = []
    @Published var ownerMemberModerationUserIDs: Set<UUID> = []
    @Published var loadingClubNewsClubIDs: Set<UUID> = []
    @Published var loadingClubNewsReportsClubIDs: Set<UUID> = []
    @Published var postingClubNewsClubIDs: Set<UUID> = []
    @Published var updatingClubNewsPostIDs: Set<UUID> = []
    @Published var creatingClubNewsCommentPostIDs: Set<UUID> = []
    @Published var resolvingClubNewsReportIDs: Set<UUID> = []
    @Published var requestingBookingGameIDs: Set<UUID> = []
    @Published var cancellingBookingIDs: Set<UUID> = []
    @Published var loadingAttendeeGameIDs: Set<UUID> = []
    @Published var ownerBookingUpdatingIDs: Set<UUID> = []
    @Published var ownerSavingGameIDs: Set<UUID> = []
    @Published var ownerDeletingGameIDs: Set<UUID> = []
    @Published var isDeletingClubIDs: Set<UUID> = []
    // reminderGameIDs, calendarGameIDs, exportingCalendarGameIDs live on scheduleStore.
    @Published var checkedInBookingIDs: Set<UUID> = []
    @Published var isLoadingClubs = false
    @Published var loadingClubGameIDs: Set<UUID> = []
    @Published var clubGamesErrorByClubID: [UUID: String] = [:]
    @Published var clubNewsErrorByClubID: [UUID: String] = [:]
    @Published var clubNewsReportsErrorByClubID: [UUID: String] = [:]
    @Published var clubDirectoryErrorByClubID: [UUID: String] = [:]
    @Published var notifications: [AppNotification] = []
    @Published var isLoadingNotifications = false
    @Published var isLoadingBookings = false
    @Published var bookingsErrorMessage: String? = nil
    @Published var clubsLoadErrorMessage: String? = nil
    @Published var isUsingLiveClubData = false
    @Published var isAuthenticating = false
    @Published var isRefreshingSession = false
    @Published var authErrorMessage: String? = nil
    @Published var authInfoMessage: String? = nil
    @Published var isSavingProfile = false
    @Published var profileSaveErrorMessage: String? = nil
    @Published var isUpdatingPassword = false
    @Published var passwordUpdateMessage: String? = nil
    @Published var bookingInfoMessage: String? = nil
    @Published var membershipInfoMessage: String? = nil
    @Published var membershipErrorMessage: String? = nil
    @Published var ownerToolsInfoMessage: String? = nil
    @Published var ownerToolsErrorMessage: String? = nil
    @Published var isSavingClubOwnerSettings = false
    @Published var isCreatingClub = false
    @Published var isCreatingOwnerGame = false
    @Published var isInitialBootstrapComplete = false
    @Published var duprID: String? = nil
    @Published var duprDoublesRating: Double? = nil
    @Published var duprSinglesRating: Double? = nil
    @Published var clubNewsNotificationsEnabled = true
    @Published var remotePushTokenHex: String? = nil
    @Published var remotePushRegistrationErrorMessage: String? = nil
    private var clubNewsPrimedClubIDs: Set<UUID> = []
    private var seenClubNewsPostIDsByClubID: [UUID: Set<UUID>] = [:]
    private var seenClubNewsCommentIDsByClubID: [UUID: Set<UUID>] = [:]
    private var hasAttemptedRemotePushRegistrationThisLaunch = false
    private var clubChatRealtimeClients: [UUID: SupabaseClubChatRealtimeClient] = [:]
    private var clubChatRealtimeRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var duprIDByUserID: [UUID: String] = [:]
    private var duprRatingsByUserID: [UUID: (doubles: Double?, singles: Double?)] = [:]
    private var duprHistoryByUserID: [UUID: [DUPREntry]] = [:]
    @Published var duprHistory: [DUPREntry] = []

    init(dataProvider: ClubDataProviding = SupabaseService()) {
        self.dataProvider = dataProvider
        restorePersistedSession()
        restoreDUPRIDStore()
        restoreDUPRRatingsStore()
        restoreDUPRHistoryStore()
        syncCurrentUserDUPRIDFromStore()
        syncCurrentUserDUPRRatingsFromStore()
        syncDUPRHistoryToCurrentUser()
        restoreCheckedInBookingIDs()
        restoreClubNewsNotificationPreference()

        Task {
            if authState == .signedIn {
                _ = await refreshSessionIfPossible(silent: true)
            }
            await refreshClubs()
            if authState == .signedIn {
                await loadProfileFromBackendIfAvailable()
                await refreshBookings()
            }
            isInitialBootstrapComplete = true
        }
    }

    func signInPreview() {
        authState = .signedIn
        if authUserID == nil {
            authUserID = UUID()
        }
        authEmail = authEmail ?? "preview@bookadink.app"
        syncCurrentUserDUPRIDFromStore()
        syncCurrentUserDUPRRatingsFromStore()

        Task {
            await refreshMemberships()
        }
    }

    func signOut() {
        // Clear push token from server before wiping session
        if let uid = authUserID {
            Task { try? await self.dataProvider.updateProfilePushToken(userID: uid, pushToken: nil) }
        }
        authState = .signedOut
        authUserID = nil
        authEmail = nil
        authAccessToken = nil
        authRefreshToken = nil
        profile = nil
        duprID = nil
        duprDoublesRating = nil
        duprSinglesRating = nil
        gamesByClubID = [:]
        bookings = []
        attendeesByGameID = [:]
        membershipStatesByClubID = [:]
        ownerJoinRequestsByClubID = [:]
        ownerMembersByClubID = [:]
        clubDirectoryMembersByClubID = [:]
        clubNewsPostsByClubID = [:]
        clubNewsReportsByClubID = [:]
        clubAdminRoleByClubID = [:]
        clubNewsPrimedClubIDs = []
        seenClubNewsPostIDsByClubID = [:]
        seenClubNewsCommentIDsByClubID = [:]
        for client in clubChatRealtimeClients.values {
            client.stop()
        }
        clubChatRealtimeClients = [:]
        for task in clubChatRealtimeRefreshTasks.values {
            task.cancel()
        }
        clubChatRealtimeRefreshTasks = [:]
        requestingMembershipClubIDs = []
        removingMembershipClubIDs = []
        loadingOwnerJoinRequestClubIDs = []
        loadingOwnerMembersClubIDs = []
        loadingClubDirectoryClubIDs = []
        ownerMembershipDecisionRequestIDs = []
        ownerAdminUpdatingUserIDs = []
        ownerMemberModerationUserIDs = []
        loadingClubNewsClubIDs = []
        loadingClubNewsReportsClubIDs = []
        postingClubNewsClubIDs = []
        updatingClubNewsPostIDs = []
        creatingClubNewsCommentPostIDs = []
        resolvingClubNewsReportIDs = []
        requestingBookingGameIDs = []
        cancellingBookingIDs = []
        ownerSavingGameIDs = []
        ownerDeletingGameIDs = []
        loadingAttendeeGameIDs = []
        ownerBookingUpdatingIDs = []
        scheduleStore.clearAll()
        checkedInBookingIDs = []
        authErrorMessage = nil
        authInfoMessage = nil
        profileSaveErrorMessage = nil
        bookingsErrorMessage = nil
        bookingInfoMessage = nil
        membershipInfoMessage = nil
        membershipErrorMessage = nil
        ownerToolsInfoMessage = nil
        ownerToolsErrorMessage = nil
        isCreatingClub = false
        clubNewsErrorByClubID = [:]
        clubNewsReportsErrorByClubID = [:]
        clubDirectoryErrorByClubID = [:]
        notifications = []
        dataProvider.setAccessToken(nil)
        clearPersistedSession()
        persistCheckedInBookingIDs()
        isInitialBootstrapComplete = true
    }

    func signIn(email: String, password: String) async {
        authErrorMessage = nil
        authInfoMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let result = try await dataProvider.signIn(email: email, password: password)
            applyAuthFlowResult(result)
            await postAuthenticationBootstrap()
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        authErrorMessage = nil
        authInfoMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let result = try await dataProvider.signUp(email: email, password: password)
            applyAuthFlowResult(result)
            if authState == .signedIn {
                await postAuthenticationBootstrap()
            }
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func completeProfile(name: String, homeClub: String?, skillLevel: SkillLevel, avatarPresetID: String?) async {
        let userID = authUserID ?? UUID()
        authUserID = userID
        syncCurrentUserDUPRIDFromStore()
        syncCurrentUserDUPRRatingsFromStore()

        let draft = UserProfile(
            id: userID,
            fullName: name,
            email: authEmail ?? "preview@bookadink.app",
            favoriteClubName: homeClub,
            skillLevel: skillLevel,
            avatarPresetID: avatarPresetID
        )
        profile = draft

        profileSaveErrorMessage = nil

        guard authState == .signedIn else {
            Task {
                await refreshMemberships()
            }
            return
        }

        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            let persisted = try await withAuthRetry {
                try await self.dataProvider.upsertProfile(draft)
            }
            profile = persisted
            authUserID = persisted.id
            authEmail = persisted.email
        } catch {
            profileSaveErrorMessage = error.localizedDescription
        }

        await refreshMemberships()
    }

    func refreshClubs() async {
        let startedAt = Date()
        telemetry("refresh_clubs_start auth_state=\(authState == .signedIn ? "signed_in" : "signed_out")")
        isLoadingClubs = true
        clubsLoadErrorMessage = nil

        do {
            let fetched = try await dataProvider.fetchClubs()
            if !fetched.isEmpty {
                clubs = fetched
                isUsingLiveClubData = true
            }
            telemetry("refresh_clubs_success count=\(fetched.count) duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            clubsLoadErrorMessage = error.localizedDescription
            isUsingLiveClubData = false
            print("[Clubs] Fetch FAILED: \(error)")
            telemetry("refresh_clubs_error duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }

        isLoadingClubs = false

        if authState == .signedIn {
            await refreshMemberships()
        }
    }

    func refreshMemberships() async {
        guard let userID = authUserID else { return }

        do {
            let memberships = try await withAuthRetry {
                try await self.dataProvider.fetchMemberships(userID: userID)
            }
            membershipStatesByClubID = memberships.reduce(into: [:]) { partial, record in
                partial[record.clubID] = record.status
            }
        } catch {
            // Keep local state if backend membership fetch isn't available yet.
        }
    }

    func membershipState(for club: Club) -> ClubMembershipState {
        membershipStatesByClubID[club.id] ?? .none
    }

    func games(for club: Club) -> [Game] {
        gamesByClubID[club.id] ?? []
    }

    func isLoadingGames(for club: Club) -> Bool {
        loadingClubGameIDs.contains(club.id)
    }

    func clubGamesError(for club: Club) -> String? {
        clubGamesErrorByClubID[club.id]
    }

    func clubDirectoryMembers(for club: Club) -> [ClubDirectoryMember] {
        clubDirectoryMembersByClubID[club.id] ?? []
    }

    func clubDirectoryError(for club: Club) -> String? {
        clubDirectoryErrorByClubID[club.id]
    }

    func isLoadingClubDirectory(for club: Club) -> Bool {
        loadingClubDirectoryClubIDs.contains(club.id)
    }

    func clubNewsPosts(for club: Club) -> [ClubNewsPost] {
        clubNewsPostsByClubID[club.id] ?? []
    }

    func clubNewsError(for club: Club) -> String? {
        clubNewsErrorByClubID[club.id]
    }

    func clubNewsReports(for club: Club) -> [ClubNewsModerationReport] {
        clubNewsReportsByClubID[club.id] ?? []
    }

    func clubNewsReportsError(for club: Club) -> String? {
        clubNewsReportsErrorByClubID[club.id]
    }

    func isLoadingClubNews(for club: Club) -> Bool {
        loadingClubNewsClubIDs.contains(club.id)
    }

    func isLoadingClubNewsReports(for club: Club) -> Bool {
        loadingClubNewsReportsClubIDs.contains(club.id)
    }

    func isPostingClubNews(for club: Club) -> Bool {
        postingClubNewsClubIDs.contains(club.id)
    }

    func isUpdatingClubNewsPost(_ postID: UUID) -> Bool {
        updatingClubNewsPostIDs.contains(postID)
    }

    func isCreatingClubNewsComment(for postID: UUID) -> Bool {
        creatingClubNewsCommentPostIDs.contains(postID)
    }

    func isResolvingClubNewsReport(_ reportID: UUID) -> Bool {
        resolvingClubNewsReportIDs.contains(reportID)
    }

    func isClubAdmin(for club: Club) -> Bool {
        if club.createdByUserID == authUserID { return true }
        guard let role = clubAdminRoleByClubID[club.id]?.lowercased() else { return false }
        return role == "owner" || role == "admin"
    }

    func bookingState(for game: Game) -> BookingState {
        bookings.first(where: { $0.booking.gameID == game.id })?.booking.state ?? .none
    }

    func existingBooking(for game: Game) -> BookingRecord? {
        bookings.first(where: { $0.booking.gameID == game.id })?.booking
    }

    func isRequestingBooking(for game: Game) -> Bool {
        requestingBookingGameIDs.contains(game.id)
    }

    func isCancellingBooking(for game: Game) -> Bool {
        cancellingBookingIDs.contains(game.id)
    }

    func gameAttendees(for game: Game) -> [GameAttendee] {
        attendeesByGameID[game.id] ?? []
    }

    func isLoadingAttendees(for game: Game) -> Bool {
        loadingAttendeeGameIDs.contains(game.id)
    }

    func isUpdatingOwnerBooking(_ bookingID: UUID) -> Bool {
        ownerBookingUpdatingIDs.contains(bookingID)
    }

    func isCheckedIn(bookingID: UUID) -> Bool {
        checkedInBookingIDs.contains(bookingID)
    }

    func isOwnerSavingGame(_ game: Game) -> Bool {
        ownerSavingGameIDs.contains(game.id)
    }

    func isOwnerDeletingGame(_ game: Game) -> Bool {
        ownerDeletingGameIDs.contains(game.id)
    }

    func isDeletingClub(_ club: Club) -> Bool {
        isDeletingClubIDs.contains(club.id)
    }

    func hasReminder(for game: Game) -> Bool {
        scheduleStore.hasReminder(for: game)
    }

    func hasCalendarExport(for game: Game) -> Bool {
        scheduleStore.hasCalendarExport(for: game)
    }

    func isExportingCalendar(for game: Game) -> Bool {
        scheduleStore.isExportingCalendar(for: game)
    }

    func saveCurrentUserDUPRID(_ raw: String) -> String? {
        guard let userID = authUserID else { return "Sign in to save your DUPR ID." }
        let normalized = normalizeDUPRID(raw)
        guard !normalized.isEmpty else { return "DUPR ID is required for DUPR games." }
        guard isLikelyDUPRID(normalized) else { return "Enter a valid DUPR ID." }

        duprIDByUserID[userID] = normalized
        duprID = normalized
        persistDUPRIDStore()
        return nil
    }

    /// Saves DUPR ratings for the current user. Returns an error string on failure, nil on success.
    func saveDUPRRatings(doubles: Double?, singles: Double?) -> String? {
        guard let userID = authUserID else { return "Sign in to save your DUPR ratings." }
        if let d = doubles, (d < 1.0 || d > 8.0) { return "Doubles rating must be between 1.0 and 8.0." }
        if let s = singles, (s < 1.0 || s > 8.0) { return "Singles rating must be between 1.0 and 8.0." }
        duprRatingsByUserID[userID] = (doubles: doubles, singles: singles)
        duprDoublesRating = doubles
        duprSinglesRating = singles
        persistDUPRRatingsStore()
        if let d = doubles {
            appendDUPREntry(rating: d, context: "DUPR sync")
        }
        return nil
    }

    func refreshGames(for club: Club) async {
        let startedAt = Date()
        telemetry("refresh_games_start club_id=\(club.id.uuidString)")
        loadingClubGameIDs.insert(club.id)
        clubGamesErrorByClubID[club.id] = nil
        defer { loadingClubGameIDs.remove(club.id) }

        do {
            let loaded = try await withAuthRetry {
                try await self.dataProvider.fetchGames(clubID: club.id)
            }
            gamesByClubID[club.id] = loaded
            telemetry("refresh_games_success club_id=\(club.id.uuidString) count=\(loaded.count) duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            clubGamesErrorByClubID[club.id] = error.localizedDescription
            telemetry("refresh_games_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }
    }

    func refreshClubDirectoryMembers(for club: Club) async {
        let startedAt = Date()
        telemetry("refresh_members_start club_id=\(club.id.uuidString)")
        loadingClubDirectoryClubIDs.insert(club.id)
        clubDirectoryErrorByClubID[club.id] = nil
        defer { loadingClubDirectoryClubIDs.remove(club.id) }

        do {
            let members = try await withAuthRetry {
                try await self.dataProvider.fetchClubDirectoryMembers(clubID: club.id)
            }
            clubDirectoryMembersByClubID[club.id] = members
            telemetry("refresh_members_success club_id=\(club.id.uuidString) count=\(members.count) duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            clubDirectoryErrorByClubID[club.id] = error.localizedDescription
            telemetry("refresh_members_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }
    }

    func refreshClubNews(for club: Club) async {
        let startedAt = Date()
        telemetry("refresh_news_start club_id=\(club.id.uuidString)")
        loadingClubNewsClubIDs.insert(club.id)
        clubNewsErrorByClubID[club.id] = nil
        defer { loadingClubNewsClubIDs.remove(club.id) }

        do {
            let previousPosts = clubNewsPostsByClubID[club.id] ?? []
            let posts = try await withAuthRetry {
                try await self.dataProvider.fetchClubNewsPosts(clubID: club.id, currentUserID: self.authUserID)
            }
            clubNewsPostsByClubID[club.id] = posts
            await handleClubNewsNotificationsIfNeeded(club: club, previousPosts: previousPosts, newPosts: posts)
            telemetry("refresh_news_success club_id=\(club.id.uuidString) count=\(posts.count) duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
            telemetry("refresh_news_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }
    }

    func startClubChatRealtime(for club: Club, includeModeration: Bool) {
        guard SupabaseConfig.isConfigured else { return }
        guard clubChatRealtimeClients[club.id] == nil else { return }

        let client = SupabaseClubChatRealtimeClient(
            clubID: club.id,
            includeModerationMessages: includeModeration,
            accessTokenProvider: { [weak self] in self?.authAccessToken },
            onEvent: { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected:
                    self.scheduleClubChatRealtimeRefresh(for: club, includeModeration: includeModeration, immediate: true)
                case .postgresChange:
                    self.scheduleClubChatRealtimeRefresh(for: club, includeModeration: includeModeration, immediate: false)
                case let .error(message):
                    if self.clubNewsErrorByClubID[club.id] == nil {
                        self.clubNewsErrorByClubID[club.id] = AppCopy.friendlyError(message)
                    }
                case .disconnected:
                    break
                }
            }
        )

        clubChatRealtimeClients[club.id] = client
        client.start()
    }

    func stopClubChatRealtime(for club: Club) {
        clubChatRealtimeRefreshTasks[club.id]?.cancel()
        clubChatRealtimeRefreshTasks.removeValue(forKey: club.id)
        clubChatRealtimeClients[club.id]?.stop()
        clubChatRealtimeClients.removeValue(forKey: club.id)
    }

    private func scheduleClubChatRealtimeRefresh(for club: Club, includeModeration: Bool, immediate: Bool) {
        guard clubChatRealtimeRefreshTasks[club.id] == nil else { return }
        clubChatRealtimeRefreshTasks[club.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.clubChatRealtimeRefreshTasks.removeValue(forKey: club.id)
                }
            }
            if !immediate {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if Task.isCancelled { return }
            await self.refreshClubNews(for: club)
            if includeModeration {
                await self.refreshClubNewsModerationReports(for: club)
            }
        }
    }

    func refreshClubAdminRole(for club: Club) async {
        let startedAt = Date()
        telemetry("refresh_admin_role_start club_id=\(club.id.uuidString)")
        guard let authUserID else { return }
        do {
            let role = try await withAuthRetry {
                try await self.dataProvider.fetchClubAdminRole(clubID: club.id, userID: authUserID)
            }
            if let role {
                clubAdminRoleByClubID[club.id] = role
            } else {
                clubAdminRoleByClubID.removeValue(forKey: club.id)
            }
            telemetry("refresh_admin_role_success club_id=\(club.id.uuidString) role=\(role ?? "none") duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            // Non-fatal; owner check still works.
            telemetry("refresh_admin_role_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }
    }

    func createClubNewsPost(for club: Club, content: String, images: [FeedImageUploadPayload], isAnnouncement: Bool = false) async -> Bool {
        clubNewsErrorByClubID[club.id] = nil
        guard let authUserID else {
            authState = .signedOut
            return false
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else {
            clubNewsErrorByClubID[club.id] = "Write something or attach a photo."
            return false
        }

        postingClubNewsClubIDs.insert(club.id)
        defer { postingClubNewsClubIDs.remove(club.id) }

        do {
            var uploadedURLs: [URL] = []
            if !images.isEmpty {
                for image in images {
                    let url = try await withAuthRetry {
                        try await self.dataProvider.uploadClubNewsImage(
                            image,
                            userID: authUserID,
                            clubID: club.id
                        )
                    }
                    uploadedURLs.append(url)
                }
            }

            try await withAuthRetry {
                try await self.dataProvider.createClubNewsPost(
                    clubID: club.id,
                    userID: authUserID,
                    content: trimmed,
                    imageURLs: uploadedURLs,
                    isAnnouncement: isAnnouncement
                )
            }
            if isAnnouncement {
                // Fan-out: notification row + push for every club member
                try? await dataProvider.triggerClubAnnouncementNotify(
                    clubID: club.id,
                    postID: club.id, // used as reference; post ID not returned by createClubNewsPost
                    posterUserID: authUserID,
                    clubName: club.name,
                    posterName: profile?.fullName ?? "A club member",
                    postBody: trimmed
                )
            } else {
                try? await withAuthRetry {
                    try await self.dataProvider.triggerClubChatPushHook(
                        clubID: club.id,
                        actorUserID: authUserID,
                        event: "new_post",
                        referenceID: nil
                    )
                }
            }
            await refreshClubNews(for: club)
            return true
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
            return false
        }
    }

    func toggleClubNewsLike(for club: Club, post: ClubNewsPost) async {
        clubNewsErrorByClubID[club.id] = nil
        guard let authUserID else {
            authState = .signedOut
            return
        }

        updatingClubNewsPostIDs.insert(post.id)
        defer { updatingClubNewsPostIDs.remove(post.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.toggleClubNewsLike(postID: post.id, userID: authUserID)
            }
            await refreshClubNews(for: club)
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func addClubNewsComment(for club: Club, post: ClubNewsPost, content: String, parentCommentID: UUID? = nil) async {
        clubNewsErrorByClubID[club.id] = nil
        guard let authUserID else {
            authState = .signedOut
            return
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        creatingClubNewsCommentPostIDs.insert(post.id)
        defer { creatingClubNewsCommentPostIDs.remove(post.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.createClubNewsComment(
                    postID: post.id,
                    userID: authUserID,
                    content: trimmed,
                    parentCommentID: parentCommentID
                )
            }
            try? await withAuthRetry {
                try await self.dataProvider.triggerClubChatPushHook(
                    clubID: club.id,
                    actorUserID: authUserID,
                    event: "new_comment",
                    referenceID: post.id
                )
            }
            await refreshClubNews(for: club)
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func deleteClubNewsComment(for club: Club, post: ClubNewsPost, comment: ClubNewsComment) async {
        clubNewsErrorByClubID[club.id] = nil
        updatingClubNewsPostIDs.insert(post.id)
        defer { updatingClubNewsPostIDs.remove(post.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.deleteClubNewsComment(commentID: comment.id)
            }
            await refreshClubNews(for: club)
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func deleteClubNewsPost(for club: Club, post: ClubNewsPost) async {
        clubNewsErrorByClubID[club.id] = nil
        updatingClubNewsPostIDs.insert(post.id)
        defer { updatingClubNewsPostIDs.remove(post.id) }

        do {
            try? await withAuthRetry {
                try await self.dataProvider.deleteClubNewsImages(post.imageURLs)
            }
            try await withAuthRetry {
                try await self.dataProvider.deleteClubNewsPost(postID: post.id)
            }
            clubNewsPostsByClubID[club.id] = clubNewsPosts(for: club).filter { $0.id != post.id }
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func editClubNewsPost(for club: Club, post: ClubNewsPost, content: String, appendedImages: [FeedImageUploadPayload], retainedImageURLs: [URL]) async -> Bool {
        clubNewsErrorByClubID[club.id] = nil
        guard let authUserID else {
            authState = .signedOut
            return false
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !retainedImageURLs.isEmpty || !appendedImages.isEmpty else {
            clubNewsErrorByClubID[club.id] = "Post cannot be empty."
            return false
        }

        updatingClubNewsPostIDs.insert(post.id)
        defer { updatingClubNewsPostIDs.remove(post.id) }

        do {
            let removedURLs = post.imageURLs.filter { !Set(retainedImageURLs).contains($0) }
            var imageURLs = retainedImageURLs
            if !appendedImages.isEmpty {
                for image in appendedImages {
                    let uploadedURL = try await withAuthRetry {
                        try await self.dataProvider.uploadClubNewsImage(image, userID: authUserID, clubID: club.id)
                    }
                    imageURLs.append(uploadedURL)
                }
            }
            try await withAuthRetry {
                try await self.dataProvider.updateClubNewsPost(postID: post.id, content: trimmed, imageURLs: imageURLs)
            }
            if !removedURLs.isEmpty {
                try? await withAuthRetry {
                    try await self.dataProvider.deleteClubNewsImages(removedURLs)
                }
            }
            await refreshClubNews(for: club)
            return true
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
            return false
        }
    }

    func reportClubNewsPost(for club: Club, post: ClubNewsPost, reason: String, details: String = "") async {
        await createClubNewsReport(for: club, targetKind: .post, targetID: post.id, reason: reason, details: details)
    }

    func reportClubNewsComment(for club: Club, comment: ClubNewsComment, reason: String, details: String = "") async {
        await createClubNewsReport(for: club, targetKind: .comment, targetID: comment.id, reason: reason, details: details)
    }

    private func createClubNewsReport(for club: Club, targetKind: ClubNewsModerationReport.TargetKind, targetID: UUID?, reason: String, details: String) async {
        clubNewsErrorByClubID[club.id] = nil
        guard let authUserID else {
            authState = .signedOut
            return
        }

        do {
            try await withAuthRetry {
                try await self.dataProvider.createClubNewsModerationReport(
                    clubID: club.id,
                    senderUserID: authUserID,
                    targetKind: targetKind,
                    targetID: targetID,
                    reason: reason,
                    details: details
                )
            }
            ownerToolsInfoMessage = "Report submitted."
        } catch {
            clubNewsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func refreshClubNewsModerationReports(for club: Club) async {
        loadingClubNewsReportsClubIDs.insert(club.id)
        clubNewsReportsErrorByClubID[club.id] = nil
        defer { loadingClubNewsReportsClubIDs.remove(club.id) }

        do {
            let reports = try await withAuthRetry {
                try await self.dataProvider.fetchClubNewsModerationReports(clubID: club.id)
            }
            clubNewsReportsByClubID[club.id] = reports
        } catch {
            clubNewsReportsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func resolveClubNewsModerationReport(for club: Club, report: ClubNewsModerationReport) async {
        clubNewsReportsErrorByClubID[club.id] = nil
        resolvingClubNewsReportIDs.insert(report.id)
        defer { resolvingClubNewsReportIDs.remove(report.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.resolveClubNewsModerationReport(reportID: report.id)
            }
            clubNewsReportsByClubID[club.id] = clubNewsReports(for: club).filter { $0.id != report.id }
        } catch {
            clubNewsReportsErrorByClubID[club.id] = error.localizedDescription
        }
    }

    func setClubNewsNotificationsEnabled(_ enabled: Bool) {
        clubNewsNotificationsEnabled = enabled
        persistClubNewsNotificationPreference()
        if enabled {
            Task { await prepareClubChatPushNotificationsIfNeeded() }
        }
    }

    func prepareClubChatPushNotificationsIfNeeded() async {
        guard clubNewsNotificationsEnabled else { return }
        guard !hasAttemptedRemotePushRegistrationThisLaunch else { return }
        hasAttemptedRemotePushRegistrationThisLaunch = true
        remotePushRegistrationErrorMessage = nil

        let center = UNUserNotificationCenter.current()
        let settings = await loadNotificationSettings(center)

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            do {
                let granted = try await requestNotificationAuthorization(center)
                guard granted else {
                    remotePushRegistrationErrorMessage = "Notifications were not enabled."
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                remotePushRegistrationErrorMessage = error.localizedDescription
            }
        case .denied:
            remotePushRegistrationErrorMessage = "Notifications are disabled. Enable them in Settings to receive chat alerts."
        @unknown default:
            remotePushRegistrationErrorMessage = "Notification permissions are unavailable."
        }
    }

    func handleRemotePushDeviceToken(_ tokenHex: String) {
        remotePushRegistrationErrorMessage = nil
        remotePushTokenHex = tokenHex

        guard let authUserID else { return }

        Task {
            do {
                try await withAuthRetry {
                    try await self.dataProvider.updateProfilePushToken(userID: authUserID, pushToken: tokenHex)
                }
            } catch {
                // Non-fatal for current UX; local notifications continue to work.
                await MainActor.run {
                    self.remotePushRegistrationErrorMessage = AppCopy.friendlyError(error.localizedDescription)
                }
            }
        }
    }

    func handleRemotePushRegistrationFailure(_ message: String) {
        remotePushRegistrationErrorMessage = AppCopy.friendlyError(message)
    }

    func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        // If not yet authenticated, store and re-fire after sign-in
        guard authState == .signedIn else {
            pendingDeepLink = link
            return
        }
        pendingDeepLink = link
    }

    func refreshAttendees(for game: Game) async {
        guard authState == .signedIn else { return }

        loadingAttendeeGameIDs.insert(game.id)
        defer { loadingAttendeeGameIDs.remove(game.id) }

        do {
            let previousBookingIDs = Set(attendeesByGameID[game.id]?.map(\.booking.id) ?? [])
            let loaded = try await withAuthRetry {
                try await self.dataProvider.fetchGameAttendees(gameID: game.id)
            }
            attendeesByGameID[game.id] = loaded

            let syncedCheckedInIDs: Set<UUID>
            do {
                syncedCheckedInIDs = try await withAuthRetry {
                    try await self.dataProvider.fetchCheckedInBookingIDs(gameID: game.id)
                }
            } catch {
                // If attendance policy is not available to this user, keep cached check-ins.
                syncedCheckedInIDs = checkedInBookingIDs.intersection(Set(loaded.map(\.booking.id)))
            }

            let currentGameBookingIDs = Set(loaded.map(\.booking.id))
            let removedForThisGame = previousBookingIDs.subtracting(currentGameBookingIDs)
            checkedInBookingIDs.subtract(removedForThisGame)
            checkedInBookingIDs.subtract(previousBookingIDs.intersection(currentGameBookingIDs))
            checkedInBookingIDs.formUnion(syncedCheckedInIDs)
            persistCheckedInBookingIDs()
        } catch {
            bookingsErrorMessage = error.localizedDescription
        }
    }

    func refreshBookings() async {
        guard authState == .signedIn, let userID = authUserID else { return }

        isLoadingBookings = true
        bookingsErrorMessage = nil
        defer { isLoadingBookings = false }

        do {
            let loaded = try await withAuthRetry {
                try await self.dataProvider.fetchUserBookings(userID: userID)
            }
            bookings = loaded.sorted { lhs, rhs in
                let lDate = lhs.game?.dateTime ?? lhs.booking.createdAt ?? .distantFuture
                let rDate = rhs.game?.dateTime ?? rhs.booking.createdAt ?? .distantFuture
                return lDate < rDate
            }
            let activeReminderEligible = Set(
                loaded
                    .filter { $0.booking.state.canCancel }
                    .map(\.booking.gameID)
            )
            scheduleStore.reminderGameIDs = scheduleStore.reminderGameIDs.intersection(activeReminderEligible)
            scheduleStore.persistReminderGameIDs()
        } catch {
            bookingsErrorMessage = error.localizedDescription
        }
    }

    func isRequestingMembership(for club: Club) -> Bool {
        requestingMembershipClubIDs.contains(club.id)
    }

    func isRemovingMembership(for club: Club) -> Bool {
        removingMembershipClubIDs.contains(club.id)
    }

    func ownerJoinRequests(for club: Club) -> [ClubJoinRequest] {
        ownerJoinRequestsByClubID[club.id] ?? []
    }

    func isLoadingOwnerJoinRequests(for club: Club) -> Bool {
        loadingOwnerJoinRequestClubIDs.contains(club.id)
    }

    func isUpdatingOwnerJoinRequest(_ request: ClubJoinRequest) -> Bool {
        ownerMembershipDecisionRequestIDs.contains(request.id)
    }

    func ownerMembers(for club: Club) -> [ClubOwnerMember] {
        ownerMembersByClubID[club.id] ?? []
    }

    func isUpdatingOwnerAdminAccess(for userID: UUID) -> Bool {
        ownerAdminUpdatingUserIDs.contains(userID)
    }

    func isModeratingOwnerMember(_ userID: UUID) -> Bool {
        ownerMemberModerationUserIDs.contains(userID)
    }

    func isLoadingOwnerMembers(for club: Club) -> Bool {
        loadingOwnerMembersClubIDs.contains(club.id)
    }

    func refreshOwnerJoinRequests(for club: Club) async {
        ownerToolsErrorMessage = nil

        loadingOwnerJoinRequestClubIDs.insert(club.id)
        defer { loadingOwnerJoinRequestClubIDs.remove(club.id) }

        do {
            let requests = try await withAuthRetry {
                try await self.dataProvider.fetchPendingClubJoinRequests(clubID: club.id)
            }
            ownerJoinRequestsByClubID[club.id] = requests
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func decideOwnerJoinRequest(_ request: ClubJoinRequest, in club: Club, approve: Bool) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil
        ownerMembershipDecisionRequestIDs.insert(request.id)
        defer { ownerMembershipDecisionRequestIDs.remove(request.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.updateClubJoinRequest(
                    requestID: request.id,
                    status: approve ? "approved" : "rejected",
                    respondedBy: self.authUserID
                )
            }

            ownerJoinRequestsByClubID[club.id] = ownerJoinRequests(for: club).filter { $0.id != request.id }
            membershipInfoMessage = approve ? "Membership approved." : "Membership request rejected."
            ownerToolsInfoMessage = approve ? "\(request.memberName) approved." : "\(request.memberName) rejected."

            // Notify the member of the decision
            let notifTitle = approve ? "Membership Approved" : "Membership Request Declined"
            let notifBody = approve
                ? "Your request to join \(club.name) has been approved. Welcome!"
                : "Your request to join \(club.name) was not approved at this time."
            Task {
                try? await self.dataProvider.triggerNotify(
                    userID: request.userID,
                    title: notifTitle,
                    body: notifBody,
                    type: approve ? "membership_approved" : "membership_rejected",
                    referenceID: club.id,
                    sendPush: true
                )
            }

            await refreshClubs()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func refreshOwnerMembers(for club: Club) async {
        ownerToolsErrorMessage = nil

        loadingOwnerMembersClubIDs.insert(club.id)
        defer { loadingOwnerMembersClubIDs.remove(club.id) }

        do {
            let members = try await withAuthRetry {
                try await self.dataProvider.fetchOwnerClubMembers(clubID: club.id, ownerUserID: club.createdByUserID)
            }
            ownerMembersByClubID[club.id] = members
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func setOwnerMemberAdminAccess(_ member: ClubOwnerMember, in club: Club, makeAdmin: Bool) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard !member.isOwner else {
            ownerToolsErrorMessage = "Owner access cannot be changed here."
            return
        }

        ownerAdminUpdatingUserIDs.insert(member.userID)
        defer { ownerAdminUpdatingUserIDs.remove(member.userID) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.setClubAdminAccess(clubID: club.id, userID: member.userID, makeAdmin: makeAdmin)
            }

            var current = ownerMembers(for: club)
            if let index = current.firstIndex(where: { $0.userID == member.userID }) {
                current[index] = ClubOwnerMember(
                    membershipRecordID: member.membershipRecordID,
                    userID: member.userID,
                    clubID: member.clubID,
                    membershipStatus: member.membershipStatus,
                    memberName: member.memberName,
                    memberEmail: member.memberEmail,
                    memberPhone: member.memberPhone,
                    emergencyContactName: member.emergencyContactName,
                    emergencyContactPhone: member.emergencyContactPhone,
                    isAdmin: makeAdmin,
                    isOwner: member.isOwner,
                    adminRole: makeAdmin ? "admin" : nil
                )
            }
            ownerMembersByClubID[club.id] = current.sorted { lhs, rhs in
                if lhs.isOwner != rhs.isOwner { return lhs.isOwner && !rhs.isOwner }
                if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin && !rhs.isAdmin }
                return lhs.memberName.localizedCaseInsensitiveCompare(rhs.memberName) == .orderedAscending
            }
            ownerToolsInfoMessage = makeAdmin ? "\(member.memberName) is now an admin." : "Admin access removed."
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func removeOwnerMember(_ member: ClubOwnerMember, in club: Club) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil
        guard !member.isOwner else {
            ownerToolsErrorMessage = "Owner account cannot be removed here."
            return
        }

        ownerMemberModerationUserIDs.insert(member.userID)
        defer { ownerMemberModerationUserIDs.remove(member.userID) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.removeMembership(clubID: club.id, userID: member.userID)
            }
            ownerMembersByClubID[club.id] = ownerMembers(for: club).filter { $0.userID != member.userID }
            clubDirectoryMembersByClubID[club.id] = clubDirectoryMembers(for: club).filter { $0.id != member.userID }
            ownerToolsInfoMessage = "\(member.memberName) removed from club."
            Task {
                try? await self.dataProvider.triggerNotify(
                    userID: member.userID,
                    title: "Removed from Club",
                    body: "You have been removed from \(club.name).",
                    type: "membership_removed",
                    referenceID: club.id,
                    sendPush: true
                )
            }
            await refreshClubs()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func blockOwnerMember(_ member: ClubOwnerMember, in club: Club) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil
        guard !member.isOwner else {
            ownerToolsErrorMessage = "Owner account cannot be blocked here."
            return
        }

        ownerMemberModerationUserIDs.insert(member.userID)
        defer { ownerMemberModerationUserIDs.remove(member.userID) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.updateClubJoinRequest(
                    requestID: member.membershipRecordID,
                    status: "rejected",
                    respondedBy: self.authUserID
                )
            }
            // Best effort: remove admin role if present.
            if member.isAdmin {
                try? await withAuthRetry {
                    try await self.dataProvider.setClubAdminAccess(clubID: club.id, userID: member.userID, makeAdmin: false)
                }
            }
            ownerMembersByClubID[club.id] = ownerMembers(for: club).filter { $0.userID != member.userID }
            clubDirectoryMembersByClubID[club.id] = clubDirectoryMembers(for: club).filter { $0.id != member.userID }
            ownerToolsInfoMessage = "\(member.memberName) has been blocked from the club."
            Task {
                try? await self.dataProvider.triggerNotify(
                    userID: member.userID,
                    title: "Removed from Club",
                    body: "Your membership in \(club.name) has been ended by an admin.",
                    type: "membership_removed",
                    referenceID: club.id,
                    sendPush: true
                )
            }
            await refreshClubs()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func ownerSetBookingState(for game: Game, attendee: GameAttendee, targetState: BookingState) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil
        let freedConfirmedSpot = bookingStateIsConfirmed(attendee.booking.state) && bookingStateIsCancelled(targetState)

        ownerBookingUpdatingIDs.insert(attendee.booking.id)
        defer { ownerBookingUpdatingIDs.remove(attendee.booking.id) }

        let statusValue: String
        let waitlistPosition: Int?
        switch targetState {
        case .confirmed:
            statusValue = "confirmed"
            waitlistPosition = nil
        case .cancelled:
            statusValue = "cancelled"
            waitlistPosition = nil
        case .waitlisted:
            statusValue = "waitlisted"
            let maxPosition = gameAttendees(for: game).compactMap { row -> Int? in
                if case let .waitlisted(position) = row.booking.state { return position }
                return nil
            }.max() ?? 0
            waitlistPosition = maxPosition + 1
        case .none, .unknown:
            return
        }

        do {
            let updated = try await withAuthRetry {
                try await self.dataProvider.ownerUpdateBooking(
                    bookingID: attendee.booking.id,
                    status: statusValue,
                    waitlistPosition: waitlistPosition
                )
            }

            if var rows = attendeesByGameID[game.id], let index = rows.firstIndex(where: { $0.booking.id == attendee.booking.id }) {
                rows[index] = GameAttendee(booking: updated, userName: rows[index].userName, userEmail: rows[index].userEmail)
                attendeesByGameID[game.id] = rows
            }
            if let index = bookings.firstIndex(where: { $0.booking.id == attendee.booking.id }) {
                bookings[index] = BookingWithGame(booking: updated, game: bookings[index].game)
            }
            if case .cancelled = targetState {
                checkedInBookingIDs.remove(attendee.booking.id)
                persistCheckedInBookingIDs()
            }

            switch targetState {
            case .confirmed:
                ownerToolsInfoMessage = "\(attendee.userName) moved to confirmed."
            case .waitlisted:
                ownerToolsInfoMessage = "\(attendee.userName) moved to waitlist."
            case .cancelled:
                ownerToolsInfoMessage = "\(attendee.userName)'s booking cancelled."
            case .none, .unknown:
                ownerToolsInfoMessage = "Booking updated."
            }

            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            if freedConfirmedSpot {
                await autoPromoteWaitlistIfPossible(for: game)
            }
            await refreshBookings()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func ownerAddPlayerToGame(_ member: ClubOwnerMember, game: Game) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        do {
            let booking = try await withAuthRetry {
                try await self.dataProvider.createBooking(gameID: game.id, userID: member.userID)
            }
            let attendee = GameAttendee(booking: booking, userName: member.memberName, userEmail: member.memberEmail)
            var rows = attendeesByGameID[game.id] ?? []
            rows.append(attendee)
            attendeesByGameID[game.id] = rows
            ownerToolsInfoMessage = "\(member.memberName) added to the game."
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
        } catch {
            ownerToolsErrorMessage = "Could not add player: \(error.localizedDescription)"
        }
    }

    func toggleCheckIn(for game: Game, attendee: GameAttendee) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard let authUserID else {
            authState = .signedOut
            return
        }

        ownerBookingUpdatingIDs.insert(attendee.booking.id)
        defer { ownerBookingUpdatingIDs.remove(attendee.booking.id) }

        do {
            if checkedInBookingIDs.contains(attendee.booking.id) {
                try await withAuthRetry {
                    try await self.dataProvider.deleteAttendanceCheckIn(bookingID: attendee.booking.id)
                }
                checkedInBookingIDs.remove(attendee.booking.id)
                ownerToolsInfoMessage = "Check-in removed."
            } else {
                try await withAuthRetry {
                    try await self.dataProvider.upsertAttendanceCheckIn(
                        gameID: game.id,
                        bookingID: attendee.booking.id,
                        userID: attendee.booking.userID,
                        checkedInBy: authUserID
                    )
                }
                checkedInBookingIDs.insert(attendee.booking.id)
                ownerToolsInfoMessage = "\(attendee.userName) checked in."
            }
            persistCheckedInBookingIDs()
            await refreshAttendees(for: game)
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func ownerMoveWaitlistAttendee(for game: Game, attendee: GameAttendee, directionUp: Bool) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard case .waitlisted = attendee.booking.state else { return }

        let waitlist = gameAttendees(for: game)
            .filter {
                if case .waitlisted = $0.booking.state { return true }
                return false
            }
            .sorted { lhs, rhs in
                let l = lhs.booking.waitlistPosition ?? Int.max
                let r = rhs.booking.waitlistPosition ?? Int.max
                return l < r
            }

        guard let index = waitlist.firstIndex(where: { $0.booking.id == attendee.booking.id }) else { return }
        let targetIndex = directionUp ? index - 1 : index + 1
        guard waitlist.indices.contains(targetIndex) else { return }

        let current = waitlist[index]
        let target = waitlist[targetIndex]
        let currentPos = current.booking.waitlistPosition ?? (index + 1)
        let targetPos = target.booking.waitlistPosition ?? (targetIndex + 1)

        ownerBookingUpdatingIDs.insert(current.booking.id)
        ownerBookingUpdatingIDs.insert(target.booking.id)
        defer {
            ownerBookingUpdatingIDs.remove(current.booking.id)
            ownerBookingUpdatingIDs.remove(target.booking.id)
        }

        do {
            _ = try await withAuthRetry {
                try await self.dataProvider.ownerUpdateBooking(
                    bookingID: current.booking.id,
                    status: "waitlisted",
                    waitlistPosition: targetPos
                )
            }
            _ = try await withAuthRetry {
                try await self.dataProvider.ownerUpdateBooking(
                    bookingID: target.booking.id,
                    status: "waitlisted",
                    waitlistPosition: currentPos
                )
            }
            ownerToolsInfoMessage = "Waitlist reordered."
            await refreshAttendees(for: game)
            await refreshBookings()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func ownerConfirmAllWaitlist(for game: Game) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        let waitlisted = gameAttendees(for: game).filter {
            if case .waitlisted = $0.booking.state { return true }
            return false
        }
        guard !waitlisted.isEmpty else { return }

        do {
            for attendee in waitlisted {
                _ = try await withAuthRetry {
                    try await self.dataProvider.ownerUpdateBooking(
                        bookingID: attendee.booking.id,
                        status: "confirmed",
                        waitlistPosition: nil
                    )
                }
            }
            ownerToolsInfoMessage = "Confirmed \(waitlisted.count) waitlisted attendee\(waitlisted.count == 1 ? "" : "s")."
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            await refreshBookings()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func ownerClearWaitlist(for game: Game) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        let waitlisted = gameAttendees(for: game).filter {
            if case .waitlisted = $0.booking.state { return true }
            return false
        }
        guard !waitlisted.isEmpty else { return }

        do {
            for attendee in waitlisted {
                _ = try await withAuthRetry {
                    try await self.dataProvider.ownerUpdateBooking(
                        bookingID: attendee.booking.id,
                        status: "cancelled",
                        waitlistPosition: nil
                    )
                }
                checkedInBookingIDs.remove(attendee.booking.id)
            }
            persistCheckedInBookingIDs()
            ownerToolsInfoMessage = "Cleared waitlist."
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            await refreshBookings()
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func createGameForClub(_ club: Club, draft: ClubOwnerGameDraft) async -> Bool {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            ownerToolsErrorMessage = "Game title is required."
            return false
        }

        guard let userID = authUserID else {
            authState = .signedOut
            return false
        }

        let repeatCount = draft.repeatWeekly ? max(draft.repeatCount, 1) : 1

        isCreatingOwnerGame = true
        defer { isCreatingOwnerGame = false }

        do {
            let recurrenceGroupID = repeatCount > 1 ? UUID() : nil
            var createdGames: [Game] = []

            for occurrenceIndex in 0..<repeatCount {
                var instanceDraft = draft
                if occurrenceIndex > 0,
                   let nextDate = Calendar.current.date(byAdding: .day, value: occurrenceIndex * 7, to: draft.startDate) {
                    instanceDraft.startDate = nextDate
                }

                let game = try await withAuthRetry {
                    try await self.dataProvider.createGame(
                        for: club.id,
                        createdBy: userID,
                        draft: instanceDraft,
                        recurrenceGroupID: recurrenceGroupID
                    )
                }
                createdGames.append(game)
            }

            var current = gamesByClubID[club.id] ?? []
            current.append(contentsOf: createdGames)
            current.sort { $0.dateTime < $1.dateTime }
            gamesByClubID[club.id] = current
            ownerToolsInfoMessage = repeatCount > 1 ? "\(repeatCount) weekly games created." : "Game created."
            await refreshGames(for: club)
            return true
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            return false
        }
    }

    func updateGameForClub(_ club: Club, game: Game, draft: ClubOwnerGameDraft, scope: RecurringGameScope = .singleEvent) async -> Bool {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            ownerToolsErrorMessage = "Game title is required."
            return false
        }

        ownerSavingGameIDs.insert(game.id)
        defer { ownerSavingGameIDs.remove(game.id) }

        do {
            let effectiveScope = (game.recurrenceGroupID == nil) ? .singleEvent : scope

            if effectiveScope == .singleEvent {
                let updated = try await withAuthRetry {
                    try await self.dataProvider.updateGame(gameID: game.id, draft: draft)
                }
                if var current = gamesByClubID[club.id], let index = current.firstIndex(where: { $0.id == game.id }) {
                    var merged = updated
                    merged.confirmedCount = current[index].confirmedCount
                    merged.waitlistCount = current[index].waitlistCount
                    current[index] = merged
                    current.sort { $0.dateTime < $1.dateTime }
                    gamesByClubID[club.id] = current
                }
                ownerToolsInfoMessage = "Game updated."
            } else if let recurrenceGroupID = game.recurrenceGroupID {
                let series = try await withAuthRetry {
                    try await self.dataProvider.fetchGamesInSeries(recurrenceGroupID: recurrenceGroupID)
                }
                let targets = series.filter { seriesGame in
                    switch effectiveScope {
                    case .singleEvent:
                        return seriesGame.id == game.id
                    case .thisAndFuture:
                        return seriesGame.dateTime >= game.dateTime
                    case .entireSeries:
                        return true
                    }
                }

                let delta = draft.startDate.timeIntervalSince(game.dateTime)
                for target in targets {
                    var perGameDraft = draft
                    perGameDraft.startDate = target.dateTime.addingTimeInterval(delta)
                    _ = try await withAuthRetry {
                        try await self.dataProvider.updateGame(gameID: target.id, draft: perGameDraft)
                    }
                }
                ownerToolsInfoMessage = effectiveScope == .entireSeries ? "Entire series updated." : "This and future games updated."
            }
            await refreshGames(for: club)
            return true
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteGameForClub(_ club: Club, game: Game, scope: RecurringGameScope = .singleEvent) async -> Bool {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        ownerDeletingGameIDs.insert(game.id)
        defer { ownerDeletingGameIDs.remove(game.id) }

        do {
            let effectiveScope = (game.recurrenceGroupID == nil) ? .singleEvent : scope

            // Notify booked players BEFORE deletion so bookings still exist in the DB
            if effectiveScope == .singleEvent {
                try? await dataProvider.triggerGameCancelledNotify(
                    gameID: game.id,
                    gameTitle: game.title
                )
            }

            if effectiveScope == .singleEvent {
                try await withAuthRetry {
                    try await self.dataProvider.deleteGame(gameID: game.id)
                }
            } else if let recurrenceGroupID = game.recurrenceGroupID {
                let series = try await withAuthRetry {
                    try await self.dataProvider.fetchGamesInSeries(recurrenceGroupID: recurrenceGroupID)
                }
                let targets = series.filter { seriesGame in
                    switch effectiveScope {
                    case .singleEvent:
                        return seriesGame.id == game.id
                    case .thisAndFuture:
                        return seriesGame.dateTime >= game.dateTime
                    case .entireSeries:
                        return true
                    }
                }
                for target in targets {
                    try await withAuthRetry {
                        try await self.dataProvider.deleteGame(gameID: target.id)
                    }
                    attendeesByGameID.removeValue(forKey: target.id)
                    bookings.removeAll { $0.booking.gameID == target.id }
                }
            }
            if var current = gamesByClubID[club.id] {
                switch effectiveScope {
                case .singleEvent:
                    current.removeAll { $0.id == game.id }
                case .thisAndFuture:
                    current.removeAll { $0.recurrenceGroupID == game.recurrenceGroupID && $0.dateTime >= game.dateTime }
                case .entireSeries:
                    current.removeAll { $0.recurrenceGroupID == game.recurrenceGroupID }
                }
                gamesByClubID[club.id] = current
            }
            if effectiveScope == .singleEvent {
                bookings.removeAll { $0.booking.gameID == game.id }
                attendeesByGameID.removeValue(forKey: game.id)
                ownerToolsInfoMessage = "Game deleted."
            } else {
                ownerToolsInfoMessage = effectiveScope == .entireSeries ? "Entire series deleted." : "This and future games deleted."
            }
            return true
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            return false
        }
    }

    func createClub(draft: ClubOwnerEditDraft) async -> Club? {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard authState == .signedIn, let userID = authUserID else {
            ownerToolsErrorMessage = "Sign in to create a club."
            authState = .signedOut
            return nil
        }
        guard let normalizedDraft = normalizedClubDraftForSave(draft) else { return nil }

        isCreatingClub = true
        defer { isCreatingClub = false }
        let startedAt = Date()
        telemetry("create_club_start user_id=\(userID.uuidString)")

        do {
            let created = try await withAuthRetry {
                try await self.dataProvider.createClub(createdBy: userID, draft: normalizedDraft)
            }
            if let index = clubs.firstIndex(where: { $0.id == created.id }) {
                clubs[index] = created
            } else {
                clubs.append(created)
            }
            clubs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            membershipStatesByClubID[created.id] = .unknown("owner")
            ownerToolsInfoMessage = "Club created."
            telemetry("create_club_success club_id=\(created.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt))")
            await refreshClubs()
            await refreshMemberships()
            await refreshClubAdminRole(for: created)
            return created
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            telemetry("create_club_error duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
            return nil
        }
    }

    func updateClubOwnerFields(_ club: Club, draft: ClubOwnerEditDraft) async -> Bool {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard let normalizedDraft = normalizedClubDraftForSave(draft) else { return false }

        isSavingClubOwnerSettings = true
        defer { isSavingClubOwnerSettings = false }
        let startedAt = Date()
        telemetry("owner_update_club_start club_id=\(club.id.uuidString)")

        do {
            let updated = try await withAuthRetry {
                try await self.dataProvider.updateClubOwnerFields(clubID: club.id, draft: normalizedDraft)
            }
            if let index = clubs.firstIndex(where: { $0.id == updated.id }) {
                clubs[index] = updated
            }
            ownerToolsInfoMessage = "Club details updated."
            telemetry("owner_update_club_success club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt))")
            await refreshClubs()
            return true
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            telemetry("owner_update_club_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
            return false
        }
    }

    func deleteClub(_ club: Club) async -> Bool {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard authState == .signedIn, authUserID != nil else {
            ownerToolsErrorMessage = "Sign in to delete a club."
            authState = .signedOut
            return false
        }

        isDeletingClubIDs.insert(club.id)
        defer { isDeletingClubIDs.remove(club.id) }

        let startedAt = Date()
        telemetry("owner_delete_club_start club_id=\(club.id.uuidString)")

        do {
            try await withAuthRetry {
                try await self.dataProvider.deleteClub(clubID: club.id)
            }
            purgeCachedClubState(for: club)
            telemetry("owner_delete_club_success club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt))")
            return true
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            telemetry("owner_delete_club_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
            return false
        }
    }

    private func purgeCachedClubState(for club: Club) {
        // Cancel any active reminders or calendar exports for games in this club
        let clubGames = gamesByClubID[club.id] ?? []
        let clubGameIDs = Set(clubGames.map(\.id))
        for gameID in clubGameIDs {
            if scheduleStore.reminderGameIDs.contains(gameID) {
                LocalNotificationManager.shared.cancelGameReminder(gameID: gameID)
            }
        }
        if !clubGameIDs.isEmpty {
            scheduleStore.reminderGameIDs.subtract(clubGameIDs)
            scheduleStore.persistReminderGameIDs()
            for gameID in clubGameIDs {
                scheduleStore.calendarGameIDs.remove(gameID)
                scheduleStore.calendarEventIDsByGameID.removeValue(forKey: gameID)
            }
            scheduleStore.persistCalendarGameIDs()
            bookings.removeAll { clubGameIDs.contains($0.booking.gameID) }
            attendeesByGameID = attendeesByGameID.filter { !clubGameIDs.contains($0.key) }
        }

        // Remove all club-keyed cached state
        clubs.removeAll { $0.id == club.id }
        gamesByClubID.removeValue(forKey: club.id)
        membershipStatesByClubID.removeValue(forKey: club.id)
        ownerJoinRequestsByClubID.removeValue(forKey: club.id)
        ownerMembersByClubID.removeValue(forKey: club.id)
        clubDirectoryMembersByClubID.removeValue(forKey: club.id)
        clubNewsPostsByClubID.removeValue(forKey: club.id)
        clubNewsReportsByClubID.removeValue(forKey: club.id)
        clubAdminRoleByClubID.removeValue(forKey: club.id)
        loadingClubGameIDs.remove(club.id)
        loadingClubNewsClubIDs.remove(club.id)
        loadingClubDirectoryClubIDs.remove(club.id)
        loadingOwnerJoinRequestClubIDs.remove(club.id)
        loadingOwnerMembersClubIDs.remove(club.id)
        clubGamesErrorByClubID.removeValue(forKey: club.id)
        clubNewsErrorByClubID.removeValue(forKey: club.id)
        clubNewsReportsErrorByClubID.removeValue(forKey: club.id)
        clubDirectoryErrorByClubID.removeValue(forKey: club.id)
        clubNewsPrimedClubIDs.remove(club.id)
        seenClubNewsPostIDsByClubID.removeValue(forKey: club.id)
        seenClubNewsCommentIDsByClubID.removeValue(forKey: club.id)
        stopClubChatRealtime(for: club)
    }

    func requestMembership(for club: Club) async {
        membershipErrorMessage = nil
        membershipInfoMessage = nil
        let currentState = membershipState(for: club)
        guard currentState.isJoinActionEnabled else { return }

        guard let userID = authUserID else {
            authState = .signedOut
            return
        }

        requestingMembershipClubIDs.insert(club.id)
        defer { requestingMembershipClubIDs.remove(club.id) }

        do {
            let status = try await withAuthRetry {
                try await self.dataProvider.requestMembership(clubID: club.id, userID: userID)
            }
            membershipStatesByClubID[club.id] = status
            membershipInfoMessage = (status == .pending) ? "Membership request sent." : "Club membership updated."
            if status == .pending {
                let memberName = profile?.fullName ?? "Someone"
                Task {
                    if let adminIDs = try? await self.dataProvider.fetchClubAdminUserIDs(clubID: club.id) {
                        for adminID in adminIDs {
                            try? await self.dataProvider.triggerNotify(
                                userID: adminID,
                                title: "New Join Request",
                                body: "\(memberName) has requested to join \(club.name).",
                                type: "membership_request_received",
                                referenceID: club.id,
                                sendPush: true
                            )
                        }
                    }
                }
            }
        } catch let serviceError as SupabaseServiceError {
            switch serviceError {
            case .authenticationRequired:
                // Auth is still in preview mode, so keep a local pending UI state.
                membershipStatesByClubID[club.id] = .pending
                membershipInfoMessage = "Membership request created locally. Sign in again if needed."
            case .duplicateMembership:
                membershipStatesByClubID[club.id] = .pending
                membershipInfoMessage = "Membership request already exists."
            default:
                membershipErrorMessage = serviceError.localizedDescription
            }
        } catch {
            membershipErrorMessage = error.localizedDescription
        }
    }

    func removeMembership(for club: Club) async {
        membershipErrorMessage = nil
        membershipInfoMessage = nil

        let currentState = membershipState(for: club)
        guard let userID = authUserID else {
            authState = .signedOut
            return
        }

        switch currentState {
        case .pending, .approved, .unknown:
            break
        case .none, .rejected:
            return
        }

        removingMembershipClubIDs.insert(club.id)
        defer { removingMembershipClubIDs.remove(club.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.removeMembership(clubID: club.id, userID: userID)
            }
            membershipStatesByClubID[club.id] = ClubMembershipState.none
            switch currentState {
            case .pending:
                membershipInfoMessage = "Membership request cancelled."
            case .approved, .unknown:
                membershipInfoMessage = "You left the club."
            case .none, .rejected:
                membershipInfoMessage = nil
            }
        } catch let serviceError as SupabaseServiceError {
            switch serviceError {
            case .authenticationRequired:
                authInfoMessage = "Please sign in again to manage club membership."
            case let .httpStatus(code, _):
                if code == 401 || code == 403 {
                    membershipErrorMessage = "This action is blocked by current club membership permissions (RLS)."
                } else {
                    membershipErrorMessage = serviceError.localizedDescription
                }
            default:
                membershipErrorMessage = serviceError.localizedDescription
            }
        } catch {
            membershipErrorMessage = error.localizedDescription
        }
    }

    func requestBooking(for game: Game) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil
        let currentState = bookingState(for: game)
        guard currentState.canBook else { return }

        guard let userID = authUserID else {
            authState = .signedOut
            return
        }

        if let club = clubs.first(where: { $0.id == game.clubID }) {
            let membership = membershipState(for: club)
            let canBookAsMember: Bool
            switch membership {
            case .approved, .unknown:
                canBookAsMember = true
            case .none, .pending, .rejected:
                canBookAsMember = false
            }

            if !canBookAsMember && !isClubAdmin(for: club) {
                bookingsErrorMessage = membership == .pending
                    ? "Your club join request is still pending. You can book once approved."
                    : "Join the club before booking a game."
                return
            }
        }

        if game.requiresDUPR {
            let currentDUPRID = normalizeDUPRID(duprID ?? "")
            guard !currentDUPRID.isEmpty else {
                bookingsErrorMessage = "Add and confirm your DUPR ID before booking this game."
                return
            }
            guard isLikelyDUPRID(currentDUPRID) else {
                bookingsErrorMessage = "Update your DUPR ID before booking this game."
                return
            }
        }

        requestingBookingGameIDs.insert(game.id)
        defer { requestingBookingGameIDs.remove(game.id) }

        do {
            let created = try await withAuthRetry {
                try await self.dataProvider.createBooking(gameID: game.id, userID: userID)
            }

            if let idx = bookings.firstIndex(where: { $0.booking.gameID == game.id }) {
                let existingGame = bookings[idx].game ?? game
                bookings[idx] = BookingWithGame(booking: created, game: existingGame)
            } else {
                bookings.append(BookingWithGame(booking: created, game: game))
            }
            switch created.state {
            case .waitlisted:
                bookingInfoMessage = "You have been added to the waitlist."
                Task {
                    try? await self.dataProvider.triggerNotify(
                        userID: userID,
                        title: "Added to Waitlist",
                        body: "You're on the waitlist for \(game.title). We'll notify you if a spot opens.",
                        type: "booking_waitlisted",
                        referenceID: game.id,
                        sendPush: false
                    )
                    await self.refreshNotifications()
                }
            case .confirmed:
                bookingInfoMessage = "Booking confirmed."
                Task {
                    try? await self.dataProvider.triggerBookingConfirmedPush(
                        gameID: game.id,
                        bookingID: created.id,
                        userID: userID
                    )
                    try? await self.dataProvider.triggerNotify(
                        userID: userID,
                        title: "Booking Confirmed",
                        body: "You're booked for \(game.title) on \(game.dateTime.formatted(date: .abbreviated, time: .shortened)).",
                        type: "booking_confirmed",
                        referenceID: game.id,
                        sendPush: false
                    )
                    await self.refreshNotifications()
                }
            case .cancelled, .none, .unknown:
                bookingInfoMessage = "Booking updated."
            }

            await refreshBookings()
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
        } catch let serviceError as SupabaseServiceError {
            switch serviceError {
            case .duplicateMembership:
                bookingsErrorMessage = "You already have a booking for this game."
            case .authenticationRequired:
                authInfoMessage = "Please sign in again to book a game."
            default:
                bookingsErrorMessage = serviceError.localizedDescription
            }
        } catch {
            bookingsErrorMessage = error.localizedDescription
        }
    }

    func cancelBooking(for game: Game) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil

        guard bookingState(for: game).canCancel else { return }
        guard let booking = existingBooking(for: game) else { return }

        cancellingBookingIDs.insert(game.id)
        defer { cancellingBookingIDs.remove(game.id) }

        do {
            let cancelled = try await withAuthRetry {
                try await self.dataProvider.cancelBooking(bookingID: booking.id)
            }

            if let idx = bookings.firstIndex(where: { $0.booking.id == booking.id }) {
                let existingGame = bookings[idx].game ?? game
                bookings[idx] = BookingWithGame(booking: cancelled, game: existingGame)
            }

            if scheduleStore.reminderGameIDs.contains(game.id) {
                LocalNotificationManager.shared.cancelGameReminder(gameID: game.id)
                scheduleStore.reminderGameIDs.remove(game.id)
                scheduleStore.persistReminderGameIDs()
            }

            bookingInfoMessage = "Booking cancelled."

            await refreshBookings()
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            await autoPromoteWaitlistIfPossible(for: game)
        } catch let serviceError as SupabaseServiceError {
            switch serviceError {
            case .authenticationRequired:
                authInfoMessage = "Please sign in again to manage bookings."
            default:
                bookingsErrorMessage = serviceError.localizedDescription
            }
        } catch {
            bookingsErrorMessage = error.localizedDescription
        }
    }

    private func autoPromoteWaitlistIfPossible(for game: Game) async {
        guard let club = clubs.first(where: { $0.id == game.clubID }) else { return }
        guard isClubAdmin(for: club) else { return }

        let attendees = gameAttendees(for: game)
        let confirmedCount = attendees.reduce(into: 0) { count, attendee in
            if bookingStateIsConfirmed(attendee.booking.state) { count += 1 }
        }
        let openSlots = max(game.maxSpots - confirmedCount, 0)
        guard openSlots > 0 else { return }

        let waitlisted = attendees
            .filter { bookingStateIsWaitlisted($0.booking.state) }
            .sorted { lhs, rhs in
                let l = lhs.booking.waitlistPosition ?? Int.max
                let r = rhs.booking.waitlistPosition ?? Int.max
                if l == r {
                    return lhs.booking.createdAt ?? .distantFuture < rhs.booking.createdAt ?? .distantFuture
                }
                return l < r
            }

        guard !waitlisted.isEmpty else { return }

        var promotedNames: [String] = []

        for attendee in waitlisted.prefix(openSlots) {
            do {
                let updated = try await withAuthRetry {
                    try await self.dataProvider.ownerUpdateBooking(
                        bookingID: attendee.booking.id,
                        status: "confirmed",
                        waitlistPosition: nil
                    )
                }
                promotedNames.append(attendee.userName)
                if let bookingIndex = bookings.firstIndex(where: { $0.booking.id == attendee.booking.id }) {
                    bookings[bookingIndex] = BookingWithGame(booking: updated, game: bookings[bookingIndex].game)
                }
                let promotedUserID = attendee.booking.userID
                Task {
                    try? await self.dataProvider.triggerNotify(
                        userID: promotedUserID,
                        title: "You're In!",
                        body: "A spot opened up — you've been moved from the waitlist to confirmed for \(game.title).",
                        type: "waitlist_promoted",
                        referenceID: game.id,
                        sendPush: true
                    )
                }
            } catch {
                ownerToolsErrorMessage = error.localizedDescription
                break
            }
        }

        guard !promotedNames.isEmpty else { return }

        if promotedNames.count == 1 {
            ownerToolsInfoMessage = "\(promotedNames[0]) was auto-promoted from the waitlist."
        } else {
            ownerToolsInfoMessage = "Auto-promoted \(promotedNames.count) players from the waitlist."
        }

        await refreshAttendees(for: game)
        await refreshGames(for: club)
        await refreshBookings()
    }

    private func bookingStateIsConfirmed(_ state: BookingState) -> Bool {
        if case .confirmed = state { return true }
        return false
    }

    private func bookingStateIsCancelled(_ state: BookingState) -> Bool {
        if case .cancelled = state { return true }
        return false
    }

    private func bookingStateIsWaitlisted(_ state: BookingState) -> Bool {
        if case .waitlisted = state { return true }
        return false
    }

    func toggleReminder(for game: Game) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil

        guard bookingState(for: game).canCancel else {
            bookingInfoMessage = "Join the game first to enable reminders."
            return
        }

        if scheduleStore.reminderGameIDs.contains(game.id) {
            LocalNotificationManager.shared.cancelGameReminder(gameID: game.id)
            scheduleStore.reminderGameIDs.remove(game.id)
            scheduleStore.persistReminderGameIDs()
            bookingInfoMessage = "Reminder removed."
            return
        }

        do {
            let scheduledDate = try await LocalNotificationManager.shared.scheduleGameReminder(for: game)
            scheduleStore.reminderGameIDs.insert(game.id)
            scheduleStore.persistReminderGameIDs()
            bookingInfoMessage = "Reminder set for \(scheduledDate.formatted(date: .omitted, time: .shortened))."
        } catch {
            bookingInfoMessage = error.localizedDescription
        }
    }

    func addGameToCalendar(for game: Game) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil

        guard bookingState(for: game).canCancel else {
            bookingInfoMessage = "Join the game first to add it to your calendar."
            return
        }

        guard !scheduleStore.calendarGameIDs.contains(game.id) else {
            bookingInfoMessage = "Already added to calendar."
            return
        }

        scheduleStore.exportingCalendarGameIDs.insert(game.id)
        defer { scheduleStore.exportingCalendarGameIDs.remove(game.id) }

        do {
            let clubName = clubs.first(where: { $0.id == game.clubID })?.name
            let eventID = try await LocalCalendarManager.shared.addGameToCalendar(game: game, clubName: clubName)
            scheduleStore.calendarEventIDsByGameID[game.id] = eventID
            scheduleStore.calendarGameIDs.insert(game.id)
            scheduleStore.persistCalendarGameIDs()
            bookingInfoMessage = "Added to your calendar."
        } catch {
            bookingInfoMessage = error.localizedDescription
        }
    }

    func removeGameFromCalendar(for game: Game) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil

        guard scheduleStore.calendarGameIDs.contains(game.id) else {
            bookingInfoMessage = "This game is not in your calendar."
            return
        }

        scheduleStore.exportingCalendarGameIDs.insert(game.id)
        defer { scheduleStore.exportingCalendarGameIDs.remove(game.id) }

        guard let eventID = scheduleStore.calendarEventIDsByGameID[game.id] else {
            // Legacy local state (pre-event-ID persistence) can be cleared even if we can't remove from Calendar.
            scheduleStore.calendarGameIDs.remove(game.id)
            scheduleStore.persistCalendarGameIDs()
            bookingInfoMessage = "Calendar link was reset locally."
            return
        }

        do {
            let removed = try await LocalCalendarManager.shared.removeGameFromCalendar(eventIdentifier: eventID)
            scheduleStore.calendarEventIDsByGameID.removeValue(forKey: game.id)
            scheduleStore.calendarGameIDs.remove(game.id)
            scheduleStore.persistCalendarGameIDs()
            bookingInfoMessage = removed ? "Removed from your calendar." : "Calendar event was already removed."
        } catch {
            bookingInfoMessage = error.localizedDescription
        }
    }

    func toggleCalendarExport(for game: Game) async {
        if hasCalendarExport(for: game) {
            await removeGameFromCalendar(for: game)
        } else {
            await addGameToCalendar(for: game)
        }
    }

    private func applyAuthFlowResult(_ result: AuthFlowResult) {
        switch result {
        case let .signedIn(session):
            authState = .signedIn
            authUserID = session.userID
            authEmail = session.email
            authAccessToken = session.accessToken
            authRefreshToken = session.refreshToken
            dataProvider.setAccessToken(session.accessToken)
            syncCurrentUserDUPRIDFromStore()
            syncCurrentUserDUPRRatingsFromStore()
            persistSession()
        case let .requiresEmailConfirmation(email):
            authState = .signedOut
            authInfoMessage = "Check \(email) to confirm your account, then sign in."
        }
    }

    private func postAuthenticationBootstrap() async {
        await refreshClubs()
        await loadProfileFromBackendIfAvailable()
        await refreshMemberships()
        await refreshBookings()
        await refreshNotifications()
        await prepareClubChatPushNotificationsIfNeeded()
    }

    // MARK: - In-App Notifications

    var unreadNotificationCount: Int {
        notifications.filter { !$0.read }.count
    }

    func refreshNotifications() async {
        guard authState == .signedIn, let userID = authUserID else { return }
        isLoadingNotifications = true
        defer { isLoadingNotifications = false }
        if let fetched = try? await withAuthRetry({ try await self.dataProvider.fetchNotifications(userID: userID) }) {
            notifications = fetched
        }
    }

    func markNotificationRead(_ notification: AppNotification) async {
        guard !notification.read else { return }
        if let idx = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[idx].read = true
        }
        try? await dataProvider.markNotificationRead(id: notification.id)
    }

    func markAllNotificationsRead() async {
        guard let userID = authUserID else { return }
        notifications = notifications.map { var copy = $0; copy.read = true; return copy }
        try? await dataProvider.markAllNotificationsRead(userID: userID)
    }

    private func loadProfileFromBackendIfAvailable() async {
        guard authState == .signedIn, let userID = authUserID else { return }
        do {
            if let fetchedProfile = try await withAuthRetry({
                try await self.dataProvider.fetchProfile(userID: userID)
            }) {
                let trimmedName = fetchedProfile.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { return }
                let currentFavoriteClub = profile?.favoriteClubName
                let currentSkill = profile?.skillLevel ?? .beginner
                profile = UserProfile(
                    id: fetchedProfile.id,
                    fullName: trimmedName,
                    email: fetchedProfile.email,
                    phone: fetchedProfile.phone,
                    dateOfBirth: fetchedProfile.dateOfBirth,
                    emergencyContactName: fetchedProfile.emergencyContactName,
                    emergencyContactPhone: fetchedProfile.emergencyContactPhone,
                    duprRating: fetchedProfile.duprRating,
                    favoriteClubName: currentFavoriteClub,
                    skillLevel: currentSkill,
                    avatarPresetID: profile?.avatarPresetID
                )
                authEmail = fetchedProfile.email
            }
        } catch {
            // Avoid blocking the UI; auth is valid even if profile row is missing.
        }
    }

    func saveProfilePersonalInfo(fullName: String, phone: String?, dateOfBirth: Date?, duprRating: Double?) async {
        guard var current = profile else { return }
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            profileSaveErrorMessage = "Full name is required."
            return
        }
        current.fullName = trimmed
        current.phone = phone
        current.dateOfBirth = dateOfBirth
        current.duprRating = duprRating
        isSavingProfile = true
        profileSaveErrorMessage = nil
        defer { isSavingProfile = false }
        do {
            let updated = try await withAuthRetry { try await self.dataProvider.patchProfile(current) }
            profile = updated
            if let rating = duprRating {
                appendDUPREntry(rating: rating, context: "Manual update")
            }
        } catch {
            profileSaveErrorMessage = AppCopy.friendlyError(error.localizedDescription)
        }
    }

    func saveEmergencyContact(name: String?, phone: String?) async {
        guard var current = profile else { return }
        current.emergencyContactName = name
        current.emergencyContactPhone = phone
        isSavingProfile = true
        profileSaveErrorMessage = nil
        defer { isSavingProfile = false }
        do {
            let updated = try await withAuthRetry { try await self.dataProvider.patchProfile(current) }
            profile = updated
        } catch {
            profileSaveErrorMessage = AppCopy.friendlyError(error.localizedDescription)
        }
    }

    func updatePassword(newPassword: String, confirmPassword: String) async {
        guard newPassword == confirmPassword else {
            passwordUpdateMessage = "Passwords do not match."
            isUpdatingPassword = false
            return
        }
        guard newPassword.count >= 6 else {
            passwordUpdateMessage = "Password must be at least 6 characters."
            return
        }
        isUpdatingPassword = true
        passwordUpdateMessage = nil
        defer { isUpdatingPassword = false }
        do {
            try await withAuthRetry {
                try await self.dataProvider.updatePassword(newPassword)
            }
            passwordUpdateMessage = "Password updated successfully."
        } catch {
            passwordUpdateMessage = AppCopy.friendlyError(error.localizedDescription)
        }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000.0).rounded())
    }

    private func telemetry(_ message: String) {
        telemetryLogger.info("\(message, privacy: .public)")
    }

    private func normalizedClubDraftForSave(_ draft: ClubOwnerEditDraft) -> ClubOwnerEditDraft? {
        var normalizedDraft = draft
        normalizedDraft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedDraft.location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedDraft.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedDraft.contactEmail = draft.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedDraft.website = draft.website.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedDraft.managerName = draft.managerName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedDraft.name.isEmpty else {
            ownerToolsErrorMessage = "Club name is required."
            return nil
        }
        if !normalizedDraft.contactEmail.isEmpty && !isLikelyEmail(normalizedDraft.contactEmail) {
            ownerToolsErrorMessage = "Enter a valid contact email."
            return nil
        }
        if !normalizedDraft.website.isEmpty {
            if !hasHTTPSScheme(normalizedDraft.website) {
                normalizedDraft.website = "https://\(normalizedDraft.website)"
            }
            guard isLikelyWebURL(normalizedDraft.website) else {
                ownerToolsErrorMessage = "Enter a valid website URL."
                return nil
            }
        }

        return normalizedDraft
    }

    private func normalizeDUPRID(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return raw
            .uppercased()
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
    }

    private func isLikelyDUPRID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, trimmed.count <= 24 else { return false }
        guard trimmed.range(of: #"[0-9]"#, options: .regularExpression) != nil else { return false }
        return trimmed.range(of: #"^[A-Z0-9-]+$"#, options: .regularExpression) != nil
    }

    private func isLikelyEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return false }
        guard trimmed.contains("@"), trimmed.contains(".") else { return false }
        return !trimmed.contains(" ")
    }

    private func hasHTTPSScheme(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private func isLikelyWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host else {
            return false
        }
        guard scheme == "http" || scheme == "https" else { return false }
        return host.contains(".")
    }

    private func withAuthRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard shouldAttemptSessionRefresh(for: error) else { throw error }
            let refreshed = await refreshSessionIfPossible(silent: true)
            guard refreshed else { throw error }
            return try await operation()
        }
    }

    private func shouldAttemptSessionRefresh(for error: Error) -> Bool {
        guard let supabaseError = error as? SupabaseServiceError else { return false }
        switch supabaseError {
        case .authenticationRequired, .missingSession:
            return true
        case let .httpStatus(code, _):
            return code == 401 || code == 403
        case .missingConfiguration, .invalidURL, .duplicateMembership, .notFound, .decoding, .network:
            return false
        }
    }

    private func refreshSessionIfPossible(silent: Bool) async -> Bool {
        guard let refreshToken = authRefreshToken, !refreshToken.isEmpty else { return false }
        guard !isRefreshingSession else { return false }

        isRefreshingSession = true
        defer { isRefreshingSession = false }

        do {
            let session = try await dataProvider.refreshSession(refreshToken: refreshToken)
            applyRefreshedSession(session)
            return true
        } catch {
            if !silent {
                authErrorMessage = error.localizedDescription
            }
            if shouldExpireSessionAfterRefreshFailure(error) {
                expireSessionForSignIn()
            }
            return false
        }
    }

    private func applyRefreshedSession(_ session: AuthSessionInfo) {
        authState = .signedIn
        authUserID = session.userID
        authEmail = session.email ?? authEmail
        authAccessToken = session.accessToken
        authRefreshToken = session.refreshToken ?? authRefreshToken
        dataProvider.setAccessToken(session.accessToken)
        syncCurrentUserDUPRIDFromStore()
        syncCurrentUserDUPRRatingsFromStore()
        persistSession()
    }

    private func expireSessionForSignIn() {
        signOut()
        authInfoMessage = "Your session expired. Please sign in again."
    }

    private func shouldExpireSessionAfterRefreshFailure(_ error: Error) -> Bool {
        guard let supabaseError = error as? SupabaseServiceError else { return false }
        switch supabaseError {
        case .authenticationRequired, .missingSession:
            return true
        case let .httpStatus(code, _):
            return code == 400 || code == 401 || code == 403
        case .missingConfiguration, .invalidURL, .duplicateMembership, .notFound, .decoding, .network:
            return false
        }
    }

    private func persistSession() {
        guard
            let userID = authUserID,
            let accessToken = authAccessToken
        else {
            clearPersistedSession()
            return
        }

        let persisted = PersistedAuthSession(
            userID: userID,
            email: authEmail,
            accessToken: accessToken,
            refreshToken: authRefreshToken
        )

        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.authSession)
    }

    private func restorePersistedSession() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.authSession) else { return }
        guard let persisted = try? JSONDecoder().decode(PersistedAuthSession.self, from: data) else {
            clearPersistedSession()
            return
        }

        authState = .signedIn
        authUserID = persisted.userID
        authEmail = persisted.email
        authAccessToken = persisted.accessToken
        authRefreshToken = persisted.refreshToken
        dataProvider.setAccessToken(persisted.accessToken)
        syncCurrentUserDUPRIDFromStore()
        syncCurrentUserDUPRRatingsFromStore()
    }

    private func clearPersistedSession() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.authSession)
    }

    private func persistCheckedInBookingIDs() {
        let ids = checkedInBookingIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(ids, forKey: StorageKeys.checkedInBookingIDs)
    }

    private func restoreCheckedInBookingIDs() {
        guard let rawIDs = UserDefaults.standard.array(forKey: StorageKeys.checkedInBookingIDs) as? [String] else { return }
        checkedInBookingIDs = Set(rawIDs.compactMap(UUID.init(uuidString:)))
    }

    private func persistDUPRIDStore() {
        let rawMap = Dictionary(uniqueKeysWithValues: duprIDByUserID.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(rawMap, forKey: StorageKeys.duprIDByUserID)
    }

    private func restoreDUPRIDStore() {
        guard let rawMap = UserDefaults.standard.dictionary(forKey: StorageKeys.duprIDByUserID) as? [String: String] else {
            duprIDByUserID = [:]
            return
        }
        duprIDByUserID = rawMap.reduce(into: [:]) { partial, entry in
            guard let userID = UUID(uuidString: entry.key) else { return }
            let normalized = normalizeDUPRID(entry.value)
            guard !normalized.isEmpty else { return }
            partial[userID] = normalized
        }
    }

    private func syncCurrentUserDUPRIDFromStore() {
        guard let userID = authUserID else {
            duprID = nil
            return
        }
        duprID = duprIDByUserID[userID]
    }

    private func persistDUPRRatingsStore() {
        // Store as [userIDString: [String: Double]] — "d" for doubles, "s" for singles
        let rawMap: [String: [String: Double]] = duprRatingsByUserID.reduce(into: [:]) { result, entry in
            var inner: [String: Double] = [:]
            if let d = entry.value.doubles { inner["d"] = d }
            if let s = entry.value.singles { inner["s"] = s }
            result[entry.key.uuidString] = inner
        }
        UserDefaults.standard.set(rawMap, forKey: StorageKeys.duprRatingsByUserID)
    }

    private func restoreDUPRRatingsStore() {
        guard let rawMap = UserDefaults.standard.dictionary(forKey: StorageKeys.duprRatingsByUserID) as? [String: [String: Double]] else {
            duprRatingsByUserID = [:]
            return
        }
        duprRatingsByUserID = rawMap.reduce(into: [:]) { partial, entry in
            guard let userID = UUID(uuidString: entry.key) else { return }
            partial[userID] = (doubles: entry.value["d"], singles: entry.value["s"])
        }
    }

    private func syncCurrentUserDUPRRatingsFromStore() {
        guard let userID = authUserID else {
            duprDoublesRating = nil
            duprSinglesRating = nil
            return
        }
        let stored = duprRatingsByUserID[userID]
        duprDoublesRating = stored?.doubles
        duprSinglesRating = stored?.singles
    }

    private func persistClubNewsNotificationPreference() {
        UserDefaults.standard.set(clubNewsNotificationsEnabled, forKey: StorageKeys.clubNewsNotificationsEnabled)
    }

    private func restoreClubNewsNotificationPreference() {
        if UserDefaults.standard.object(forKey: StorageKeys.clubNewsNotificationsEnabled) == nil {
            clubNewsNotificationsEnabled = true
        } else {
            clubNewsNotificationsEnabled = UserDefaults.standard.bool(forKey: StorageKeys.clubNewsNotificationsEnabled)
        }
    }

    func appendDUPREntry(rating: Double, context: String? = nil) {
        guard let userID = authUserID else { return }
        let existing = duprHistoryByUserID[userID, default: []]
        if let last = existing.sorted(by: { $0.recordedAt < $1.recordedAt }).last,
           abs(last.rating - rating) < 0.001 { return }
        let entry = DUPREntry(rating: rating, recordedAt: Date(), context: context)
        duprHistoryByUserID[userID, default: []].append(entry)
        duprHistory = duprHistoryByUserID[userID, default: []].sorted { $0.recordedAt < $1.recordedAt }
        persistDUPRHistoryStore()
    }

    private func persistDUPRHistoryStore() {
        let encodable = duprHistoryByUserID.reduce(into: [String: [DUPREntry]]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.duprHistoryByUserID)
    }

    private func restoreDUPRHistoryStore() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.duprHistoryByUserID),
              let decoded = try? JSONDecoder().decode([String: [DUPREntry]].self, from: data) else {
            duprHistoryByUserID = [:]
            return
        }
        duprHistoryByUserID = decoded.reduce(into: [:]) { result, entry in
            guard let uuid = UUID(uuidString: entry.key) else { return }
            result[uuid] = entry.value
        }
    }

    private func syncDUPRHistoryToCurrentUser() {
        guard let userID = authUserID else { duprHistory = []; return }
        duprHistory = duprHistoryByUserID[userID, default: []].sorted { $0.recordedAt < $1.recordedAt }
    }

    private func loadNotificationSettings(_ center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { (continuation: CheckedContinuation<UNNotificationSettings, Never>) in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestNotificationAuthorization(_ center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func handleClubNewsNotificationsIfNeeded(club: Club, previousPosts: [ClubNewsPost], newPosts: [ClubNewsPost]) async {
        guard clubNewsNotificationsEnabled else {
            seenClubNewsPostIDsByClubID[club.id] = Set(newPosts.map(\.id))
            seenClubNewsCommentIDsByClubID[club.id] = Set(newPosts.flatMap { $0.comments.map(\.id) })
            clubNewsPrimedClubIDs.insert(club.id)
            return
        }
        let oldPostIDs = seenClubNewsPostIDsByClubID[club.id] ?? Set(previousPosts.map(\.id))
        let oldCommentIDs = seenClubNewsCommentIDsByClubID[club.id] ?? Set(previousPosts.flatMap { $0.comments.map(\.id) })

        let newPostIDs = Set(newPosts.map(\.id))
        let newCommentIDs = Set(newPosts.flatMap { $0.comments.map(\.id) })

        defer {
            seenClubNewsPostIDsByClubID[club.id] = newPostIDs
            seenClubNewsCommentIDsByClubID[club.id] = newCommentIDs
            clubNewsPrimedClubIDs.insert(club.id)
        }

        guard clubNewsPrimedClubIDs.contains(club.id) else { return }
        guard let currentUserID = authUserID else { return }

        let newPostsByOthers = newPosts.filter { !oldPostIDs.contains($0.id) && $0.userID != currentUserID }
        for post in newPostsByOthers.prefix(2) {
            await LocalNotificationManager.shared.scheduleClubNewsActivityNotification(
                id: "post.\(post.id.uuidString)",
                title: "\(club.name): New Post",
                body: "\(post.authorName): \(post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Shared a photo" : post.content)"
            )
        }

        // Reply/comment notifications for posts authored by current user.
        let myPostIDs = Set(newPosts.filter { $0.userID == currentUserID }.map(\.id))
        if !myPostIDs.isEmpty {
            let newCommentsOnMyPosts = newPosts
                .flatMap(\.comments)
                .filter { myPostIDs.contains($0.postID) && !oldCommentIDs.contains($0.id) && $0.userID != currentUserID }

            for comment in newCommentsOnMyPosts.prefix(2) {
                await LocalNotificationManager.shared.scheduleClubNewsActivityNotification(
                    id: "reply.\(comment.id.uuidString)",
                    title: "\(club.name): New Reply",
                    body: "\(comment.authorName) replied: \(comment.content)"
                )
            }
        }
    }
}

enum AuthState {
    case signedOut
    case signedIn
}

private struct PersistedAuthSession: Codable {
    let userID: UUID
    let email: String?
    let accessToken: String
    let refreshToken: String?
}
