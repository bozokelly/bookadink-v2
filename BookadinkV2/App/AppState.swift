import Combine
import Foundation
import os
import UIKit
import UserNotifications

/// The result of a successful cancellation credit issued to a user.
/// Published by `cancelBooking` when the server confirms a credit was issued.
struct CancellationCreditResult: Equatable {
    let clubID: UUID
    let clubName: String?
    let creditedCents: Int
    let newBalanceCents: Int
}

/// Routes that may be pushed onto the Clubs-tab `NavigationStack`.
/// Identity is the model UUID — never the resolved value — so duplicate pushes
/// of the same Game / Club collapse via `AppState.navigate(to:)` idempotency.
enum AppRoute: Hashable {
    case club(UUID)
    case game(UUID)
}

@MainActor
final class AppState: ObservableObject {
    private enum StorageKeys {
        static let noShowBookingIDs = "bookadink.owner.noShowBookingIDs"
        static let authSession = "bookadink.auth.session"
        static let checkedInBookingIDs = "bookadink.owner.checkedInBookingIDs"
        static let clubNewsNotificationsEnabled = "bookadink.clubNews.notificationsEnabled"
        static let duprIDByUserID = "bookadink.profile.duprIDByUserID"
        static let duprRatingsByUserID = "bookadink.profile.duprRatingsByUserID"
        static let duprHistoryByUserID = "bookadink.profile.duprHistoryByUserID"
        static let pinnedClubIDs = "bookadink.home.pinnedClubIDs"
    }

    private let dataProvider: ClubDataProviding
    private let telemetryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BookadinkV2", category: "ClubTelemetry")

    /// Reminder and calendar-export state lives here to limit re-render scope.
    /// Inject as a separate @EnvironmentObject so only views that need it re-render.
    let scheduleStore = GameScheduleStore()

    @Published var pendingDeepLink: DeepLink? = nil
    /// Currently selected tab. Lifted from `MainTabView` so `navigate(to:)`
    /// can switch tabs from any context (e.g. tapping a club chip from
    /// `GameDetailView` while presented inside the Bookings tab stack).
    @Published var selectedTab: AppTab = .home
    /// Single source of truth for the Clubs-tab `NavigationStack` path.
    /// Mutated only via `navigate(to:)` so push de-duplication is centralised.
    @Published var clubsNavPath: [AppRoute] = []
    @Published var authState: AuthState = .signedOut
    @Published var authUserID: UUID? = nil
    @Published var authEmail: String? = nil
    @Published var authAccessToken: String? = nil
    @Published var authRefreshToken: String? = nil
    @Published var profile: UserProfile? = nil
    @Published var clubs: [Club] = MockData.clubs
    @Published var gamesByClubID: [UUID: [Game]] = [:]
    /// All active upcoming games within the next 14 days, fetched at bootstrap.
    /// Powers the "Games Near You" home section and NearbyGamesView.
    @Published var allUpcomingGames: [Game] = []
    @Published var bookings: [BookingWithGame] = []
    @Published var attendeesByGameID: [UUID: [GameAttendee]] = [:]
    @Published var pinnedClubIDs: [UUID] = []
    @Published var membershipStatesByClubID: [UUID: ClubMembershipState] = [:]
    @Published var ownerJoinRequestsByClubID: [UUID: [ClubJoinRequest]] = [:]
    @Published var ownerMembersByClubID: [UUID: [ClubOwnerMember]] = [:]
    @Published var clubDirectoryMembersByClubID: [UUID: [ClubDirectoryMember]] = [:]
    @Published var clubNewsPostsByClubID: [UUID: [ClubNewsPost]] = [:]
    @Published var clubNewsReportsByClubID: [UUID: [ClubNewsModerationReport]] = [:]
    @Published var clubAdminRoleByClubID: [UUID: ClubAdminRole] = [:]
    @Published var roleHistoryByClubID: [UUID: [ClubRoleAuditEntry]] = [:]
    @Published var loadingRoleHistoryClubIDs: Set<UUID> = []
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
    @Published var cancellingGameIDs: Set<UUID> = []
    @Published var loadingAttendeeGameIDs: Set<UUID> = []
    @Published var ownerBookingUpdatingIDs: Set<UUID> = []
    @Published var ownerSavingGameIDs: Set<UUID> = []
    @Published var ownerDeletingGameIDs: Set<UUID> = []
    @Published var isDeletingClubIDs: Set<UUID> = []
    @Published var reviewsByClubID: [UUID: [GameReview]] = [:]
    @Published var loadingReviewsClubIDs: Set<UUID> = []
    @Published var pendingReviewPrompt: PendingReviewPrompt? = nil
    @Published var revenueSummaryByClubID: [UUID: ClubRevenueSummary] = [:]
    @Published var loadingRevenueSummaryClubIDs: Set<UUID> = []
    @Published var fillRateSummaryByClubID: [UUID: ClubFillRateSummary] = [:]
    @Published var loadingFillRateSummaryClubIDs: Set<UUID> = []

    // Dashboard summary — lightweight metrics, all plan tiers
    @Published var dashboardSummaryByClubID: [UUID: ClubDashboardSummary] = [:]

    // Phase 5B — Advanced Analytics
    @Published var analyticsKPIsByClubID: [UUID: ClubAnalyticsKPIs] = [:]
    @Published var analyticsSupplementalByClubID: [UUID: ClubAnalyticsSupplemental] = [:]
    @Published var revenueTrendByClubID: [UUID: [ClubRevenueTrendPoint]] = [:]
    @Published var topGamesByClubID: [UUID: [ClubTopGame]] = [:]
    @Published var peakTimesByClubID: [UUID: [ClubPeakTime]] = [:]
    @Published var loadingAnalyticsClubIDs: Set<UUID> = []
    /// Last analytics fetch error per club. Nil when last fetch succeeded or hasn't run yet.
    @Published var analyticsErrorByClubID: [UUID: String] = [:]
    @Published var clubVenuesByClubID: [UUID: [ClubVenue]] = [:]
    @Published var loadingClubVenueIDs: Set<UUID> = []
    @Published var savingClubVenueIDs: Set<UUID> = []
    @Published var deletingClubVenueIDs: Set<UUID> = []
    // reminderGameIDs, calendarGameIDs, exportingCalendarGameIDs live on scheduleStore.
    @Published var checkedInBookingIDs: Set<UUID> = []       // attendance_status = 'attended'
    @Published var noShowBookingIDs: Set<UUID> = []           // attendance_status = 'no_show'
    /// Maps bookingID → payment_status ("unpaid" | "cash" | "stripe") for attendance rows.
    @Published var attendancePaymentByBookingID: [UUID: String] = [:]
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
    // Stripe Connect
    @Published var isCreatingConnectOnboarding = false
    @Published var connectOnboardingError: String? = nil
    /// Cached Stripe account status keyed by club ID. Views observe this to re-render after refresh.
    /// Absent key means not yet fetched or no account created. Non-nil value = account exists.
    @Published var stripeAccountByClubID: [UUID: ClubStripeAccount] = [:]
    /// Set when the app returns from Stripe onboarding so the onboarding view can react immediately.
    @Published var pendingConnectReturnClubID: UUID? = nil
    /// "complete" or "refresh" (link expired). Valid only while pendingConnectReturnClubID is non-nil.
    @Published var pendingConnectReturnStatus: String = "complete"
    // Club Subscriptions (Phase 4)
    @Published var subscriptionsByClubID: [UUID: ClubSubscription] = [:]
    @Published var entitlementsByClubID: [UUID: ClubEntitlements] = [:]
    /// Canonical plan tier limit definitions fetched from get_plan_tier_limits() at launch.
    /// Keyed by plan tier string ("free", "starter", "pro"). Empty until first successful fetch.
    @Published var planTierLimits: [String: PlanTierLimits] = [:]
    /// Server-authoritative subscription plan catalogue from get_subscription_plans().
    /// Contains Stripe price IDs and display prices. Empty until first successful fetch.
    /// Clients must never hardcode these values — use subscriptionPriceID(for:) and
    /// subscriptionDisplayPrice(for:) helpers instead.
    @Published var subscriptionPlans: [SubscriptionPlan] = []
    /// Server-authoritative runtime config from app_config table.
    /// nil = not yet loaded. Features that depend on config values must check for nil.
    @Published var gameReminderOffsetMinutes: Int? = nil
    @Published var isCreatingSubscription = false
    @Published var subscriptionError: String? = nil
    // Credits (Phase 2) — club-scoped: keyed by club UUID
    @Published var creditBalanceByClubID: [UUID: Int] = [:]
    @Published var lastCancellationCredit: CancellationCreditResult? = nil
    /// Set to the club UUID whenever a booking is confirmed (Stripe or credits or free).
    /// Analytics views observe this to refresh after a player books into a game.
    @Published var lastConfirmedBookingClubID: UUID? = nil
    /// Set to the club UUID whenever an attendance record is created, updated, or deleted.
    /// Analytics views observe this to refresh no-show counts after check-in changes.
    @Published var lastAttendanceUpdateClubID: UUID? = nil
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
    /// Per-game admin feedback messages. Keyed by game ID so messages from one game
    /// never appear in another game's view. Club-scoped actions use the global above.
    @Published var gameOwnerInfoByID: [UUID: String] = [:]
    @Published var gameOwnerErrorByID: [UUID: String] = [:]
    @Published var isSavingClubOwnerSettings = false
    @Published var isCreatingClub = false
    @Published var isCreatingOwnerGame = false
    @Published var isInitialBootstrapComplete = false
    @Published var isPerformingPostSignInBootstrap = false
    @Published var duprID: String? = nil
    @Published var duprDoublesRating: Double? = nil
    @Published var mutedClubChatIDs: Set<UUID> = []
    @Published var notificationPreferences: NotificationPreferences = .init()
    @Published var remotePushTokenHex: String? = nil
    @Published var remotePushRegistrationErrorMessage: String? = nil
    private var clubNewsPrimedClubIDs: Set<UUID> = []
    private var seenClubNewsPostIDsByClubID: [UUID: Set<UUID>] = [:]
    private var seenClubNewsCommentIDsByClubID: [UUID: Set<UUID>] = [:]
    private var hasAttemptedRemotePushRegistrationThisLaunch = false
    private var clubChatRealtimeClients: [UUID: SupabaseClubChatRealtimeClient] = [:]
    private var clubChatRealtimeRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var duprIDByUserID: [UUID: String] = [:]
    private var duprRatingsByUserID: [UUID: Double?] = [:]

    func duprDoublesRating(for userID: UUID) -> Double? {
        duprRatingsByUserID[userID] ?? nil
    }
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
        // Attendance state (checkedInBookingIDs / noShowBookingIDs) is intentionally NOT
        // restored from UserDefaults here. DB is the source of truth; state is synced
        // from fetchAttendanceRecords on every refreshAttendees call. Restoring stale
        // UserDefaults attendance would show incorrect state before the first DB sync,
        // breaking multi-device consistency when two staff devices share a game.
        restoreClubNewsNotificationPreference()
        restorePinnedClubIDs()

        Task {
            if authState == .signedIn {
                _ = await refreshSessionIfPossible(silent: true)
            }
            // Load palette definitions, plan limits, subscription plans, and app config concurrently.
            async let palettes: Void = loadAvatarPalettes()
            async let clubs: Void = refreshClubs()
            async let tierLimits: Void = fetchPlanTierLimits()
            async let subPlans: Void = fetchSubscriptionPlans()
            async let appCfg: Void = fetchAppConfig()
            _ = await (palettes, clubs, tierLimits, subPlans, appCfg)
            if authState == .signedIn {
                await loadProfileFromBackendIfAvailable()
                await loadNotificationPreferencesIfNeeded()
                await refreshBookings(silent: true)
                await refreshUpcomingGames()
                await fetchPendingReviewPrompt()
                // Session restore (cached auth) skips the sign-in/sign-up bootstrap that
                // normally triggers APNs registration — re-fire here so iPad / second
                // devices always have a push_tokens row after a relaunch.
                await ensureRemotePushRegistrationIfAuthorized()
                await flushPendingPushTokenIfNeeded()
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
        gamesByClubID = [:]
        allUpcomingGames = []
        bookings = []
        attendeesByGameID = [:]
        membershipStatesByClubID = [:]
        ownerJoinRequestsByClubID = [:]
        ownerMembersByClubID = [:]
        clubDirectoryMembersByClubID = [:]
        clubNewsPostsByClubID = [:]
        clubNewsReportsByClubID = [:]
        clubAdminRoleByClubID = [:]
        roleHistoryByClubID = [:]
        loadingRoleHistoryClubIDs = []
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
        cancellingGameIDs = []
        ownerSavingGameIDs = []
        ownerDeletingGameIDs = []
        loadingAttendeeGameIDs = []
        ownerBookingUpdatingIDs = []
        scheduleStore.clearAll()
        checkedInBookingIDs = []
        noShowBookingIDs = []
        authErrorMessage = nil
        authInfoMessage = nil
        profileSaveErrorMessage = nil
        bookingsErrorMessage = nil
        bookingInfoMessage = nil
        membershipInfoMessage = nil
        membershipErrorMessage = nil
        ownerToolsInfoMessage = nil
        ownerToolsErrorMessage = nil
        gameOwnerInfoByID = [:]
        gameOwnerErrorByID = [:]
        isCreatingClub = false
        clubNewsErrorByClubID = [:]
        clubNewsReportsErrorByClubID = [:]
        clubDirectoryErrorByClubID = [:]
        notifications = []
        pendingReviewPrompt = nil
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

    func completeProfile(firstName: String, lastName: String, homeClub: String?, skillLevel: SkillLevel) async {
        let userID = authUserID ?? UUID()
        authUserID = userID
        syncCurrentUserDUPRIDFromStore()
        syncCurrentUserDUPRRatingsFromStore()

        let draft = UserProfile(
            id: userID,
            firstName: firstName,
            lastName: lastName,
            fullName: "\(firstName) \(lastName)",
            email: authEmail ?? "preview@bookadink.app",
            favoriteClubName: homeClub,
            skillLevel: skillLevel,
            avatarColorKey: nil
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
            // Only show the preview-data banner if we don't already have live clubs loaded.
            // A failed re-fetch should not wipe out the live indicator set by a previous
            // successful fetch.
            if !isUsingLiveClubData {
                clubsLoadErrorMessage = error.localizedDescription
            }
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

        // Always refresh admin roles alongside memberships so promotions are reflected immediately.
        do {
            let roles = try await withAuthRetry {
                try await self.dataProvider.fetchAllAdminRoles(userID: userID)
            }
            clubAdminRoleByClubID = roles
        } catch {
            // Non-fatal; existing local admin role state is kept.
        }
    }

    func refreshProfile() async {
        await loadProfileFromBackendIfAvailable()
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
        guard let role = clubAdminRoleByClubID[club.id] else { return false }
        return role == .owner || role == .admin
    }

    // MARK: - Pinned Clubs

    func isClubPinned(_ club: Club) -> Bool {
        pinnedClubIDs.contains(club.id)
    }

    /// Toggles the pin state for a club. Enforces a maximum of 3 pinned clubs.
    /// Returns false if the pin was rejected due to the cap being reached.
    @discardableResult
    func togglePinClub(_ club: Club) -> Bool {
        if let idx = pinnedClubIDs.firstIndex(of: club.id) {
            pinnedClubIDs.remove(at: idx)
        } else {
            guard pinnedClubIDs.count < 3 else { return false }
            pinnedClubIDs.append(club.id)
        }
        persistPinnedClubIDs()
        return true
    }

    private func persistPinnedClubIDs() {
        UserDefaults.standard.set(pinnedClubIDs.map(\.uuidString), forKey: StorageKeys.pinnedClubIDs)
    }

    func restorePinnedClubIDs() {
        guard let raw = UserDefaults.standard.array(forKey: StorageKeys.pinnedClubIDs) as? [String] else { return }
        pinnedClubIDs = raw.compactMap(UUID.init(uuidString:))
    }

    /// True only for the club owner — not regular admins.
    /// Owners can promote/demote admins and remove any member.
    /// Admins can only manage regular (non-admin) members.
    func isClubOwner(for club: Club) -> Bool {
        if club.createdByUserID == authUserID { return true }
        guard let role = clubAdminRoleByClubID[club.id] else { return false }
        return role == .owner
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

    func isCancellingGame(_ game: Game) -> Bool {
        cancellingGameIDs.contains(game.id)
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

    func isNoShow(bookingID: UUID) -> Bool {
        noShowBookingIDs.contains(bookingID)
    }

    /// Returns 'attended', 'no_show', or 'unmarked'.
    func attendanceStatus(bookingID: UUID) -> String {
        if checkedInBookingIDs.contains(bookingID) { return "attended" }
        if noShowBookingIDs.contains(bookingID) { return "no_show" }
        return "unmarked"
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
        // Persist to Supabase so book_game() server gate can enforce DUPR requirements.
        // DB constraint rejects values outside ^[A-Z0-9-]+$ or without a digit —
        // surface the error so the caller knows the value was not persisted server-side.
        Task {
            do {
                try await dataProvider.patchDuprID(userID: userID, duprID: normalized)
            } catch {
                await MainActor.run {
                    profileSaveErrorMessage = "DUPR ID saved locally but couldn't sync to server: \(AppCopy.friendlyError(error.localizedDescription))"
                }
            }
        }
        return nil
    }

    /// Saves the DUPR rating for the current user. Returns an error string on failure, nil on success.
    /// Callers must validate exactly 3 decimal places at the text-input layer before invoking this.
    func saveDUPRRatings(doubles: Double?, singles: Double? = nil) -> String? {
        guard let userID = authUserID else { return "Sign in to save your DUPR rating." }
        if let d = doubles, (d < 2.0 || d > 8.0) { return "DUPR rating must be between 2.000 and 8.000." }
        duprRatingsByUserID[userID] = doubles
        duprDoublesRating = doubles
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
            mergeIntoAllUpcomingGames(loaded, forClubID: club.id)
            telemetry("refresh_games_success club_id=\(club.id.uuidString) count=\(loaded.count) duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            clubGamesErrorByClubID[club.id] = error.localizedDescription
            telemetry("refresh_games_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }
    }

    /// Fetches all active games within the next 14 days across all clubs and
    /// populates `allUpcomingGames`. Non-critical — failures are silent.
    func refreshUpcomingGames() async {
        guard authState == .signedIn else { return }
        do {
            let games = try await withAuthRetry {
                try await self.dataProvider.fetchUpcomingGames()
            }
            allUpcomingGames = games
            let clubCount = Set(games.map(\.clubID)).count
            print("[NearbyGames] Loaded \(games.count) games across \(clubCount) clubs")
            // Log each game so we can verify Supabase returned coordinates.
            for g in games {
                let coordStatus: String
                if g.latitude != nil {
                    coordStatus = "game-coords"
                } else if clubs.first(where: { $0.id == g.clubID })?.latitude != nil {
                    coordStatus = "club-coords"
                } else {
                    coordStatus = "no-coords"
                }
                print("[NearbyGames]   · \(g.title) club=\(g.clubID.uuidString.prefix(8)) \(coordStatus)")
            }

            // Prefetch venues for any club whose upcoming games reference a specific
            // venue by name. This ensures distance calculations can use the actual
            // game venue coordinates rather than the club's base address.
            let clubIDsNeedingVenues = Set(games.filter { $0.venueName != nil }.map(\.clubID))
                .subtracting(Set(clubVenuesByClubID.keys))
            for club in clubs.filter({ clubIDsNeedingVenues.contains($0.id) }) {
                Task { await refreshVenues(for: club) }
            }
        } catch {
            // Non-critical: the home section stays empty or keeps stale data on error.
            print("[NearbyGames] Failed to load upcoming games: \(error.localizedDescription)")
        }
    }

    /// Merges freshly-loaded per-club games into `allUpcomingGames`,
    /// replacing any stale entries for that club.
    private func mergeIntoAllUpcomingGames(_ loaded: [Game], forClubID clubID: UUID) {
        let now = Date()
        let windowEnd = now.addingTimeInterval(14 * 24 * 3_600)
        let fresh = loaded.filter {
            $0.dateTime >= now && $0.dateTime <= windowEnd && $0.status == "upcoming"
            && ($0.publishAt == nil || $0.publishAt! <= now)
        }
        allUpcomingGames.removeAll { $0.clubID == clubID }
        allUpcomingGames.append(contentsOf: fresh)
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
                case .error:
                    // Realtime subscription errors are transient — the client auto-reconnects
                    // after 3 seconds. Do not surface them as a blocking UI error banner;
                    // the user would see a spurious "something went wrong" on every reconnect.
                    break
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
        // Cancel any in-flight debounce and reschedule — avoids dropping rapid realtime events
        clubChatRealtimeRefreshTasks[club.id]?.cancel()
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
            telemetry("refresh_admin_role_success club_id=\(club.id.uuidString) role=\(role?.rawValue ?? "none") duration_ms=\(elapsedMilliseconds(since: startedAt))")
        } catch {
            // Non-fatal; owner check still works.
            telemetry("refresh_admin_role_error club_id=\(club.id.uuidString) duration_ms=\(elapsedMilliseconds(since: startedAt)) message=\(error.localizedDescription)")
        }
    }

    func uploadClubAvatarImage(_ data: Data, clubID: UUID) async throws -> URL {
        try await dataProvider.uploadClubAvatarImage(data, clubID: clubID)
    }

    func uploadClubBannerImage(_ data: Data, clubID: UUID) async throws -> URL {
        try await dataProvider.uploadClubBannerImage(data, clubID: clubID)
    }

    /// Deletes a club avatar or banner image from Supabase storage.
    /// Only acts on URLs that belong to our managed bucket; silently skips all others.
    /// Fire-and-forget safe — errors are swallowed and logged.
    func deleteClubStorageImageIfManaged(_ url: URL?) async {
        guard let url else { return }
        do {
            try await dataProvider.deleteClubStorageImage(at: url)
        } catch {
            telemetry("deleteClubStorageImage failed url=\(url.absoluteString) error=\(error.localizedDescription)")
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

            let createdPostID = try await withAuthRetry {
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
                    postID: createdPostID ?? club.id,
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
                        referenceID: createdPostID,
                        postAuthorID: nil,
                        content: trimmed
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

    // Mutates a single post in the local cache without a network round-trip.
    private func updatePostLocally(clubID: UUID, postID: UUID, update: (inout ClubNewsPost) -> Void) {
        guard var posts = clubNewsPostsByClubID[clubID],
              let idx = posts.firstIndex(where: { $0.id == postID }) else { return }
        update(&posts[idx])
        clubNewsPostsByClubID[clubID] = posts
    }

    func toggleClubNewsLike(for club: Club, post: ClubNewsPost) async {
        clubNewsErrorByClubID[club.id] = nil
        guard let authUserID else {
            authState = .signedOut
            return
        }

        // Optimistic flip — instant UI response, no full refresh needed
        let wasLiked = post.isLikedByCurrentUser
        updatePostLocally(clubID: club.id, postID: post.id) { p in
            p.isLikedByCurrentUser = !wasLiked
            p.likeCount = max(0, p.likeCount + (wasLiked ? -1 : 1))
        }

        updatingClubNewsPostIDs.insert(post.id)
        defer { updatingClubNewsPostIDs.remove(post.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.toggleClubNewsLike(postID: post.id, userID: authUserID)
            }
            // No full refresh — realtime will reconcile any edge-case discrepancy
        } catch {
            // Revert optimistic change on failure
            updatePostLocally(clubID: club.id, postID: post.id) { p in
                p.isLikedByCurrentUser = wasLiked
                p.likeCount = max(0, p.likeCount + (wasLiked ? 1 : -1))
            }
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

        // Optimistic insert — comment appears immediately with a temp UUID
        let tempComment = ClubNewsComment(
            id: UUID(),
            postID: post.id,
            userID: authUserID,
            authorName: profile?.fullName ?? "You",
            avatarColorKey: profile?.avatarColorKey,
            content: trimmed,
            createdAt: Date(),
            parentID: parentCommentID
        )
        updatePostLocally(clubID: club.id, postID: post.id) { p in
            p.comments.append(tempComment)
        }

        do {
            let createdCommentID = try await withAuthRetry {
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
                    event: "comment_on_post",
                    referenceID: createdCommentID,
                    postAuthorID: post.userID,
                    content: trimmed
                )
            }
            // Background refresh replaces the temp comment with the real server row
            Task { await self.refreshClubNews(for: club) }
        } catch {
            // Revert optimistic insert
            updatePostLocally(clubID: club.id, postID: post.id) { p in
                p.comments.removeAll { $0.id == tempComment.id }
            }
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

    func isClubChatMuted(for clubID: UUID) -> Bool {
        mutedClubChatIDs.contains(clubID)
    }

    func setClubChatMuted(_ muted: Bool, for clubID: UUID) {
        if muted {
            mutedClubChatIDs.insert(clubID)
        } else {
            mutedClubChatIDs.remove(clubID)
            Task { await prepareClubChatPushNotificationsIfNeeded() }
        }
        // Clear any stale error so re-renders triggered by the @Published mutedClubChatIDs
        // change don't resurface an old error banner.
        clubNewsErrorByClubID[clubID] = nil
        persistClubNewsNotificationPreference()
    }

    func prepareClubChatPushNotificationsIfNeeded() async {
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

    /// Idempotent re-registration for APNs. Does NOT prompt the user — only fires
    /// `registerForRemoteNotifications` when authorization is already granted. Safe
    /// to call from session-restore and every foreground without affecting permission UX.
    func ensureRemotePushRegistrationIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        let settings = await loadNotificationSettings(center)
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            let idiom: String = await MainActor.run {
                UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            }
            let userIDStr = authUserID?.uuidString ?? "<no-auth>"
            print("[push] register fire idiom=\(idiom) user=\(userIDStr) status=\(settings.authorizationStatus.rawValue)")
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        default:
            break
        }
    }

    func handleRemotePushDeviceToken(_ tokenHex: String) {
        remotePushRegistrationErrorMessage = nil
        remotePushTokenHex = tokenHex

        let summary = AppState.tokenSummary(tokenHex)
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

        guard let authUserID else {
            print("[push] token received idiom=\(idiom) token=\(summary) — deferred (no auth yet)")
            return
        }

        print("[push] token received idiom=\(idiom) user=\(authUserID.uuidString) token=\(summary)")

        Task {
            do {
                try await withAuthRetry {
                    try await self.dataProvider.updateProfilePushToken(userID: authUserID, pushToken: tokenHex)
                }
                print("[push] upload ok idiom=\(idiom) user=\(authUserID.uuidString) token=\(summary)")
            } catch {
                // 409 = token already stored (push_tokens has no unique constraint yet, upsert
                // sees a conflict). The token IS registered — not an error worth surfacing.
                if case let SupabaseServiceError.httpStatus(code, _) = error, code == 409 {
                    print("[push] upload 409 idiom=\(idiom) user=\(authUserID.uuidString) token=\(summary) (already stored)")
                    return
                }
                print("[push] upload FAIL idiom=\(idiom) user=\(authUserID.uuidString) token=\(summary) error=\(error)")
                // Other failures are non-fatal (local notifications still work) but worth showing
                // so the user knows push alerts may not arrive.
                await MainActor.run {
                    self.remotePushRegistrationErrorMessage = AppCopy.friendlyError(error.localizedDescription)
                }
            }
        }
    }

    private static func tokenSummary(_ token: String) -> String {
        guard !token.isEmpty else { return "<empty>" }
        if token.count <= 8 { return "\(token.prefix(4))…\(token.suffix(2))" }
        return "\(token.prefix(6))…\(token.suffix(4))"
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
        // Stripe Connect return — signal the onboarding view and refresh status.
        // Don't set pendingDeepLink since there's nothing to navigate to.
        if case .connectReturn(let clubID, let status) = link {
            pendingConnectReturnStatus = status
            pendingConnectReturnClubID = clubID
            Task { await refreshStripeAccountStatus(for: clubID) }
            return
        }
        pendingDeepLink = link
    }

    /// Idempotent push onto the Clubs-tab navigation stack.
    ///
    /// - Tapping the current top route is a no-op.
    /// - Tapping a route already in the stack pops back to it (instead of
    ///   pushing a duplicate). This prevents Game ↔ Club ping-pong loops.
    /// - Otherwise the route is appended.
    ///
    /// Always switches to the Clubs tab so callers from other tabs (e.g. a
    /// club chip tapped inside a Bookings-tab `GameDetailView`) land where
    /// the path actually lives.
    func navigate(to route: AppRoute) {
        if selectedTab != .clubs {
            selectedTab = .clubs
        }
        if clubsNavPath.last == route {
            return
        }
        if let existingIndex = clubsNavPath.firstIndex(of: route) {
            let removeCount = clubsNavPath.count - existingIndex - 1
            if removeCount > 0 {
                clubsNavPath.removeLast(removeCount)
            }
            return
        }
        clubsNavPath.append(route)
    }

    /// Composes the structured booking-confirmed notification body used by both
    /// the in-app row and the push (the Edge Function builds an identical
    /// version on the server — these need to stay in sync).
    ///
    ///     {Game Title}
    ///     {Day}, {D MMM} · {h:mm a} ({Duration})
    ///     📍 {Venue Name}
    ///
    /// `static` so it can be reused without an instance and unit-tested in
    /// isolation. AU locale matches the rest of the app.
    static func buildBookingConfirmedBody(
        gameTitle: String,
        dateTime: Date,
        durationMinutes: Int,
        venue: String
    ) -> String {
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_AU")
        dayFmt.dateFormat = "EEEE"
        let day = dayFmt.string(from: dateTime)

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_AU")
        dateFmt.dateFormat = "d MMM"
        let date = dateFmt.string(from: dateTime)

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_AU")
        timeFmt.dateFormat = "h:mm a"
        let time = timeFmt.string(from: dateTime).lowercased()

        let duration: String
        if durationMinutes < 60 {
            duration = "\(durationMinutes)m"
        } else {
            let h = durationMinutes / 60
            let m = durationMinutes % 60
            duration = m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }

        var lines: [String] = [gameTitle]
        lines.append("\(day), \(date) · \(time) (\(duration))")
        let trimmedVenue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVenue.isEmpty {
            lines.append("📍 \(trimmedVenue)")
        }
        return lines.joined(separator: "\n")
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

            let syncedRecords: AttendanceRecords
            do {
                syncedRecords = try await withAuthRetry {
                    try await self.dataProvider.fetchAttendanceRecords(gameID: game.id)
                }
            } catch {
                // If attendance policy is not available to this user, keep cached state.
                let loadedBookingIDs = Set(loaded.map(\.booking.id))
                let cachedAttended = checkedInBookingIDs.intersection(loadedBookingIDs)
                let cachedNoShow   = noShowBookingIDs.intersection(loadedBookingIDs)
                var statusMap: [UUID: String] = [:]
                for id in cachedAttended { statusMap[id] = "attended" }
                for id in cachedNoShow   { statusMap[id] = "no_show" }
                let paymentMap = Dictionary(uniqueKeysWithValues: cachedAttended.map { ($0, attendancePaymentByBookingID[$0] ?? "unpaid") })
                syncedRecords = AttendanceRecords(attendanceStatusByBookingID: statusMap, paymentByBookingID: paymentMap)
            }

            let currentGameBookingIDs = Set(loaded.map(\.booking.id))
            let removedForThisGame    = previousBookingIDs.subtracting(currentGameBookingIDs)

            // Clear stale entries for removed and previously-known bookings in this game
            checkedInBookingIDs.subtract(removedForThisGame)
            noShowBookingIDs.subtract(removedForThisGame)
            checkedInBookingIDs.subtract(previousBookingIDs.intersection(currentGameBookingIDs))
            noShowBookingIDs.subtract(previousBookingIDs.intersection(currentGameBookingIDs))

            // Apply synced attendance state
            for (bookingID, status) in syncedRecords.attendanceStatusByBookingID {
                if status == "attended"  { checkedInBookingIDs.insert(bookingID) }
                else if status == "no_show" { noShowBookingIDs.insert(bookingID) }
            }

            // Update payment statuses
            for id in removedForThisGame { attendancePaymentByBookingID.removeValue(forKey: id) }
            for (bookingID, status) in syncedRecords.paymentByBookingID { attendancePaymentByBookingID[bookingID] = status }
            persistCheckedInBookingIDs()
        } catch {
            bookingsErrorMessage = error.localizedDescription
        }
    }

    func refreshBookings(silent: Bool = false) async {
        guard authState == .signedIn, let userID = authUserID else { return }

        isLoadingBookings = true
        if !silent { bookingsErrorMessage = nil }
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
            // Silent failures don't surface to the user — only user-initiated refreshes show errors
            if !silent { bookingsErrorMessage = error.localizedDescription }
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
        guard isClubOwner(for: club) else {
            ownerToolsErrorMessage = "Only the club owner can change admin access."
            return
        }

        ownerAdminUpdatingUserIDs.insert(member.userID)
        defer { ownerAdminUpdatingUserIDs.remove(member.userID) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.setClubAdminAccess(clubID: club.id, userID: member.userID, makeAdmin: makeAdmin)
            }

            // Re-fetch from server. The mutation may have changed the demoted/promoted user's
            // own role cache (clubAdminRoleByClubID) on this device, and the member list snapshot
            // (ownerMembersByClubID) needs the authoritative server state — never trust an
            // optimistic rewrite for role changes since stale cache silently lies in 15+ UI sites.
            await refreshClubAdminRole(for: club)
            await refreshOwnerMembers(for: club)

            ownerToolsInfoMessage = makeAdmin ? "\(member.memberName) is now an admin." : "Admin access removed."
            // Push + in-app notification for the affected user is fanned out
            // server-side by the trg_enqueue_role_change_push trigger on
            // club_role_audit (migration 20260504030000). Do NOT add a
            // client-side triggerNotify here — it would duplicate the push.
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    /// Atomically transfers club ownership to another approved member via the
    /// transfer_club_ownership RPC. Server validates caller=current owner,
    /// updates clubs.created_by, upserts new owner club_admins row, and demotes
    /// the old owner to `oldOwnerNewRole` ("admin" or "member"), all under a
    /// clubs row lock. After success: refreshes club list (so the local
    /// isClubOwner check flips on this device) and reloads admin role + member
    /// list to bust stale caches.
    func transferClubOwnership(in club: Club, newOwnerID: UUID, oldOwnerNewRole: String) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard isClubOwner(for: club) else {
            ownerToolsErrorMessage = "Only the club owner can transfer ownership."
            return
        }
        guard let callerID = authUserID, newOwnerID != callerID else {
            ownerToolsErrorMessage = "Pick a different member to transfer to."
            return
        }
        guard oldOwnerNewRole == "admin" || oldOwnerNewRole == "member" else {
            ownerToolsErrorMessage = "Invalid role for the outgoing owner."
            return
        }

        ownerAdminUpdatingUserIDs.insert(newOwnerID)
        defer { ownerAdminUpdatingUserIDs.remove(newOwnerID) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.transferClubOwnership(
                    clubID: club.id,
                    newOwnerID: newOwnerID,
                    oldOwnerNewRole: oldOwnerNewRole
                )
            }

            await refreshClubs()
            await refreshClubAdminRole(for: club)
            await refreshOwnerMembers(for: club)

            ownerToolsInfoMessage = "Club ownership transferred."
            // Push + in-app notification for both the new owner ('transferred_in')
            // and the outgoing owner ('transferred_out_to_admin'/'_member') is
            // fanned out server-side by trg_enqueue_role_change_push on
            // club_role_audit (migration 20260504030000). Do NOT add a
            // client-side triggerNotify here.
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    /// Fetches recent role-change audit rows for the club via the
    /// get_club_role_history RPC. Owner/admin only (server-enforced).
    /// Result is stored in `roleHistoryByClubID[club.id]` and surfaced via
    /// `roleHistory(for:)`. Failures populate `ownerToolsErrorMessage`.
    func refreshClubRoleHistory(for club: Club, limit: Int = 100) async {
        loadingRoleHistoryClubIDs.insert(club.id)
        defer { loadingRoleHistoryClubIDs.remove(club.id) }

        do {
            let entries = try await withAuthRetry {
                try await self.dataProvider.fetchClubRoleHistory(clubID: club.id, limit: limit)
            }
            roleHistoryByClubID[club.id] = entries
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    func roleHistory(for club: Club) -> [ClubRoleAuditEntry] {
        roleHistoryByClubID[club.id] ?? []
    }

    func isLoadingRoleHistory(for club: Club) -> Bool {
        loadingRoleHistoryClubIDs.contains(club.id)
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

    func createPaymentIntent(amountCents: Int, currency: String, clubID: UUID?, metadata: [String: String]) async throws -> PaymentIntentResult {
        try await withAuthRetry {
            try await self.dataProvider.createPaymentIntent(
                amountCents: amountCents,
                currency: currency,
                clubID: clubID,
                metadata: metadata
            )
        }
    }

    // MARK: - Credits (Phase 2)

    /// Returns the credit balance for the given club (0 if none).
    func creditBalance(for clubID: UUID) -> Int {
        creditBalanceByClubID[clubID] ?? 0
    }

    /// Fetches the latest credit balance from the DB for a specific club and updates `creditBalanceByClubID`.
    func refreshCreditBalance(for clubID: UUID) async {
        guard let userID = authUserID else { return }
        do {
            let balance = try await withAuthRetry {
                try await self.dataProvider.fetchCreditBalance(userID: userID, clubID: clubID)
            }
            await MainActor.run { self.creditBalanceByClubID[clubID] = balance }
        } catch {
            // Non-critical — swallow silently; balance shows as 0
        }
    }

    /// Calculates how many cents of credit to apply to a game booking and the
    /// remaining amount the player must pay via Stripe.
    /// - Parameters:
    ///   - amountCents: The full game fee in cents.
    ///   - clubID: The club whose credit balance to draw from.
    ///   - applyCredits: When `false`, skips credit lookup and returns the full amount (toggle off).
    /// - Returns: `(creditsToApply, remainingCents)` where `remainingCents` is the Stripe charge amount.
    func creditOffset(for amountCents: Int, clubID: UUID, applyCredits: Bool = true) async -> (creditsToApply: Int, remainingCents: Int) {
        guard applyCredits else { return (0, amountCents) }
        let balance = creditBalance(for: clubID)
        let creditsToApply = min(balance, amountCents)
        let remaining = amountCents - creditsToApply
        return (creditsToApply, remaining)
    }

    // MARK: - Confirm pending payment (Phase 3)

    /// Transitions a `pending_payment` booking to `confirmed` after successful payment.
    /// Used for promoted waitlist players completing their held spot.
    func confirmPendingBooking(bookingID: UUID, stripePaymentIntentID: String?, platformFeeCents: Int?, clubPayoutCents: Int?, creditsAppliedCents: Int?, clubID: UUID) async {
        // Client-side fast-fail: catch expired holds before hitting the server.
        // The server enforces this too (hold_expires_at > now() filter), but
        // failing locally avoids a wasted network round trip and gives instant feedback.
        if let holdExp = bookings.first(where: { $0.booking.id == bookingID })?.booking.holdExpiresAt,
           holdExp <= Date() {
            bookingsErrorMessage = SupabaseServiceError.holdExpired.errorDescription
            await refreshBookings(silent: false)
            return
        }

        do {
            let updated = try await withAuthRetry {
                try await self.dataProvider.confirmPendingBooking(
                    bookingID: bookingID,
                    stripePaymentIntentID: stripePaymentIntentID,
                    platformFeeCents: platformFeeCents,
                    clubPayoutCents: clubPayoutCents,
                    creditsAppliedCents: creditsAppliedCents
                )
            }
            // Update local cache
            if let idx = bookings.firstIndex(where: { $0.booking.id == bookingID }) {
                let existingGame = bookings[idx].game
                bookings[idx] = BookingWithGame(booking: updated, game: existingGame)
            }
            // Deduct credits if applied (same pattern as requestBooking)
            if let credits = creditsAppliedCents, credits > 0, let userID = authUserID {
                let cid = clubID
                // Optimistic update: reflect the deduction immediately in the UI.
                creditBalanceByClubID[cid] = max(0, (creditBalanceByClubID[cid] ?? 0) - credits)
                Task {
                    _ = try? await self.dataProvider.applyCredits(
                        userID: userID,
                        bookingID: bookingID,
                        amountCents: credits,
                        clubID: cid
                    )
                    // Confirm with authoritative DB value.
                    await self.refreshCreditBalance(for: cid)
                }
            }
            await refreshBookings(silent: true)
            // Refresh attendees + game spot count so the player list and fill bar update immediately.
            if let bookingWithGame = bookings.first(where: { $0.booking.id == bookingID }),
               let game = bookingWithGame.game {
                await refreshAttendees(for: game)
                if let club = clubs.first(where: { $0.id == game.clubID }) {
                    await refreshGames(for: club)
                }
            }
        } catch SupabaseServiceError.holdExpired {
            // Hold expired between client check and server PATCH — refresh to show correct state.
            bookingsErrorMessage = SupabaseServiceError.holdExpired.errorDescription
            await refreshBookings(silent: false)
        } catch {
            bookingsErrorMessage = "Could not confirm booking: \(error.localizedDescription)"
        }
    }

    /// Creates a PaymentIntent on demand for a deferred payment scenario (e.g. waitlist promotion).
    /// Call this when the player actively returns to the app and chooses to complete payment.
    /// Does NOT insert a booking — that is handled by the caller after PaymentSheet completion.
    func createDeferredPaymentIntent(for game: Game) async throws -> PaymentIntentResult {
        let amountCents = Int(((game.feeAmount ?? 0) * 100).rounded())
        let (_, remaining) = await creditOffset(for: amountCents, clubID: game.clubID)

        return try await withAuthRetry {
            try await self.dataProvider.createPaymentIntent(
                amountCents: remaining,
                currency: "aud",
                clubID: game.clubID,
                metadata: ["game_id": game.id.uuidString, "game_title": game.title, "deferred": "true"]
            )
        }
    }

    func fetchClubStripeAccount(for clubID: UUID) async throws -> ClubStripeAccount? {
        try await withAuthRetry {
            try await self.dataProvider.fetchClubStripeAccount(clubID: clubID)
        }
    }

    func createConnectOnboarding(for club: Club) async -> String? {
        isCreatingConnectOnboarding = true
        connectOnboardingError = nil
        defer { isCreatingConnectOnboarding = false }
        do {
            let returnURL = "bookadink://connect-return"
            return try await withAuthRetry {
                try await self.dataProvider.createConnectOnboarding(
                    clubID: club.id,
                    returnURL: returnURL
                )
            }
        } catch {
            connectOnboardingError = error.localizedDescription
            return nil
        }
    }

    /// Fetches the live Stripe account state from the backend and caches it in `stripeAccountByClubID`.
    /// Called on return from Stripe onboarding (via deep link) and on explicit user "Check Status" taps.
    func refreshStripeAccountStatus(for clubID: UUID) async {
        do {
            let account = try await withAuthRetry {
                try await self.dataProvider.refreshStripeAccountStatus(clubID: clubID)
            }
            await MainActor.run {
                if let account {
                    stripeAccountByClubID[clubID] = account
                } else {
                    stripeAccountByClubID.removeValue(forKey: clubID)
                }
            }
        } catch {
            // Non-fatal — fall back to a direct DB read so we still show something
            let account = try? await withAuthRetry {
                try await self.dataProvider.fetchClubStripeAccount(clubID: clubID)
            }
            await MainActor.run {
                if let account {
                    stripeAccountByClubID[clubID] = account
                }
            }
        }
    }

    // MARK: - Club Subscriptions (Phase 4)

    func fetchClubSubscription(for clubID: UUID) async {
        do {
            let sub = try await withAuthRetry {
                try await self.dataProvider.fetchClubSubscription(clubID: clubID)
            }
            await MainActor.run {
                if let sub { subscriptionsByClubID[clubID] = sub }
                else { subscriptionsByClubID.removeValue(forKey: clubID) }
            }
        } catch {
            // Non-fatal: subscription is just not shown
        }
    }

    /// Fetches entitlements for a club and stores them in entitlementsByClubID.
    ///
    /// On error or missing row, the dict is left unchanged — a missing entry is treated
    /// as fully blocked by FeatureGateService (deny by default). No silent access on failure.
    func fetchClubEntitlements(for clubID: UUID) async {
        do {
            let entitlements = try await withAuthRetry {
                try await self.dataProvider.fetchClubEntitlements(clubID: clubID)
            }
            await MainActor.run {
                if let entitlements {
                    entitlementsByClubID[clubID] = entitlements
                }
                // Intentional: nil result (no row found) does not update the dict.
                // entitlementsByClubID[clubID] == nil → FeatureGateService returns .blocked.
            }
        } catch {
            // Intentional: fetch errors do not update the dict.
            // Keeps paid features locked if connectivity is lost mid-session.
        }
    }

    /// Fetches canonical plan tier limits from get_plan_tier_limits() and caches them.
    /// Called once at bootstrap. Silently no-ops on error — UI falls back to inline defaults.
    func fetchPlanTierLimits() async {
        do {
            let limits = try await withAuthRetry {
                try await self.dataProvider.fetchPlanTierLimits()
            }
            await MainActor.run {
                planTierLimits = limits
            }
        } catch {
            // Silent: paywall falls back to hardcoded fallback strings if this fails.
        }
    }

    /// Fetches active subscription plan definitions from get_subscription_plans() and caches them.
    /// Called once at bootstrap. On error subscriptionPlans remains empty — paywalls show
    /// a loading state and disable the subscribe button until plans arrive.
    func fetchSubscriptionPlans() async {
        do {
            let plans = try await withAuthRetry {
                try await self.dataProvider.fetchSubscriptionPlans()
            }
            await MainActor.run {
                subscriptionPlans = plans
            }
        } catch {
            // subscriptionPlans stays empty; paywall disables subscribe buttons.
        }
    }

    /// Returns the Stripe price ID for the given plan ID, or nil if plans haven't loaded yet.
    func subscriptionPriceID(for planID: String) -> String? {
        subscriptionPlans.first(where: { $0.planID == planID })?.stripePriceID
    }

    /// Returns the display price string for the given plan ID, or nil if plans haven't loaded.
    func subscriptionDisplayPrice(for planID: String) -> String? {
        subscriptionPlans.first(where: { $0.planID == planID })?.displayPrice
    }

    /// Fetches server-authoritative runtime config from the app_config table.
    /// Called once at bootstrap. Sets gameReminderOffsetMinutes from the DB value.
    /// On error gameReminderOffsetMinutes remains nil — callers must handle the nil case.
    func fetchAppConfig() async {
        do {
            let config = try await withAuthRetry {
                try await self.dataProvider.fetchAppConfig()
            }
            await MainActor.run {
                if let raw = config["game_reminder_offset_minutes"], let minutes = Int(raw), minutes > 0 {
                    gameReminderOffsetMinutes = minutes
                }
            }
        } catch {
            // gameReminderOffsetMinutes stays nil; caller surfaces the nil case to the user.
        }
    }

    func createClubSubscription(for club: Club, priceID: String) async -> ClubSubscriptionResult? {
        isCreatingSubscription = true
        subscriptionError = nil
        defer { isCreatingSubscription = false }
        do {
            let result = try await withAuthRetry {
                try await self.dataProvider.createClubSubscription(clubID: club.id, priceID: priceID)
            }
            // Refresh local subscription cache
            await fetchClubSubscription(for: club.id)
            // For the upgrade path the Edge Function derives entitlements synchronously
            // before returning, so the DB row is already correct — fetch it now so the
            // UI unlocks without waiting for any caller to do a second round-trip.
            if result.status == "active" {
                await fetchClubEntitlements(for: club.id)
            }
            return result
        } catch {
            subscriptionError = error.localizedDescription
            return nil
        }
    }

    func cancelClubSubscription(for club: Club) async {
        subscriptionError = nil
        do {
            try await withAuthRetry {
                try await self.dataProvider.cancelClubSubscription(clubID: club.id)
            }
            // Refresh both caches so the UI immediately shows "cancels at period end"
            // and entitlements remain at the paid tier until the period ends.
            await fetchClubSubscription(for: club.id)
            await fetchClubEntitlements(for: club.id)
        } catch {
            subscriptionError = error.localizedDescription
        }
    }

    func adminUpdateMemberDUPR(_ member: ClubOwnerMember, rating: Double) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil
        do {
            try await withAuthRetry {
                try await self.dataProvider.adminUpdateMemberDUPR(memberUserID: member.userID, rating: rating)
            }
            // Update in-memory cache so the attendee list and directory reflect
            // the new value immediately without a full refresh.
            duprRatingsByUserID[member.userID] = rating
            persistDUPRRatingsStore()
            ownerToolsInfoMessage = "DUPR updated to \(String(format: "%.3f", rating)) for \(member.memberName)."
        } catch {
            ownerToolsErrorMessage = "Failed to update DUPR: \(error.localizedDescription)"
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
        gameOwnerErrorByID.removeValue(forKey: game.id)
        gameOwnerInfoByID.removeValue(forKey: game.id)
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
        case .none, .unknown, .pendingPayment:
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
                rows[index] = GameAttendee(booking: updated, userName: rows[index].userName, userEmail: rows[index].userEmail, duprRating: rows[index].duprRating, avatarColorKey: rows[index].avatarColorKey)
                attendeesByGameID[game.id] = rows
            }
            if let index = bookings.firstIndex(where: { $0.booking.id == attendee.booking.id }) {
                bookings[index] = BookingWithGame(booking: updated, game: bookings[index].game)
            }
            if case .cancelled = targetState {
                checkedInBookingIDs.remove(attendee.booking.id)
                noShowBookingIDs.remove(attendee.booking.id)
                persistCheckedInBookingIDs()

                // Notify the cancelled player so their device refreshes immediately
                // (the trigger-based waitlist push only reaches the *promoted* user).
                // Skip when an admin cancels their own booking — they already updated locally.
                let cancelledUserID = attendee.booking.userID
                if cancelledUserID != authUserID {
                    let gameTitle = game.title
                    let gameID = game.id
                    Task {
                        try? await self.dataProvider.triggerNotify(
                            userID: cancelledUserID,
                            title: "Booking Cancelled",
                            body: "An admin removed you from \(gameTitle).",
                            type: "booking_cancelled",
                            referenceID: gameID,
                            sendPush: true
                        )
                    }
                }
            }

            switch targetState {
            case .confirmed:
                gameOwnerInfoByID[game.id] = "\(attendee.userName) moved to confirmed."
            case .waitlisted:
                gameOwnerInfoByID[game.id] = "\(attendee.userName) moved to waitlist."
            case .cancelled:
                gameOwnerInfoByID[game.id] = "\(attendee.userName)'s booking cancelled."
            case .none, .unknown, .pendingPayment:
                gameOwnerInfoByID[game.id] = "Booking updated."
            }

            // Snapshot waitlist before refresh (for DB-trigger promotion detection)
            let preWaitlistedIDs: Set<UUID> = freedConfirmedSpot ? Set(
                (attendeesByGameID[game.id] ?? [])
                    .filter { bookingStateIsWaitlisted($0.booking.state) }
                    .map { $0.booking.userID }
            ) : []

            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            if freedConfirmedSpot {
                // Server is authoritative on waitlist promotion: the
                // promote_top_waitlisted DB trigger fires on confirmed→cancelled
                // and promotes one waitlister atomically (paid → pending_payment
                // with a hold; free → confirmed). Push goes out via the
                // promote-top-waitlisted-push Edge Function. The client never
                // promotes — see CLAUDE.md "Waitlist & Hold System".
                await notifyWaitlistPromoted(for: game, previouslyWaitlisted: preWaitlistedIDs)
            }
            await refreshBookings(silent: true)
        } catch {
            gameOwnerErrorByID[game.id] = error.localizedDescription
        }
    }

    func ownerAddPlayerToGame(_ member: ClubOwnerMember, game: Game) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)
        gameOwnerInfoByID.removeValue(forKey: game.id)

        do {
            // Server (owner_create_booking RPC) decides confirmed vs waitlisted
            // under a games-row FOR UPDATE lock — the same invariant book_game()
            // uses (confirmed + pending_payment <= max_spots). The status/position
            // returned in the booking record is authoritative.
            let booking = try await withAuthRetry {
                try await self.dataProvider.ownerCreateBooking(
                    gameID: game.id,
                    userID: member.userID,
                    status: "confirmed",      // ignored by RPC; kept for signature compat
                    waitlistPosition: nil      // ignored by RPC; kept for signature compat
                )
            }
            let attendee = GameAttendee(booking: booking, userName: member.memberName, userEmail: member.memberEmail, duprRating: nil, avatarColorKey: member.avatarColorKey)
            var rows = attendeesByGameID[game.id] ?? []
            rows.append(attendee)
            attendeesByGameID[game.id] = rows

            // Use the server-returned state, not a pre-call client estimate.
            let placedOnWaitlist: Bool = {
                if case .waitlisted = booking.state { return true }
                return false
            }()
            gameOwnerInfoByID[game.id] = placedOnWaitlist
                ? "\(member.memberName) added to the waitlist (game is full)."
                : "\(member.memberName) added to the game."

            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
        } catch let error as SupabaseServiceError {
            if case let .httpStatus(code, _) = error, code == 409 {
                gameOwnerErrorByID[game.id] = "This player already has an active booking for this game."
            } else {
                gameOwnerErrorByID[game.id] = "Could not add player: \(error.localizedDescription)"
            }
        } catch {
            gameOwnerErrorByID[game.id] = "Could not add player: \(error.localizedDescription)"
        }
    }

    /// Sets attendance for a player. status: 'attended' | 'no_show' | nil (removes record = unmarked).
    /// Optimistic: local state updates immediately. Backend saves in background. Reverts on failure.
    func setAttendance(for game: Game, attendee: GameAttendee, status: String?) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)
        gameOwnerInfoByID.removeValue(forKey: game.id)

        guard let authUserID else {
            authState = .signedOut
            return
        }

        // Capture previous state for rollback
        let wasAttended = checkedInBookingIDs.contains(attendee.booking.id)
        let wasNoShow   = noShowBookingIDs.contains(attendee.booking.id)

        // Optimistic update — row changes immediately before network call
        checkedInBookingIDs.remove(attendee.booking.id)
        noShowBookingIDs.remove(attendee.booking.id)
        switch status {
        case "attended":  checkedInBookingIDs.insert(attendee.booking.id)
        case "no_show":   noShowBookingIDs.insert(attendee.booking.id)
        default:          break  // nil = remove row (unmarked)
        }
        persistCheckedInBookingIDs()

        ownerBookingUpdatingIDs.insert(attendee.booking.id)
        defer { ownerBookingUpdatingIDs.remove(attendee.booking.id) }

        do {
            if let status {
                try await withAuthRetry {
                    try await self.dataProvider.upsertAttendance(
                        gameID: game.id,
                        bookingID: attendee.booking.id,
                        userID: attendee.booking.userID,
                        checkedInBy: authUserID,
                        status: status
                    )
                }
                lastAttendanceUpdateClubID = game.clubID
                switch status {
                case "attended":  gameOwnerInfoByID[game.id] = "\(attendee.userName) marked attended."
                case "no_show":   gameOwnerInfoByID[game.id] = "\(attendee.userName) marked no show."
                default:          break
                }
            } else {
                try await withAuthRetry {
                    try await self.dataProvider.deleteAttendanceCheckIn(bookingID: attendee.booking.id)
                }
                lastAttendanceUpdateClubID = game.clubID
                gameOwnerInfoByID[game.id] = "Attendance removed."
            }
        } catch {
            // Revert optimistic update on failure
            checkedInBookingIDs.remove(attendee.booking.id)
            noShowBookingIDs.remove(attendee.booking.id)
            if wasAttended { checkedInBookingIDs.insert(attendee.booking.id) }
            if wasNoShow   { noShowBookingIDs.insert(attendee.booking.id) }
            persistCheckedInBookingIDs()
            gameOwnerErrorByID[game.id] = "Could not update attendance."
            return
        }
        // Reconcile from DB after the write so any DB-side side effects (triggers,
        // concurrent admin updates) are reflected without requiring a manual refresh.
        await refreshAttendees(for: game)
    }

    func paymentStatus(for bookingID: UUID) -> String {
        attendancePaymentByBookingID[bookingID] ?? "unpaid"
    }

    func updatePaymentStatus(for game: Game, attendee: GameAttendee, status: String) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)

        ownerBookingUpdatingIDs.insert(attendee.booking.id)
        defer { ownerBookingUpdatingIDs.remove(attendee.booking.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.updateAttendancePaymentStatus(
                    bookingID: attendee.booking.id,
                    status: status
                )
            }
            attendancePaymentByBookingID[attendee.booking.id] = status
        } catch {
            gameOwnerErrorByID[game.id] = "Could not update payment: \(error.localizedDescription)"
            return
        }
        await refreshAttendees(for: game)
    }

    /// Updates the `payment_method` (and `fee_paid`) on a booking record for upcoming games.
    /// Stripe-paid bookings must never be passed here — enforced at the call site.
    func updateBookingPaymentMethod(for game: Game, attendee: GameAttendee, method: String) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)

        ownerBookingUpdatingIDs.insert(attendee.booking.id)
        defer { ownerBookingUpdatingIDs.remove(attendee.booking.id) }

        do {
            let updated = try await withAuthRetry {
                try await self.dataProvider.updateBookingPaymentMethod(
                    bookingID: attendee.booking.id,
                    paymentMethod: method
                )
            }
            if var rows = attendeesByGameID[game.id],
               let idx = rows.firstIndex(where: { $0.booking.id == attendee.booking.id }) {
                rows[idx] = GameAttendee(booking: updated, userName: rows[idx].userName, userEmail: rows[idx].userEmail, duprRating: rows[idx].duprRating, avatarColorKey: rows[idx].avatarColorKey)
                attendeesByGameID[game.id] = rows
            }
        } catch {
            gameOwnerErrorByID[game.id] = "Could not update payment: \(error.localizedDescription)"
            return
        }
        await refreshAttendees(for: game)
        // Signal analytics to refresh — payment method changes affect revenue KPIs
        lastAttendanceUpdateClubID = game.clubID
    }

    func ownerMoveWaitlistAttendee(for game: Game, attendee: GameAttendee, directionUp: Bool) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)
        gameOwnerInfoByID.removeValue(forKey: game.id)

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
            gameOwnerInfoByID[game.id] = "Waitlist reordered."
            await refreshAttendees(for: game)
            await refreshBookings(silent: true)
        } catch {
            gameOwnerErrorByID[game.id] = error.localizedDescription
        }
    }

    func ownerConfirmAllWaitlist(for game: Game) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)
        gameOwnerInfoByID.removeValue(forKey: game.id)

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
            gameOwnerInfoByID[game.id] = "Confirmed \(waitlisted.count) waitlisted attendee\(waitlisted.count == 1 ? "" : "s")."
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            await refreshBookings(silent: true)
        } catch {
            gameOwnerErrorByID[game.id] = error.localizedDescription
        }
    }

    func ownerClearWaitlist(for game: Game) async {
        gameOwnerErrorByID.removeValue(forKey: game.id)
        gameOwnerInfoByID.removeValue(forKey: game.id)

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
                noShowBookingIDs.remove(attendee.booking.id)
            }
            persistCheckedInBookingIDs()
            gameOwnerInfoByID[game.id] = "Cleared waitlist."
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            await refreshBookings(silent: true)
        } catch {
            gameOwnerErrorByID[game.id] = error.localizedDescription
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

        guard draft.hasVenue else {
            ownerToolsErrorMessage = "Please select a venue for this game."
            return false
        }

        if let pa = draft.publishAt, pa <= Date() {
            ownerToolsErrorMessage = "Publish time must be in the future."
            return false
        }

        guard let userID = authUserID else {
            authState = .signedOut
            return false
        }

        let repeatCount = draft.repeatWeekly ? max(draft.repeatCount, 1) : 1

        // Gate: check active game limit before creating.
        // Active = not cancelled, date in future. Scheduled (unpublished) games count.
        // For a recurring batch, check that all instances fit within the limit.
        let now = Date()
        let currentActiveCount = (gamesByClubID[club.id] ?? [])
            .filter { $0.status != "cancelled" && $0.dateTime > now }
            .count
        let gateResult = FeatureGateService.canCreateGame(
            entitlementsByClubID[club.id],
            currentActiveGameCount: currentActiveCount + repeatCount - 1
        )
        if case .blocked(let reason) = gateResult {
            ownerToolsErrorMessage = reason
            return false
        }

        // Gate: fee requires payment eligibility.
        let draftFeeForCreate = Double(draft.feeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if draftFeeForCreate > 0 {
            if case .blocked(let reason) = FeatureGateService.canAcceptPayments(entitlementsByClubID[club.id]) {
                ownerToolsErrorMessage = reason
                return false
            }
        }

        isCreatingOwnerGame = true
        defer { isCreatingOwnerGame = false }

        // Pre-compute the publish offset (seconds before game start) so each
        // recurring occurrence gets publish_at = its own start time – offset.
        let publishOffset: TimeInterval? = draft.publishAt.map { draft.startDate.timeIntervalSince($0) }

        do {
            let recurrenceGroupID = repeatCount > 1 ? UUID() : nil
            var createdGames: [Game] = []

            for occurrenceIndex in 0..<repeatCount {
                var instanceDraft = draft
                if occurrenceIndex > 0,
                   let nextDate = Calendar.current.date(byAdding: .day, value: occurrenceIndex * 7, to: draft.startDate) {
                    instanceDraft.startDate = nextDate
                }
                // Apply the same publish offset to each occurrence's start time.
                if let offset = publishOffset {
                    instanceDraft.publishAt = instanceDraft.startDate.addingTimeInterval(-offset)
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

            // Notify club members when the game is published immediately (no delay).
            // Delayed-publish games are not live yet — skip until they go public.
            if draft.publishAt == nil, let firstGame = createdGames.first, let creatorID = authUserID {
                try? await dataProvider.triggerGamePublishedNotify(
                    gameID: firstGame.id,
                    gameTitle: firstGame.title,
                    gameDateTime: firstGame.dateTime,
                    clubID: club.id,
                    clubName: club.name,
                    createdByUserID: creatorID,
                    skillLevel: draft.skillLevelRaw == "all" ? nil : draft.skillLevelRaw,
                    clubTimezone: club.timezone
                )
            }

            await refreshGames(for: club)
            return true
        } catch {
            if let sub = subscriptionsByClubID[club.id], sub.isPastDue {
                ownerToolsErrorMessage = "Your subscription payment failed. Update your payment method in Plan & Billing to restore access."
            } else {
                ownerToolsErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    func updateGameForClub(_ club: Club, game: Game, draft: ClubOwnerGameDraft, scope: RecurringGameScope = .singleEvent) async -> Bool {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        guard !game.startsInPast else {
            ownerToolsErrorMessage = "Past games cannot be edited."
            return false
        }

        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            ownerToolsErrorMessage = "Game title is required."
            return false
        }

        guard draft.hasVenue else {
            ownerToolsErrorMessage = "Please select a venue for this game."
            return false
        }

        if let pa = draft.publishAt, pa <= Date() {
            ownerToolsErrorMessage = "Publish time must be in the future."
            return false
        }

        // Gate: fee requires payment eligibility.
        let draftFeeForUpdate = Double(draft.feeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if draftFeeForUpdate > 0 {
            if case .blocked(let reason) = FeatureGateService.canAcceptPayments(entitlementsByClubID[club.id]) {
                ownerToolsErrorMessage = reason
                return false
            }
        }

        ownerSavingGameIDs.insert(game.id)
        defer { ownerSavingGameIDs.remove(game.id) }

        do {
            let effectiveScope = (game.recurrenceGroupID == nil) ? .singleEvent : scope

            if effectiveScope == .singleEvent {
                let updated = try await withAuthRetry {
                    try await self.dataProvider.updateGame(gameID: game.id, draft: draft)
                }
                // Preserve confirmed/waitlist counts (not returned by the update endpoint).
                var merged = updated
                if let current = gamesByClubID[club.id]?.first(where: { $0.id == game.id }) {
                    merged.confirmedCount = current.confirmedCount
                    merged.waitlistCount  = current.waitlistCount
                }
                // Update gamesByClubID immediately so ClubDetailView reflects the change.
                if var current = gamesByClubID[club.id], let index = current.firstIndex(where: { $0.id == game.id }) {
                    current[index] = merged
                    current.sort { $0.dateTime < $1.dateTime }
                    gamesByClubID[club.id] = current
                }
                // Propagate into bookings right away — no network call needed.
                syncGameIntoBookings(merged)
                ownerToolsInfoMessage = "Game updated."
                // Notify confirmed + waitlisted players of the change (non-blocking)
                let updatedGame = merged
                Task {
                    // Compute which fields changed so the edge function can build specific copy
                    var changedFields: [String] = []
                    if abs(draft.startDate.timeIntervalSince(game.dateTime)) > 60 { changedFields.append("date_time") }
                    if draft.venueName.trimmingCharacters(in: .whitespacesAndNewlines) != (game.venueName ?? "") { changedFields.append("venue_name") }
                    let newFee = Double(draft.feeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    if abs(newFee - (game.feeAmount ?? 0)) > 0.001 { changedFields.append("fee_amount") }
                    if draft.maxSpots != game.maxSpots { changedFields.append("max_spots") }
                    try? await self.dataProvider.triggerGameUpdatedNotify(
                        gameID: updatedGame.id,
                        clubID: club.id,
                        gameTitle: updatedGame.title,
                        clubName: club.name,
                        gameDateTime: updatedGame.dateTime,
                        changedFields: changedFields,
                        clubTimezone: club.timezone
                    )
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

                let delta = draft.startDate.timeIntervalSince(game.dateTime)
                // Pre-compute publish offset so each game in the series keeps the same gap.
                let publishOffset: TimeInterval? = draft.publishAt.map { draft.startDate.timeIntervalSince($0) }
                for target in targets {
                    var perGameDraft = draft
                    perGameDraft.startDate = target.dateTime.addingTimeInterval(delta)
                    if let offset = publishOffset {
                        perGameDraft.publishAt = perGameDraft.startDate.addingTimeInterval(-offset)
                    }
                    _ = try await withAuthRetry {
                        try await self.dataProvider.updateGame(gameID: target.id, draft: perGameDraft)
                    }
                }
                ownerToolsInfoMessage = effectiveScope == .entireSeries ? "Entire series updated." : "This and future games updated."
            }

            // Re-fetch the club's games from the server so gamesByClubID and
            // allUpcomingGames are authoritative, then sync bookings from that
            // fresh data — covers both the singleEvent and series paths.
            await refreshGames(for: club)
            syncGamesIntoBookings(from: club.id)
            // Authoritative full-bookings refresh ensures appState.bookings
            // reflects the latest game data (including on the Home screen's
            // "Your Next Game" section) without requiring the user to pull-to-refresh.
            await refreshBookings(silent: true)
            return true
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces the embedded `game` snapshot inside `appState.bookings` for a
    /// single updated game. Called immediately after a successful singleEvent edit
    /// so the UI reflects the change without waiting for a network round-trip.
    private func syncGameIntoBookings(_ updatedGame: Game) {
        bookings = bookings.map { item in
            guard item.game?.id == updatedGame.id else { return item }
            return BookingWithGame(booking: item.booking, game: updatedGame)
        }
    }

    /// Replaces the embedded `game` snapshots inside `appState.bookings` for all
    /// games belonging to `clubID`, using the freshly fetched data already in
    /// `gamesByClubID`. Called after `refreshGames(for:)` completes.
    private func syncGamesIntoBookings(from clubID: UUID) {
        let games = gamesByClubID[clubID] ?? []
        guard !games.isEmpty else { return }
        let gameByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        bookings = bookings.map { item in
            guard item.game?.clubID == clubID,
                  let gameID = item.game?.id,
                  let fresh = gameByID[gameID] else { return item }
            return BookingWithGame(booking: item.booking, game: fresh)
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
                    gameTitle: game.title,
                    clubTimezone: club.timezone
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
            // refreshClubs() already calls refreshMemberships() internally.
            await refreshClubs()
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
            // Club already patched in-memory above; no full refetch needed.
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
        allUpcomingGames.removeAll { $0.clubID == club.id }
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

    func requestMembership(for club: Club, conductAcceptedAt: Date? = nil, cancellationPolicyAcceptedAt: Date? = nil) async {
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
                try await self.dataProvider.requestMembership(clubID: club.id, userID: userID, conductAcceptedAt: conductAcceptedAt, cancellationPolicyAcceptedAt: cancellationPolicyAcceptedAt)
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

    /// Creates a `pending_payment` booking with a 30-min hold before the Stripe PaymentSheet
    /// is shown. The booking_id is used by `create-payment-intent` (Gate 0.5) to scope the
    /// Stripe idempotency key to `pi-{booking_id}-{amount}`, preventing reuse of an already-
    /// charged PI on rebook (paymentIntentInTerminalState).
    ///
    /// Returns the booking record so the caller can set `pendingBookingIDForConfirm`.
    /// Throws `SupabaseServiceError.duplicateMembership` when the user already has an active
    /// booking for this game — callers should fall back to the existing pending_payment booking.
    func reservePaidBooking(for game: Game, creditsAppliedCents: Int?) async throws -> BookingRecord {
        guard let userID = authUserID else { throw SupabaseServiceError.authenticationRequired }
        let created = try await withAuthRetry {
            try await self.dataProvider.bookGame(
                gameID: game.id,
                userID: userID,
                feePaid: false,
                holdForPayment: true,
                stripePaymentIntentID: nil,
                paymentMethod: nil,
                platformFeeCents: nil,
                clubPayoutCents: nil,
                creditsAppliedCents: creditsAppliedCents
            )
        }
        // Update local cache so bookingState(for:) reflects pending_payment immediately.
        if let idx = bookings.firstIndex(where: { $0.booking.gameID == game.id }) {
            bookings[idx] = BookingWithGame(booking: created, game: bookings[idx].game ?? game)
        } else {
            bookings.append(BookingWithGame(booking: created, game: game))
        }
        return created
    }

    func requestBooking(for game: Game, stripePaymentIntentID: String? = nil, platformFeeCents: Int? = nil, clubPayoutCents: Int? = nil, creditsAppliedCents: Int? = nil) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil
        guard !game.startsInPast else {
            bookingsErrorMessage = "This game has already taken place."
            return
        }
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
            // Fast-fail guard: paid games that appear available require proof of payment.
            // Use liveGame.isFull as a hint only — if the game looks full the user is likely
            // joining the waitlist and doesn't need payment upfront. The server is authoritative
            // on status; this guard only prevents a clearly missing payment on a non-full game.
            let liveGameIsFull = (gamesByClubID[game.clubID]?.first(where: { $0.id == game.id }) ?? game).isFull
            if !liveGameIsFull,
               let fee = game.feeAmount, fee > 0,
               stripePaymentIntentID == nil,
               creditsAppliedCents == nil {
                bookingsErrorMessage = "Payment is required to book this game. Please try again."
                return
            }

            // Server atomically determines confirmed vs waitlisted using FOR UPDATE locking
            // on the games row — no client-side race condition on isFull.
            let created = try await withAuthRetry {
                try await self.dataProvider.bookGame(
                    gameID: game.id,
                    userID: userID,
                    feePaid: stripePaymentIntentID != nil,
                    holdForPayment: false,
                    stripePaymentIntentID: stripePaymentIntentID,
                    paymentMethod: stripePaymentIntentID != nil ? "stripe" : (creditsAppliedCents != nil ? "credits" : nil),
                    platformFeeCents: platformFeeCents,
                    clubPayoutCents: clubPayoutCents,
                    creditsAppliedCents: creditsAppliedCents
                )
            }

            if let idx = bookings.firstIndex(where: { $0.booking.gameID == game.id }) {
                let existingGame = bookings[idx].game ?? game
                bookings[idx] = BookingWithGame(booking: created, game: existingGame)
            } else {
                bookings.append(BookingWithGame(booking: created, game: game))
            }

            // Signal analytics views to refresh (confirmed bookings only — not waitlist)
            if created.state == .confirmed {
                lastConfirmedBookingClubID = game.clubID
            }

            // Deduct credits atomically (non-blocking) when credits were applied
            if let credits = creditsAppliedCents, credits > 0 {
                let bookingID = created.id
                let clubID = game.clubID
                // Optimistic update: reflect the deduction immediately in the UI.
                creditBalanceByClubID[clubID] = max(0, (creditBalanceByClubID[clubID] ?? 0) - credits)
                Task {
                    _ = try? await self.dataProvider.applyCredits(
                        userID: userID,
                        bookingID: bookingID,
                        amountCents: credits,
                        clubID: clubID
                    )
                    // Confirm with authoritative DB value.
                    await self.refreshCreditBalance(for: clubID)
                }
            }

            switch created.state {
            case .waitlisted:
                bookingInfoMessage = "You have been added to the waitlist."
                Task {
                    let waitlistBody = "You're on the waitlist for \(game.title) · \(game.dateTime.formatted(date: .abbreviated, time: .shortened)). We'll notify you if a spot opens."
                    try? await self.dataProvider.triggerNotify(
                        userID: userID,
                        title: "Added to waitlist",
                        body: waitlistBody,
                        type: "booking_waitlisted",
                        referenceID: game.id,
                        sendPush: true
                    )
                    await self.refreshNotifications()
                }
            case .confirmed:
                bookingInfoMessage = "Booking confirmed."
                Task {
                    // Push comes from booking-confirmed edge function (includes formatted time + venue)
                    try? await self.dataProvider.triggerBookingConfirmedPush(
                        gameID: game.id,
                        bookingID: created.id,
                        userID: userID
                    )
                    // In-app notification row (sendPush: false avoids double push).
                    // Body matches the structured push template so the in-app
                    // list, push lock-screen, and email body all read the same.
                    let venue = game.venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let confirmedBody = Self.buildBookingConfirmedBody(
                        gameTitle: game.title,
                        dateTime: game.dateTime,
                        durationMinutes: game.durationMinutes,
                        venue: venue
                    )
                    try? await self.dataProvider.triggerNotify(
                        userID: userID,
                        title: "Booking confirmed",
                        body: confirmedBody,
                        type: "booking_confirmed",
                        referenceID: game.id,
                        sendPush: false
                    )
                    await self.refreshNotifications()
                }
            case .pendingPayment:
                bookingInfoMessage = "Booking reserved — complete payment to confirm your spot."
            case .cancelled, .none, .unknown:
                bookingInfoMessage = "Booking updated."
            }

            await refreshBookings(silent: true)
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
            case .membershipRequired:
                let isPending = clubs.first(where: { $0.id == game.clubID })
                    .map { membershipState(for: $0) == .pending } ?? false
                bookingsErrorMessage = isPending
                    ? "Your club join request is still pending. You can book once approved."
                    : "You must be an approved club member to book this game."
            case .duprRequired:
                bookingsErrorMessage = "Add and confirm your DUPR ID before booking this game."
            default:
                bookingsErrorMessage = serviceError.localizedDescription
            }
        } catch {
            bookingsErrorMessage = error.localizedDescription
        }
    }

    /// Immediately releases a `pending_payment` booking that was never paid
    /// (e.g. user cancelled the PaymentSheet). Frees the held spot so other players
    /// can book right away instead of waiting for the 30-minute cron expiry.
    /// Best-effort: errors are swallowed because local state is already reset by the caller.
    func releasePendingPaymentBooking(bookingID: UUID, game: Game) async {
        _ = try? await withAuthRetry {
            try await self.dataProvider.cancelBookingWithCredit(bookingID: bookingID)
        }
        bookings.removeAll { $0.booking.id == bookingID }
        await refreshBookings(silent: true)
        if let club = clubs.first(where: { $0.id == game.clubID }) {
            await refreshGames(for: club)
        }
    }

    func cancelBooking(for game: Game) async {
        bookingsErrorMessage = nil
        bookingInfoMessage = nil

        guard !game.startsInPast else {
            bookingsErrorMessage = "Bookings cannot be cancelled after a game has taken place."
            return
        }
        guard bookingState(for: game).canCancel else { return }
        guard let booking = existingBooking(for: game) else { return }

        cancellingBookingIDs.insert(game.id)
        defer { cancellingBookingIDs.remove(game.id) }

        do {
            // Single server-authoritative call: cancels the booking, applies the 6-hour
            // window check, computes the refund amount, and issues the credit atomically.
            // No client-side refund math — the server returns the authoritative result.
            let result = try await withAuthRetry {
                try await self.dataProvider.cancelBookingWithCredit(bookingID: booking.id)
            }

            // Optimistic local update using pre-cancel booking data with cancelled state.
            if let idx = bookings.firstIndex(where: { $0.booking.id == booking.id }) {
                let existingGame = bookings[idx].game ?? game
                let cancelledRecord = BookingRecord(
                    id: booking.id,
                    gameID: booking.gameID,
                    userID: booking.userID,
                    state: .cancelled,
                    waitlistPosition: booking.waitlistPosition,
                    createdAt: booking.createdAt,
                    feePaid: booking.feePaid,
                    paidAt: booking.paidAt,
                    stripePaymentIntentID: booking.stripePaymentIntentID,
                    paymentMethod: booking.paymentMethod,
                    platformFeeCents: booking.platformFeeCents,
                    clubPayoutCents: booking.clubPayoutCents,
                    creditsAppliedCents: booking.creditsAppliedCents,
                    holdExpiresAt: nil
                )
                bookings[idx] = BookingWithGame(booking: cancelledRecord, game: existingGame)
            }

            if scheduleStore.reminderGameIDs.contains(game.id) {
                LocalNotificationManager.shared.cancelGameReminder(gameID: game.id)
                scheduleStore.reminderGameIDs.remove(game.id)
                scheduleStore.persistReminderGameIDs()
            }

            // Apply server-returned credit result — no fetch required.
            let clubID = game.clubID
            creditBalanceByClubID[clubID] = result.newBalanceCents
            if result.creditIssuedCents > 0 {
                let clubName = clubs.first(where: { $0.id == clubID })?.name
                lastCancellationCredit = CancellationCreditResult(
                    clubID: clubID,
                    clubName: clubName,
                    creditedCents: result.creditIssuedCents,
                    newBalanceCents: result.newBalanceCents
                )
            }

            bookingInfoMessage = "Booking cancelled."

            // Snapshot waitlist before refresh so we can detect DB-trigger auto-promotions
            let preWaitlistedIDs = Set(
                (attendeesByGameID[game.id] ?? [])
                    .filter { bookingStateIsWaitlisted($0.booking.state) }
                    .map { $0.booking.userID }
            )

            await refreshBookings(silent: true)
            if let club = clubs.first(where: { $0.id == game.clubID }) {
                await refreshGames(for: club)
            }
            await refreshAttendees(for: game)
            // Server-authoritative promotion: promote_top_waitlisted trigger
            // fires on this confirmed→cancelled transition and handles the
            // waitlist queue atomically. See CLAUDE.md "Waitlist & Hold System".
            await notifyWaitlistPromoted(for: game, previouslyWaitlisted: preWaitlistedIDs)
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

    func cancelGame(for game: Game) async {
        ownerToolsErrorMessage = nil
        ownerToolsInfoMessage = nil

        cancellingGameIDs.insert(game.id)
        defer { cancellingGameIDs.remove(game.id) }

        do {
            try await withAuthRetry {
                try await self.dataProvider.cancelGame(gameID: game.id)
            }

            // Update in-memory game status — propagates immediately to all list views
            if var games = gamesByClubID[game.clubID],
               let idx = games.firstIndex(where: { $0.id == game.id }) {
                games[idx].status = "cancelled"
                gamesByClubID[game.clubID] = games
            }
            allUpcomingGames.removeAll { $0.id == game.id }

            // Notify all booked players
            let clubTZ = clubs.first(where: { $0.id == game.clubID })?.timezone ?? "Australia/Perth"
            try? await withAuthRetry {
                try await self.dataProvider.triggerGameCancelledNotify(
                    gameID: game.id,
                    gameTitle: game.title,
                    clubTimezone: clubTZ
                )
            }

            ownerToolsInfoMessage = "Game cancelled."
        } catch let serviceError as SupabaseServiceError {
            switch serviceError {
            case .authenticationRequired:
                authInfoMessage = "Please sign in again to manage games."
            default:
                ownerToolsErrorMessage = serviceError.localizedDescription
            }
        } catch {
            ownerToolsErrorMessage = error.localizedDescription
        }
    }

    /// Detects players who transitioned from waitlisted → confirmed after a refresh
    /// (i.e. promoted by the DB trigger) and sends them a push notification.
    private func notifyWaitlistPromoted(for game: Game, previouslyWaitlisted: Set<UUID>) async {
        guard !previouslyWaitlisted.isEmpty else { return }
        let promoted = (attendeesByGameID[game.id] ?? []).filter { attendee in
            guard previouslyWaitlisted.contains(attendee.booking.userID) else { return false }
            return bookingStateIsConfirmed(attendee.booking.state)
        }
        for attendee in promoted {
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
        }
    }

    // Client-side waitlist auto-promotion was removed on 2026-05-02 after a
    // 5/4 over-booking incident. The DB trigger promote_top_waitlisted handles
    // confirmed→cancelled transitions atomically (counts confirmed +
    // pending_payment under a games row lock, promotes one waitlister, sends
    // push via promote-top-waitlisted-push). The cron revert_expired_holds_and_repromote
    // handles hold expiry. The client must never decide promotion order or
    // flip status from waitlisted → pending_payment. See CLAUDE.md
    // "Waitlist & Hold System → Do not reintroduce".

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

        guard let offsetMinutes = gameReminderOffsetMinutes else {
            bookingInfoMessage = "Reminder config hasn't loaded yet. Please try again in a moment."
            return
        }

        do {
            let clubName = clubs.first(where: { $0.id == game.clubID })?.name ?? ""
            _ = try await LocalNotificationManager.shared.scheduleGameReminder(
                for: game,
                offsetMinutes: offsetMinutes,
                clubName: clubName
            )
            scheduleStore.reminderGameIDs.insert(game.id)
            scheduleStore.persistReminderGameIDs()
            let hours = offsetMinutes / 60
            bookingInfoMessage = "Reminder set — you'll be notified \(hours) hour\(hours == 1 ? "" : "s") before the game."
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
            let venues = clubVenuesByClubID[game.clubID] ?? []
            let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
            let eventID = try await LocalCalendarManager.shared.addGameToCalendar(game: game, clubName: clubName, resolvedVenue: resolvedVenue)
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
        isPerformingPostSignInBootstrap = true
        defer { isPerformingPostSignInBootstrap = false }
        await refreshClubs()
        await loadProfileFromBackendIfAvailable()
        await loadNotificationPreferencesIfNeeded()
        await refreshMemberships()
        await refreshBookings(silent: true)
        await refreshUpcomingGames()
        await refreshNotifications()
        await prepareClubChatPushNotificationsIfNeeded()
        // Flush any push token that arrived before auth was ready (common on first launch / session restore).
        await flushPendingPushTokenIfNeeded()
    }

    private func flushPendingPushTokenIfNeeded() async {
        guard let userID = authUserID, let token = remotePushTokenHex else { return }
        do {
            try await withAuthRetry {
                try await self.dataProvider.updateProfilePushToken(userID: userID, pushToken: token)
            }
        } catch {
            // Non-fatal — local notifications still work.
        }
    }

    // MARK: - In-App Notifications

    var unreadNotificationCount: Int {
        notifications.filter { !$0.read }.count
    }

    private func syncBadgeCount() {
        let count = unreadNotificationCount
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    func refreshNotifications() async {
        guard authState == .signedIn, let userID = authUserID else { return }
        isLoadingNotifications = true
        defer { isLoadingNotifications = false }
        if let fetched = try? await withAuthRetry({ try await self.dataProvider.fetchNotifications(userID: userID) }) {
            notifications = fetched
            syncBadgeCount()
        }
    }

    func markNotificationRead(_ notification: AppNotification) async {
        guard !notification.read else { return }
        if let idx = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[idx].read = true
        }
        syncBadgeCount()
        try? await dataProvider.markNotificationRead(id: notification.id)
    }

    func markAllNotificationsRead() async {
        guard let userID = authUserID else { return }
        notifications = notifications.map { var copy = $0; copy.read = true; return copy }
        syncBadgeCount()
        try? await dataProvider.markAllNotificationsRead(userID: userID)
    }

    func clearAllNotifications() async {
        guard let userID = authUserID else { return }
        notifications = []
        syncBadgeCount()
        try? await dataProvider.deleteAllNotifications(userID: userID)
    }

    func submitReview(gameID: UUID, rating: Int, comment: String?) async throws {
        guard let userID = authUserID else { return }
        try await dataProvider.submitReview(gameID: gameID, userID: userID, rating: rating, comment: comment)
        // Don't nil pendingReviewPrompt here — the sheet is still showing the success state.
        // The onDismiss handler calls dismissReviewPrompt(gameID:) which refreshes the prompt.
    }

    /// Fetches the highest-priority pending review from the server and publishes it.
    /// Called at bootstrap and after the review sheet closes (via dismissReviewPrompt).
    func fetchPendingReviewPrompt() async {
        guard authState == .signedIn, let userID = authUserID else { return }
        let prompt = try? await dataProvider.fetchPendingReviewPrompt(userID: userID)
        await MainActor.run { pendingReviewPrompt = prompt }
    }

    /// Called when the review sheet closes (submitted or dismissed without submitting).
    /// Marks the game as dismissed server-side (idempotent for submitted games since the
    /// reviews table check takes priority), then checks for the next pending prompt.
    func dismissReviewPrompt(gameID: UUID) async {
        await MainActor.run {
            if pendingReviewPrompt?.id == gameID { pendingReviewPrompt = nil }
        }
        try? await dataProvider.dismissReviewPrompt(gameID: gameID)
        // After dismiss/submit, check if another review is pending.
        await fetchPendingReviewPrompt()
    }

    /// Resolves a Game by ID. Checks memory caches first; falls back to a DB fetch.
    /// Used by deep-link navigation when a game notification arrives before the club's
    /// games have been loaded (e.g. new_game push received from the lock screen).
    func resolveGame(id: UUID) async -> Game? {
        // 1. Check upcoming games cache
        if let game = gamesByClubID.values.flatMap({ $0 }).first(where: { $0.id == id }) {
            return game
        }
        // 2. Check bookings cache (includes booked past games)
        if let game = bookings.first(where: { $0.booking.gameID == id })?.game {
            return game
        }
        // 3. Fetch from DB — game not in any memory cache
        return try? await dataProvider.fetchGame(gameID: id)
    }

    /// Resolves the club for a game ID. Checks memory caches first; falls back to a
    /// lightweight DB fetch of just club_id. Safe to call from a Task during sheet open.
    func clubForGame(gameID: UUID) async -> Club? {
        // 1. Check upcoming games cache
        for (clubID, games) in gamesByClubID {
            if games.contains(where: { $0.id == gameID }) {
                return clubs.first { $0.id == clubID }
            }
        }
        // 2. Check bookings cache (includes past games)
        if let game = bookings.first(where: { $0.booking.gameID == gameID })?.game {
            return clubs.first { $0.id == game.clubID }
        }
        // 3. Fetch club_id from DB (past game not cached anywhere)
        guard let clubID = try? await dataProvider.fetchGameClubID(gameID: gameID) else { return nil }
        return clubs.first { $0.id == clubID }
    }

    func fetchReviews(for clubID: UUID) async {
        guard !loadingReviewsClubIDs.contains(clubID) else { return }
        loadingReviewsClubIDs.insert(clubID)
        do {
            let reviews = try await dataProvider.fetchClubReviews(clubID: clubID)
            reviewsByClubID[clubID] = reviews
        } catch {
            // Silently fail — reviews are non-critical; section stays hidden
        }
        loadingReviewsClubIDs.remove(clubID)
    }

    func fetchClubRevenueSummary(for clubID: UUID, days: Int?) async {
        guard !loadingRevenueSummaryClubIDs.contains(clubID) else { return }
        loadingRevenueSummaryClubIDs.insert(clubID)
        do {
            let summary = try await withAuthRetry {
                try await self.dataProvider.fetchClubRevenueSummary(clubID: clubID, days: days)
            }
            if let summary {
                revenueSummaryByClubID[clubID] = summary
            }
        } catch {
            // Error is surfaced via nil in revenueSummaryByClubID — UI shows empty state
        }
        loadingRevenueSummaryClubIDs.remove(clubID)
    }

    func fetchClubFillRateSummary(for clubID: UUID, days: Int?) async {
        guard !loadingFillRateSummaryClubIDs.contains(clubID) else { return }
        loadingFillRateSummaryClubIDs.insert(clubID)
        do {
            let summary = try await withAuthRetry {
                try await self.dataProvider.fetchClubFillRateSummary(clubID: clubID, days: days)
            }
            if let summary {
                fillRateSummaryByClubID[clubID] = summary
            }
        } catch {
            // Error is surfaced via nil in fillRateSummaryByClubID — UI shows empty state
        }
        loadingFillRateSummaryClubIDs.remove(clubID)
    }

    // MARK: - Phase 5B Analytics

    /// Fetches all advanced analytics data for the given club and period concurrently.
    /// Sets loadingAnalyticsClubIDs while in-flight; populates four published dicts on completion.
    func fetchClubAdvancedAnalytics(for clubID: UUID, days: Int, startDate: Date? = nil, endDate: Date? = nil) async {
        guard !loadingAnalyticsClubIDs.contains(clubID) else { return }
        loadingAnalyticsClubIDs.insert(clubID)
        // Core analytics — fetched concurrently. A failure here leaves the view empty.
        analyticsErrorByClubID.removeValue(forKey: clubID)
        do {
            async let kpis     = withAuthRetry { try await self.dataProvider.fetchClubAnalyticsKPIs(clubID: clubID, days: days, startDate: startDate, endDate: endDate) }
            async let trend    = withAuthRetry { try await self.dataProvider.fetchClubRevenueTrend(clubID: clubID, days: days, startDate: startDate, endDate: endDate) }
            async let topGames = withAuthRetry { try await self.dataProvider.fetchClubTopGames(clubID: clubID, days: days, startDate: startDate, endDate: endDate) }
            async let peaks    = withAuthRetry { try await self.dataProvider.fetchClubPeakTimes(clubID: clubID, days: days, startDate: startDate, endDate: endDate) }

            let k = try await kpis
            let t = try await trend
            let g = try await topGames
            let p = try await peaks

            if let k { analyticsKPIsByClubID[clubID] = k }
            revenueTrendByClubID[clubID] = t
            topGamesByClubID[clubID]     = g
            peakTimesByClubID[clubID]    = p
        } catch {
            analyticsErrorByClubID[clubID] = error.localizedDescription
        }

        // Supplemental analytics — isolated so a missing/failing RPC never blocks core data.
        // Sections that depend on this data show "—" gracefully when it's absent.
        do {
            if let s = try await withAuthRetry({ try await self.dataProvider.fetchClubAnalyticsSupplemental(clubID: clubID, days: days, startDate: startDate, endDate: endDate) }) {
                analyticsSupplementalByClubID[clubID] = s
            }
        } catch {
            // Non-fatal — deploy get_club_analytics_supplemental migration to enable these sections.
        }
        loadingAnalyticsClubIDs.remove(clubID)
    }

    /// Fetches the lightweight dashboard summary for a club.
    /// Available on all plan tiers — no analytics entitlement required.
    func loadDashboardSummary(for clubID: UUID) async {
        do {
            if let summary = try await withAuthRetry({ try await self.dataProvider.fetchClubDashboardSummary(clubID: clubID) }) {
                dashboardSummaryByClubID[clubID] = summary
            }
        } catch {
            // Non-fatal — dashboard shows "—" for unloaded metrics.
        }
    }

    private func loadNotificationPreferencesIfNeeded() async {
        guard authState == .signedIn, let userID = authUserID else { return }
        do {
            if let prefs = try await dataProvider.fetchNotificationPreferences(userID: userID) {
                await MainActor.run { notificationPreferences = prefs }
            }
        } catch {
            // Non-fatal — defaults (all on) remain in effect.
        }
    }

    func saveNotificationPreferences() async {
        guard let userID = authUserID else { return }
        let prefs = notificationPreferences
        do {
            try await dataProvider.saveNotificationPreferences(userID: userID, prefs: prefs)
        } catch {
            // Silently ignore — preference is still applied locally this session.
        }
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
                    firstName: fetchedProfile.firstName,
                    lastName: fetchedProfile.lastName,
                    fullName: trimmedName,
                    email: fetchedProfile.email,
                    phone: fetchedProfile.phone,
                    dateOfBirth: fetchedProfile.dateOfBirth,
                    emergencyContactName: fetchedProfile.emergencyContactName,
                    emergencyContactPhone: fetchedProfile.emergencyContactPhone,
                    duprRating: fetchedProfile.duprRating,
                    duprID: fetchedProfile.duprID,
                    favoriteClubName: currentFavoriteClub,
                    skillLevel: currentSkill,
                    avatarColorKey: fetchedProfile.avatarColorKey
                )
                authEmail = fetchedProfile.email
                // Sync Supabase DUPR value → UserDefaults so admin-applied updates
                // are reflected on the member's device after next profile load.
                // Always sync — including nil — so cleared ratings don't linger in cache.
                _ = saveDUPRRatings(doubles: fetchedProfile.duprRating)
                // Sync DUPR ID from DB → local state (authoritative source for server gate).
                if let dbDuprID = fetchedProfile.duprID, !dbDuprID.trimmingCharacters(in: .whitespaces).isEmpty {
                    duprIDByUserID[userID] = dbDuprID
                    duprID = dbDuprID
                    persistDUPRIDStore()
                }

            }
        } catch {
            // Avoid blocking the UI; auth is valid even if profile row is missing.
        }
    }

    func saveProfilePersonalInfo(firstName: String? = nil, lastName: String? = nil, fullName: String, phone: String?, dateOfBirth: Date?, duprRating: Double?) async {
        guard var current = profile else { return }
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            profileSaveErrorMessage = "Full name is required."
            return
        }
        if let f = firstName { current.firstName = f }
        if let l = lastName { current.lastName = l }
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
            // Sync UserDefaults from the value Supabase actually stored (not the raw input),
            // so the cache always reflects the true DB value.
            _ = saveDUPRRatings(doubles: updated.duprRating)
        } catch {
            profileSaveErrorMessage = AppCopy.friendlyError(error.localizedDescription)
        }
    }

    func loadAvatarPalettes() async {
        guard let rows = try? await dataProvider.fetchAvatarPalettes(), !rows.isEmpty else { return }
        let cache = Dictionary(uniqueKeysWithValues: rows.map { ($0.paletteKey, $0.toEntry()) })
        await MainActor.run { AvatarGradients.liveCache = cache }
    }

    func saveAvatarColorKey(_ key: String?) async {
        guard var current = profile else { return }
        current.avatarColorKey = key
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
            // 403 is a permission/eligibility error — a refreshed token cannot fix it.
            // Only 401 (genuine auth expiry) should trigger a session refresh.
            return code == 401
        case .missingConfiguration, .invalidURL, .duplicateMembership, .notFound, .decoding, .network, .holdExpired, .membershipRequired, .duprRequired, .notAuthorized, .invalidPayload, .rateLimited:
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
        case .missingConfiguration, .invalidURL, .duplicateMembership, .notFound, .decoding, .network, .holdExpired, .membershipRequired, .duprRequired, .notAuthorized, .invalidPayload, .rateLimited:
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
        let attendedIDs = checkedInBookingIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(attendedIDs, forKey: StorageKeys.checkedInBookingIDs)
        let noShowIDs = noShowBookingIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(noShowIDs, forKey: StorageKeys.noShowBookingIDs)
    }

    private func restoreCheckedInBookingIDs() {
        if let rawIDs = UserDefaults.standard.array(forKey: StorageKeys.checkedInBookingIDs) as? [String] {
            checkedInBookingIDs = Set(rawIDs.compactMap(UUID.init(uuidString:)))
        }
        if let rawIDs = UserDefaults.standard.array(forKey: StorageKeys.noShowBookingIDs) as? [String] {
            noShowBookingIDs = Set(rawIDs.compactMap(UUID.init(uuidString:)))
        }
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
        // Store as [userIDString: Double]
        let rawMap: [String: Double] = duprRatingsByUserID.compactMapValues { $0 }
            .reduce(into: [:]) { result, entry in result[entry.key.uuidString] = entry.value }
        UserDefaults.standard.set(rawMap, forKey: StorageKeys.duprRatingsByUserID)
    }

    private func restoreDUPRRatingsStore() {
        // Support both old format ([String: [String: Double]]) and new ([String: Double])
        if let rawMap = UserDefaults.standard.dictionary(forKey: StorageKeys.duprRatingsByUserID) as? [String: Double] {
            duprRatingsByUserID = rawMap.reduce(into: [:]) { partial, entry in
                guard let userID = UUID(uuidString: entry.key) else { return }
                partial[userID] = entry.value
            }
        } else if let oldMap = UserDefaults.standard.dictionary(forKey: StorageKeys.duprRatingsByUserID) as? [String: [String: Double]] {
            // Migrate old doubles/singles format — keep doubles only
            duprRatingsByUserID = oldMap.reduce(into: [:]) { partial, entry in
                guard let userID = UUID(uuidString: entry.key) else { return }
                partial[userID] = entry.value["d"]
            }
            persistDUPRRatingsStore() // rewrite in new format
        } else {
            duprRatingsByUserID = [:]
        }
    }

    private func syncCurrentUserDUPRRatingsFromStore() {
        guard let userID = authUserID else {
            duprDoublesRating = nil
            return
        }
        duprDoublesRating = duprRatingsByUserID[userID] ?? nil
    }

    private func persistClubNewsNotificationPreference() {
        let mutedStrings = mutedClubChatIDs.map(\.uuidString)
        UserDefaults.standard.set(mutedStrings, forKey: StorageKeys.clubNewsNotificationsEnabled)
    }

    private func restoreClubNewsNotificationPreference() {
        let mutedStrings = UserDefaults.standard.stringArray(forKey: StorageKeys.clubNewsNotificationsEnabled) ?? []
        mutedClubChatIDs = Set(mutedStrings.compactMap(UUID.init))
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
        // APNs push (club-chat-push Edge Function) is the single notification path for chat events —
        // both background delivery and foreground presentation (via willPresent → .banner) are handled
        // server-side. Local notifications are suppressed here to prevent duplicate banners when the
        // app refreshes the feed after receiving a push.
        seenClubNewsPostIDsByClubID[club.id] = Set(newPosts.map(\.id))
        seenClubNewsCommentIDsByClubID[club.id] = Set(newPosts.flatMap { $0.comments.map(\.id) })
        clubNewsPrimedClubIDs.insert(club.id)
    }

    // MARK: - Club Venues

    func venues(for club: Club) -> [ClubVenue] {
        clubVenuesByClubID[club.id] ?? []
    }

    func refreshVenues(for club: Club) async {
        loadingClubVenueIDs.insert(club.id)
        defer { loadingClubVenueIDs.remove(club.id) }
        do {
            let fetched = try await withAuthRetry {
                try await self.dataProvider.fetchClubVenues(clubID: club.id)
            }
            clubVenuesByClubID[club.id] = fetched
        } catch {
            telemetryLogger.error("fetchClubVenues failed: \(error.localizedDescription)")
        }
    }

    func createVenue(for club: Club, draft: ClubVenueDraft) async -> Bool {
        ownerToolsErrorMessage = nil
        let tempID = UUID()
        savingClubVenueIDs.insert(tempID)
        defer { savingClubVenueIDs.remove(tempID) }
        // Fast path: coordinates pre-resolved via place search — no geocoding needed.
        // Manual entry path: geocode the address fields; block if it fails.
        let saveLat: Double
        let saveLng: Double
        if let lat = draft.resolvedLatitude, let lng = draft.resolvedLongitude {
            saveLat = lat
            saveLng = lng
        } else {
            let geocodeResult = await LocationService.geocode(draft: draft)
            guard case .success(let geocoded) = geocodeResult else {
                switch geocodeResult {
                case .emptyAddress:
                    ownerToolsErrorMessage = "Please enter an address before saving."
                case .noResult:
                    ownerToolsErrorMessage = "Address could not be located. Check the address and try again."
                case .failed:
                    ownerToolsErrorMessage = "Location lookup failed. Check your connection and try again."
                case .success:
                    break
                }
                return false
            }
            saveLat = geocoded.coordinate.latitude
            saveLng = geocoded.coordinate.longitude
        }
        do {
            let venue = try await withAuthRetry {
                try await self.dataProvider.createClubVenue(
                    clubID: club.id,
                    draft: draft,
                    latitude: saveLat,
                    longitude: saveLng
                )
            }
            var current = clubVenuesByClubID[club.id] ?? []
            current.append(venue)
            // Enforce single-primary: demote all other venues in DB and local cache.
            if draft.isPrimary {
                try? await withAuthRetry {
                    try await self.dataProvider.demoteOtherPrimaryVenues(clubID: club.id, exceptVenueID: venue.id)
                }
                for i in current.indices where current[i].id != venue.id {
                    current[i].isPrimary = false
                }
            }
            current.sort { ($0.isPrimary && !$1.isPrimary) || ($0.venueName < $1.venueName && $0.isPrimary == $1.isPrimary) }
            clubVenuesByClubID[club.id] = current
            // Propagate primary venue name and coordinates to the club row.
            // venue_name drives Club.addressLine1 in the clubs list; coordinates power the explore map.
            if draft.isPrimary {
                let name = draft.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    try? await withAuthRetry {
                        try await self.dataProvider.updateClubVenueName(clubID: club.id, venueName: name)
                    }
                }
                if let lat = venue.latitude, let lng = venue.longitude {
                    try? await withAuthRetry {
                        try await self.dataProvider.updateClubCoordinates(clubID: club.id, latitude: lat, longitude: lng)
                    }
                }
                await refreshClubs()
            }
            return true
        } catch {
            ownerToolsErrorMessage = "Could not save venue: \(error.localizedDescription)"
            return false
        }
    }

    func updateVenue(for club: Club, venue: ClubVenue, draft: ClubVenueDraft) async -> Bool {
        ownerToolsErrorMessage = nil
        savingClubVenueIDs.insert(venue.id)
        defer { savingClubVenueIDs.remove(venue.id) }
        // Geocode when the address changed, or when the existing venue has no coordinates.
        // Both cases must succeed — a venue without valid coordinates cannot be saved.
        // Address unchanged AND coordinates already valid → existing coordinates preserved.
        var geocodedLat: Double? = nil
        var geocodedLng: Double? = nil
        var shouldWriteCoordinates = false
        if let lat = draft.resolvedLatitude, let lng = draft.resolvedLongitude {
            // Fast path: coordinates pre-resolved via place search.
            geocodedLat = lat
            geocodedLng = lng
            shouldWriteCoordinates = true
        } else if draft.locationChanged {
            let geocodeResult = await LocationService.geocode(draft: draft)
            guard case .success(let geocoded) = geocodeResult else {
                switch geocodeResult {
                case .emptyAddress:
                    ownerToolsErrorMessage = "Please enter an address before saving."
                case .noResult:
                    ownerToolsErrorMessage = "Address could not be located. Check the address and try again."
                case .failed:
                    ownerToolsErrorMessage = "Location lookup failed. Check your connection and try again."
                case .success:
                    break
                }
                return false
            }
            geocodedLat = geocoded.coordinate.latitude
            geocodedLng = geocoded.coordinate.longitude
            shouldWriteCoordinates = true
        } else if !venue.hasResolvedCoordinates {
            // Address unchanged but venue has no valid coordinates — must resolve before saving.
            let geocodeResult = await LocationService.geocode(draft: draft)
            guard case .success(let geocoded) = geocodeResult else {
                switch geocodeResult {
                case .emptyAddress:
                    ownerToolsErrorMessage = "This venue has no address. Add an address before saving."
                case .noResult:
                    ownerToolsErrorMessage = "Venue address could not be located. Update the address and try again."
                case .failed:
                    ownerToolsErrorMessage = "Location lookup failed. Check your connection and try again."
                case .success:
                    break
                }
                return false
            }
            geocodedLat = geocoded.coordinate.latitude
            geocodedLng = geocoded.coordinate.longitude
            shouldWriteCoordinates = true
        }
        do {
            let updated = try await withAuthRetry {
                try await self.dataProvider.updateClubVenue(
                    venueID: venue.id,
                    draft: draft,
                    latitude: geocodedLat,
                    longitude: geocodedLng,
                    updateCoordinates: shouldWriteCoordinates
                )
            }
            var current = clubVenuesByClubID[club.id] ?? []
            if let idx = current.firstIndex(where: { $0.id == venue.id }) {
                current[idx] = updated
            }
            // Enforce single-primary: demote all other venues in DB and local cache.
            if updated.isPrimary {
                try? await withAuthRetry {
                    try await self.dataProvider.demoteOtherPrimaryVenues(clubID: club.id, exceptVenueID: updated.id)
                }
                for i in current.indices where current[i].id != updated.id {
                    current[i].isPrimary = false
                }
            }
            current.sort { ($0.isPrimary && !$1.isPrimary) || ($0.venueName < $1.venueName && $0.isPrimary == $1.isPrimary) }
            clubVenuesByClubID[club.id] = current
            // Propagate primary venue name and coordinates to the club row.
            if updated.isPrimary {
                let name = updated.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    try? await withAuthRetry {
                        try await self.dataProvider.updateClubVenueName(clubID: club.id, venueName: name)
                    }
                }
                if let lat = updated.latitude, let lng = updated.longitude {
                    try? await withAuthRetry {
                        try await self.dataProvider.updateClubCoordinates(clubID: club.id, latitude: lat, longitude: lng)
                    }
                }
                await refreshClubs()
            }
            return true
        } catch {
            ownerToolsErrorMessage = "Could not update venue: \(error.localizedDescription)"
            return false
        }
    }

    func deleteVenue(for club: Club, venue: ClubVenue) async -> Bool {
        ownerToolsErrorMessage = nil
        deletingClubVenueIDs.insert(venue.id)
        defer { deletingClubVenueIDs.remove(venue.id) }
        do {
            try await withAuthRetry {
                try await self.dataProvider.deleteClubVenue(venueID: venue.id)
            }
            clubVenuesByClubID[club.id]?.removeAll { $0.id == venue.id }
            return true
        } catch {
            ownerToolsErrorMessage = "Could not delete venue: \(error.localizedDescription)"
            return false
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
