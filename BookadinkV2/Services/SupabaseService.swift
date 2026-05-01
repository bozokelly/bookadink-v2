import Foundation

/// Server-authoritative result returned by `cancelBookingWithCredit`.
struct CancellationResult {
    /// Credits issued to the player's club balance (0 if outside the window or free game).
    let creditIssuedCents: Int
    /// True when the cancellation was within the 6-hour eligible window.
    let wasEligible: Bool
    /// The player's authoritative credit balance for the club after the operation.
    let newBalanceCents: Int
}

/// Attendance records for a single game, returned by fetchAttendanceRecords.
struct AttendanceRecords {
    /// Maps bookingID → attendance status ('attended' | 'no_show') for all rows in game_attendance.
    let attendanceStatusByBookingID: [UUID: String]
    /// Maps bookingID → payment status ('unpaid' | 'cash' | 'stripe') for all rows in game_attendance.
    let paymentByBookingID: [UUID: String]
}

protocol ClubDataProviding {
    func setAccessToken(_ token: String?)
    func signIn(email: String, password: String) async throws -> AuthFlowResult
    func signUp(email: String, password: String) async throws -> AuthFlowResult
    func refreshSession(refreshToken: String) async throws -> AuthSessionInfo
    func fetchClubs() async throws -> [Club]
    func fetchClubDetail(id: UUID) async throws -> Club
    func fetchGames(clubID: UUID) async throws -> [Game]
    func fetchGamesInSeries(recurrenceGroupID: UUID) async throws -> [Game]
    func fetchGameAttendees(gameID: UUID) async throws -> [GameAttendee]
    /// Returns attendance and payment records for all game_attendance rows for this game.
    func fetchAttendanceRecords(gameID: UUID) async throws -> AttendanceRecords
    func updateAttendancePaymentStatus(bookingID: UUID, status: String) async throws
    func fetchUserBookings(userID: UUID) async throws -> [BookingWithGame]
    func fetchProfile(userID: UUID) async throws -> UserProfile?
    func patchDuprID(userID: UUID, duprID: String) async throws
    func fetchMemberships(userID: UUID) async throws -> [ClubMembershipRecord]
    func fetchPendingClubJoinRequests(clubID: UUID) async throws -> [ClubJoinRequest]
    func fetchOwnerClubMembers(clubID: UUID, ownerUserID: UUID?) async throws -> [ClubOwnerMember]
    func fetchClubDirectoryMembers(clubID: UUID) async throws -> [ClubDirectoryMember]
    func fetchClubAdminRole(clubID: UUID, userID: UUID) async throws -> ClubAdminRole?
    func fetchAllAdminRoles(userID: UUID) async throws -> [UUID: ClubAdminRole]
    func fetchClubNewsPosts(clubID: UUID, currentUserID: UUID?) async throws -> [ClubNewsPost]
    func updateClubNewsPost(postID: UUID, content: String, imageURLs: [URL]) async throws
    func requestMembership(clubID: UUID, userID: UUID, conductAcceptedAt: Date?, cancellationPolicyAcceptedAt: Date?) async throws -> ClubMembershipState
    func removeMembership(clubID: UUID, userID: UUID) async throws
    func updateClubJoinRequest(requestID: UUID, status: String, respondedBy: UUID?) async throws
    func setClubAdminAccess(clubID: UUID, userID: UUID, makeAdmin: Bool) async throws
    func adminUpdateMemberDUPR(memberUserID: UUID, rating: Double) async throws
    func createClub(createdBy: UUID, draft: ClubOwnerEditDraft) async throws -> Club
    func createGame(for clubID: UUID, createdBy: UUID, draft: ClubOwnerGameDraft, recurrenceGroupID: UUID?) async throws -> Game
    func updateGame(gameID: UUID, draft: ClubOwnerGameDraft) async throws -> Game
    func deleteGame(gameID: UUID) async throws
    func cancelGame(gameID: UUID) async throws
    func updateClubOwnerFields(clubID: UUID, draft: ClubOwnerEditDraft) async throws -> Club
    func deleteClub(clubID: UUID) async throws
    func createBooking(gameID: UUID, userID: UUID, status: String, waitlistPosition: Int?, feePaid: Bool, stripePaymentIntentID: String?, paymentMethod: String?, platformFeeCents: Int?, clubPayoutCents: Int?, creditsAppliedCents: Int?) async throws -> BookingRecord
    /// Atomically books a game, letting the server determine confirmed vs waitlisted status.
    /// Pass `holdForPayment: true` for paid fresh bookings — creates a `pending_payment`
    /// booking with a 30-min hold so `create-payment-intent` can scope the PI to this booking_id.
    func bookGame(gameID: UUID, userID: UUID, feePaid: Bool, holdForPayment: Bool, stripePaymentIntentID: String?, paymentMethod: String?, platformFeeCents: Int?, clubPayoutCents: Int?, creditsAppliedCents: Int?) async throws -> BookingRecord
    /// Transitions a `pending_payment` booking to `confirmed` after successful Stripe payment.
    func confirmPendingBooking(bookingID: UUID, stripePaymentIntentID: String?, platformFeeCents: Int?, clubPayoutCents: Int?, creditsAppliedCents: Int?) async throws -> BookingRecord
    func ownerCreateBooking(gameID: UUID, userID: UUID, status: String, waitlistPosition: Int?) async throws -> BookingRecord
    /// Atomically cancels the caller's own booking and issues a credit refund when within
    /// the 6-hour window. Server computes the eligible amount — no client-side math.
    func cancelBookingWithCredit(bookingID: UUID) async throws -> CancellationResult
    func ownerUpdateBooking(bookingID: UUID, status: String, waitlistPosition: Int?) async throws -> BookingRecord
    func updateBookingPaymentMethod(bookingID: UUID, paymentMethod: String) async throws -> BookingRecord
    func upsertAttendance(gameID: UUID, bookingID: UUID, userID: UUID, checkedInBy: UUID, status: String) async throws
    func deleteAttendanceCheckIn(bookingID: UUID) async throws
    func uploadClubAvatarImage(_ data: Data, clubID: UUID) async throws -> URL
    func uploadClubBannerImage(_ data: Data, clubID: UUID) async throws -> URL
    func uploadClubNewsImage(_ image: FeedImageUploadPayload, userID: UUID, clubID: UUID) async throws -> URL
    func deleteClubNewsImages(_ imageURLs: [URL]) async throws
    /// Deletes a club avatar or banner image from Supabase storage by its public URL.
    /// Silently no-ops if the URL does not belong to the managed club-images bucket.
    func deleteClubStorageImage(at url: URL) async throws
    func createClubNewsPost(clubID: UUID, userID: UUID, content: String, imageURLs: [URL], isAnnouncement: Bool) async throws -> UUID?
    func toggleClubNewsLike(postID: UUID, userID: UUID) async throws
    func createClubNewsComment(postID: UUID, userID: UUID, content: String, parentCommentID: UUID?) async throws -> UUID?
    func deleteClubNewsComment(commentID: UUID) async throws
    func deleteClubNewsPost(postID: UUID) async throws
    func createClubNewsModerationReport(clubID: UUID, senderUserID: UUID, targetKind: ClubNewsModerationReport.TargetKind, targetID: UUID?, reason: String, details: String) async throws
    func fetchClubNewsModerationReports(clubID: UUID) async throws -> [ClubNewsModerationReport]
    func resolveClubNewsModerationReport(reportID: UUID) async throws
    func triggerClubChatPushHook(clubID: UUID, actorUserID: UUID, event: String, referenceID: UUID?, postAuthorID: UUID?, content: String?) async throws
    func triggerBookingConfirmedPush(gameID: UUID, bookingID: UUID, userID: UUID) async throws
    func triggerNotify(userID: UUID, title: String, body: String, type: String, referenceID: UUID?, sendPush: Bool) async throws
    func triggerGameUpdatedNotify(gameID: UUID, clubID: UUID, gameTitle: String, clubName: String, gameDateTime: Date?, changedFields: [String], clubTimezone: String) async throws
    func triggerGameCancelledNotify(gameID: UUID, gameTitle: String, clubTimezone: String) async throws
    func triggerGamePublishedNotify(gameID: UUID, gameTitle: String, gameDateTime: Date, clubID: UUID, clubName: String, createdByUserID: UUID, skillLevel: String?, clubTimezone: String) async throws
    func triggerClubAnnouncementNotify(clubID: UUID, postID: UUID, posterUserID: UUID, clubName: String, posterName: String, postBody: String) async throws
    func createPaymentIntent(amountCents: Int, currency: String, clubID: UUID?, metadata: [String: String]) async throws -> PaymentIntentResult
    func fetchClubStripeAccount(clubID: UUID) async throws -> ClubStripeAccount?
    /// Fetches live Stripe account state, persists it to club_stripe_accounts, and returns current status.
    func refreshStripeAccountStatus(clubID: UUID) async throws -> ClubStripeAccount?
    /// Creates a Stripe Connect onboarding link for the club. `returnURL` is the deep link back into the app.
    func createConnectOnboarding(clubID: UUID, returnURL: String) async throws -> String
    // MARK: - Club Subscriptions (Phase 4)
    func fetchClubSubscription(clubID: UUID) async throws -> ClubSubscription?
    func createClubSubscription(clubID: UUID, priceID: String) async throws -> ClubSubscriptionResult
    func cancelClubSubscription(clubID: UUID) async throws
    // MARK: - Club Entitlements (Phase 4 Part 2A)
    func fetchClubEntitlements(clubID: UUID) async throws -> ClubEntitlements?
    func fetchClubAdminUserIDs(clubID: UUID) async throws -> [UUID]
    func fetchNotifications(userID: UUID) async throws -> [AppNotification]
    func markNotificationRead(id: UUID) async throws
    func markAllNotificationsRead(userID: UUID) async throws
    func deleteAllNotifications(userID: UUID) async throws
    func submitReview(gameID: UUID, userID: UUID, rating: Int, comment: String?) async throws
    func fetchClubReviews(clubID: UUID) async throws -> [GameReview]
    func fetchPendingReviewPrompt(userID: UUID) async throws -> PendingReviewPrompt?
    func dismissReviewPrompt(gameID: UUID) async throws
    func fetchClubRevenueSummary(clubID: UUID, days: Int?) async throws -> ClubRevenueSummary?
    func fetchClubFillRateSummary(clubID: UUID, days: Int?) async throws -> ClubFillRateSummary?

    // Phase 5B — Advanced Analytics
    func fetchClubAnalyticsKPIs(clubID: UUID, days: Int, startDate: Date?, endDate: Date?) async throws -> ClubAnalyticsKPIs?
    func fetchClubRevenueTrend(clubID: UUID, days: Int, startDate: Date?, endDate: Date?) async throws -> [ClubRevenueTrendPoint]
    func fetchClubTopGames(clubID: UUID, days: Int, startDate: Date?, endDate: Date?) async throws -> [ClubTopGame]
    func fetchClubPeakTimes(clubID: UUID, days: Int, startDate: Date?, endDate: Date?) async throws -> [ClubPeakTime]
    func fetchGame(gameID: UUID) async throws -> Game?
    func fetchGameClubID(gameID: UUID) async throws -> UUID?
    func updateProfilePushToken(userID: UUID, pushToken: String?) async throws
    func upsertProfile(_ profile: UserProfile) async throws -> UserProfile
    func patchProfile(_ profile: UserProfile) async throws -> UserProfile
    func updatePassword(_ newPassword: String) async throws

    /// Fetches all active, upcoming games within a bounded time window across all clubs.
    /// Used to power the "Games Near You" home section and nearby games discovery screen.
    func fetchUpcomingGames() async throws -> [Game]

    // Club Venues
    func fetchClubVenues(clubID: UUID) async throws -> [ClubVenue]
    func createClubVenue(clubID: UUID, draft: ClubVenueDraft, latitude: Double?, longitude: Double?) async throws -> ClubVenue
    func updateClubVenue(venueID: UUID, draft: ClubVenueDraft, latitude: Double?, longitude: Double?, updateCoordinates: Bool) async throws -> ClubVenue
    func deleteClubVenue(venueID: UUID) async throws
    func updateClubCoordinates(clubID: UUID, latitude: Double, longitude: Double) async throws
    func updateClubVenueName(clubID: UUID, venueName: String) async throws
    /// Sets is_primary = false on every venue for `clubID` except `exceptVenueID`.
    /// Call after saving a primary venue to enforce single-primary invariant.
    func demoteOtherPrimaryVenues(clubID: UUID, exceptVenueID: UUID) async throws

    // MARK: - Credits (Phase 2)
    /// Fetches the credit balance for a specific user at a specific club.
    func fetchCreditBalance(userID: UUID, clubID: UUID) async throws -> Int
    // MARK: - Waitlist Promotion (Phase 3)
    /// Atomically promotes a waitlisted booking to `pending_payment` with a timed hold.
    /// Returns `true` if the promotion succeeded.
    func promoteWaitlistPlayer(gameID: UUID, bookingID: UUID, holdMinutes: Int) async throws -> Bool
    /// Atomically deducts `amountCents` from the user's club-scoped credit balance. Returns `true` on success.
    func applyCredits(userID: UUID, bookingID: UUID, amountCents: Int, clubID: UUID) async throws -> Bool

    // MARK: - Notification Preferences
    /// Returns the stored preferences, or `nil` if no row exists yet (caller treats nil as all-defaults).
    func fetchNotificationPreferences(userID: UUID) async throws -> NotificationPreferences?
    /// Upserts the preferences row for the given user.
    func saveNotificationPreferences(userID: UUID, prefs: NotificationPreferences) async throws

    // MARK: - Club Dashboard Summary
    /// Fetches lightweight dashboard metrics available on all plan tiers.
    /// No analytics entitlement required.
    func fetchClubDashboardSummary(clubID: UUID) async throws -> ClubDashboardSummary?

    // MARK: - Analytics Supplemental
    /// Fetches operational + membership metrics. Requires Pro analytics entitlement.
    func fetchClubAnalyticsSupplemental(clubID: UUID, days: Int, startDate: Date?, endDate: Date?) async throws -> ClubAnalyticsSupplemental?

    // MARK: - Avatar Palettes
    /// Returns all active palette definitions from the canonical avatar_palettes table.
    func fetchAvatarPalettes() async throws -> [AvatarPaletteRow]

    // MARK: - Plan Tier Limits
    /// Returns canonical plan limit definitions for all tiers (free, starter, pro).
    /// Global constants — not per-club. iOS/Android/Web call this once at launch.
    func fetchPlanTierLimits() async throws -> [String: PlanTierLimits]

    /// Returns active subscription plan definitions from the subscription_plans table.
    /// Clients use the returned stripe_price_id and display_price — never hardcode either.
    func fetchSubscriptionPlans() async throws -> [SubscriptionPlan]

    // MARK: - App Config
    /// Returns all rows from the app_config table as a [key: value] dictionary.
    /// Server-authoritative runtime constants consumed by iOS, Android, and Edge Functions.
    func fetchAppConfig() async throws -> [String: String]
}

enum SupabaseServiceError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case authenticationRequired
    case duplicateMembership
    case notFound
    case holdExpired
    case membershipRequired
    case duprRequired
    case missingSession
    case httpStatus(Int, String)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Supabase is not configured."
        case .invalidURL:
            return "Supabase URL is invalid."
        case .authenticationRequired:
            return "Authentication is required for this action."
        case .duplicateMembership:
            return "Membership request already exists."
        case .notFound:
            return "Requested item was not found."
        case .holdExpired:
            return "Your spot hold has expired. The next player in the queue has been offered this spot."
        case .membershipRequired:
            return "You must be an approved club member to book this game."
        case .duprRequired:
            return "A valid DUPR ID is required to book this game."
        case .missingSession:
            return "No authenticated session is available."
        case let .httpStatus(code, body):
            return "Supabase request failed (\(code)): \(body)"
        case let .decoding(message):
            return "Failed to decode Supabase response: \(message)"
        case let .network(message):
            return "Network error: \(message)"
        }
    }
}

final class SupabaseService: ClubDataProviding {
    private let session: URLSession
    private let authAccessTokenProvider: () -> String?
    private var storedAccessToken: String?

    init(
        session: URLSession = .shared,
        authAccessTokenProvider: @escaping () -> String? = { nil }
    ) {
        self.session = session
        self.authAccessTokenProvider = authAccessTokenProvider
    }

    func setAccessToken(_ token: String?) {
        storedAccessToken = token
    }

    func signIn(email: String, password: String) async throws -> AuthFlowResult {
        let response: SupabaseAuthResponse = try await sendAuth(
            path: "token",
            queryItems: [.init(name: "grant_type", value: "password")],
            method: "POST",
            body: try JSONEncoder().encode(SupabaseEmailAuthRequest(email: email, password: password))
        )

        guard
            let accessToken = response.accessToken,
            let user = response.user,
            let userID = UUID(uuidString: user.id)
        else {
            throw SupabaseServiceError.missingSession
        }

        storedAccessToken = accessToken
        return .signedIn(
            AuthSessionInfo(
                accessToken: accessToken,
                refreshToken: response.refreshToken,
                userID: userID,
                email: user.email
            )
        )
    }

    func signUp(email: String, password: String) async throws -> AuthFlowResult {
        let response: SupabaseAuthResponse = try await sendAuth(
            path: "signup",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(SupabaseEmailAuthRequest(email: email, password: password))
        )

        if
            let accessToken = response.accessToken,
            let user = response.user,
            let userID = UUID(uuidString: user.id)
        {
            storedAccessToken = accessToken
            return .signedIn(
                AuthSessionInfo(
                    accessToken: accessToken,
                    refreshToken: response.refreshToken,
                    userID: userID,
                    email: user.email
                )
            )
        }

        return .requiresEmailConfirmation(email: email)
    }

    func refreshSession(refreshToken: String) async throws -> AuthSessionInfo {
        let response: SupabaseAuthResponse = try await sendAuth(
            path: "token",
            queryItems: [.init(name: "grant_type", value: "refresh_token")],
            method: "POST",
            body: try JSONEncoder().encode(SupabaseRefreshTokenRequest(refreshToken: refreshToken))
        )

        guard
            let accessToken = response.accessToken,
            let user = response.user,
            let userID = UUID(uuidString: user.id)
        else {
            throw SupabaseServiceError.missingSession
        }

        storedAccessToken = accessToken
        return AuthSessionInfo(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            userID: userID,
            email: user.email
        )
    }

    func fetchClubs() async throws -> [Club] {
        guard SupabaseConfig.isConfigured else {
            return MockData.clubs
        }

        // NOTE: PostgREST only returns columns you explicitly enumerate here.
        // `latitude` and `longitude` MUST stay in this list — removing them silently
        // decodes as nil and breaks NearbyDiscoveryView. Update ClubRow + toClub() together.
        let clubRows: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "select", value: "id,name,description,image_url,contact_email,contact_phone,website,manager_name,members_only,created_by,win_condition,default_court_count,venue_name,street_address,suburb,state,postcode,country,latitude,longitude,hero_image_key,custom_banner_url,code_of_conduct,cancellation_policy,stripe_connect_id,avatar_background_color,timezone")
            ],
            method: "GET",
            body: nil,
            authBearerToken: nil
        )

        let memberRows: [ClubMemberStatusRow] = (try? await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "club_id,status")
            ],
            method: "GET",
            body: nil,
            authBearerToken: nil
        )) ?? []

        let countsByClub = Self.buildMemberCounts(memberRows)
        let mockByName = Dictionary(uniqueKeysWithValues: MockData.clubs.map { ($0.name.lowercased(), $0) })

        return clubRows.map { row in
            let seed = mockByName[row.name.lowercased()]
            return row.toClub(
                memberCount: countsByClub[row.id] ?? 0,
                seedMembers: seed?.topMembers ?? [],
                seedTags: seed?.tags ?? []
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchClubDetail(id: UUID) async throws -> Club {
        guard SupabaseConfig.isConfigured else {
            return MockData.clubs.first(where: { $0.id == id }) ?? MockData.clubs[0]
        }

        let clubs: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "select", value: "id,name,description,image_url,contact_email,contact_phone,website,manager_name,members_only,created_by,win_condition,default_court_count,venue_name,street_address,suburb,state,postcode,country,latitude,longitude,hero_image_key,custom_banner_url,code_of_conduct,cancellation_policy,stripe_connect_id,avatar_background_color,timezone"),
                .init(name: "id", value: "eq.\(id.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: nil
        )

        guard let row = clubs.first else { throw SupabaseServiceError.notFound }

        let memberRows: [ClubMemberStatusRow] = (try? await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "club_id,status"),
                .init(name: "club_id", value: "eq.\(id.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: nil
        )) ?? []

        let memberCount = Self.buildMemberCounts(memberRows)[id] ?? 0
        let seed = MockData.clubs.first(where: { $0.name.caseInsensitiveCompare(row.name) == .orderedSame })
        return row.toClub(
            memberCount: memberCount,
            seedMembers: seed?.topMembers ?? [],
            seedTags: seed?.tags ?? []
        )
    }

    func fetchGames(clubID: UUID) async throws -> [Game] {
        guard SupabaseConfig.isConfigured else { return [] }

        let gameRows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,status,notes,requires_dupr,recurrence_group_id,publish_at"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "archived_at", value: "is.null"),  // exclude archived games
                .init(name: "order", value: "date_time.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        let bookingRows: [GameBookingStatusRow] = (try? await send(
            path: "bookings",
            queryItems: [
                .init(name: "select", value: "game_id,status"),
                .init(name: "game_id", value: "in.(\(clubIDGamesList(from: gameRows)))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []

        let countsByGame = Self.buildBookingCounts(bookingRows)
        return gameRows.map { row in
            let counts = countsByGame[row.id]
            return row.toGame(confirmedCount: counts?.confirmed, waitlistCount: counts?.waitlisted)
        }
    }

    func fetchUpcomingGames() async throws -> [Game] {
        guard SupabaseConfig.isConfigured else { return [] }

        // Bounded 14-day window — keeps the payload small and the results actionable.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowStr       = iso.string(from: Date())
        let windowEndStr = iso.string(from: Date().addingTimeInterval(14 * 24 * 3600))

        let gameRows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select",       value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,latitude,longitude,status,notes,requires_dupr,recurrence_group_id,publish_at"),
                .init(name: "date_time",    value: "gte.\(nowStr)"),
                .init(name: "date_time",    value: "lte.\(windowEndStr)"),
                .init(name: "archived_at",  value: "is.null"),
                .init(name: "or",           value: "(publish_at.is.null,publish_at.lte.\(nowStr))"),
                .init(name: "order",        value: "date_time.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        guard !gameRows.isEmpty else { return [] }

        let bookingRows: [GameBookingStatusRow] = (try? await send(
            path: "bookings",
            queryItems: [
                .init(name: "select",  value: "game_id,status"),
                .init(name: "game_id", value: "in.(\(clubIDGamesList(from: gameRows)))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []

        let countsByGame = Self.buildBookingCounts(bookingRows)
        return gameRows.map { row in
            let counts = countsByGame[row.id]
            return row.toGame(confirmedCount: counts?.confirmed, waitlistCount: counts?.waitlisted)
        }
    }

    func fetchGamesInSeries(recurrenceGroupID: UUID) async throws -> [Game] {
        guard SupabaseConfig.isConfigured else { return [] }

        let gameRows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,status,notes,requires_dupr,recurrence_group_id,publish_at"),
                .init(name: "recurrence_group_id", value: "eq.\(recurrenceGroupID.uuidString)"),
                .init(name: "order", value: "date_time.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        return gameRows.map { $0.toGame(confirmedCount: nil, waitlistCount: nil) }
    }

    func fetchUserBookings(userID: UUID) async throws -> [BookingWithGame] {
        guard SupabaseConfig.isConfigured else { return [] }

        let bookingRows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method,platform_fee_cents,club_payout_cents,credits_applied_cents,hold_expires_at,games(id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,status,notes,requires_dupr,recurrence_group_id,publish_at)"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "order", value: "created_at.desc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        return bookingRows.map { row in
            BookingWithGame(
                booking: row.toBookingRecord(),
                game: row.gameRow?.toGame(confirmedCount: nil, waitlistCount: nil)
            )
        }
    }

    func fetchGameAttendees(gameID: UUID) async throws -> [GameAttendee] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let bookingRows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method,platform_fee_cents,club_payout_cents,credits_applied_cents,hold_expires_at"),
                .init(name: "game_id", value: "eq.\(gameID.uuidString)"),
                .init(name: "order", value: "created_at.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        let userIDs = Array(Set(bookingRows.map(\.userID)))
        let profileRows: [OwnerProfileLiteRow] = userIDs.isEmpty ? [] : (try? await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,full_name,email,phone,emergency_contact_name,emergency_contact_phone,dupr_rating,avatar_color_key"),
                .init(name: "id", value: "in.(\(userIDs.map(\.uuidString).joined(separator: ",")))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )) ?? []
        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })

        return bookingRows
            .map { row in
                let profile = profilesByID[row.userID]
                let trimmed = profile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return GameAttendee(
                    booking: row.toBookingRecord(),
                    userName: trimmed.isEmpty ? "Member" : trimmed,
                    userEmail: profile?.email,
                    duprRating: profile?.duprRating,
                    avatarColorKey: profile?.avatarColorKey
                )
            }
            .sorted { lhs, rhs in
                self.attendeeComparator(lhs: lhs, rhs: rhs)
            }
    }

    func fetchAttendanceRecords(gameID: UUID) async throws -> AttendanceRecords {
        guard SupabaseConfig.isConfigured else { return AttendanceRecords(attendanceStatusByBookingID: [:], paymentByBookingID: [:]) }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [GameAttendanceRow] = try await send(
            path: "game_attendance",
            queryItems: [
                .init(name: "select", value: "booking_id,payment_status,attendance_status"),
                .init(name: "game_id", value: "eq.\(gameID.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        var attendanceStatusByBookingID: [UUID: String] = [:]
        var paymentByBookingID: [UUID: String] = [:]
        for row in rows {
            attendanceStatusByBookingID[row.bookingID] = row.attendanceStatus ?? "attended"
            paymentByBookingID[row.bookingID] = row.paymentStatus ?? "unpaid"
        }
        return AttendanceRecords(
            attendanceStatusByBookingID: attendanceStatusByBookingID,
            paymentByBookingID: paymentByBookingID
        )
    }

    func updateAttendancePaymentStatus(bookingID: UUID, status: String) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct PaymentStatusPatch: Encodable {
            let paymentStatus: String
            enum CodingKeys: String, CodingKey { case paymentStatus = "payment_status" }
        }

        let _: [GameAttendanceRow] = try await send(
            path: "game_attendance",
            queryItems: [
                .init(name: "booking_id", value: "eq.\(bookingID.uuidString)"),
                .init(name: "select", value: "booking_id,payment_status")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(PaymentStatusPatch(paymentStatus: status)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json", "Prefer": "return=representation"]
        )
    }

    func fetchMemberships(userID: UUID) async throws -> [ClubMembershipRecord] {
        guard SupabaseConfig.isConfigured else { return [] }

        let rows: [ClubMembershipUserRow] = try await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "club_id,user_id,status"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        return rows.map { row in
            ClubMembershipRecord(
                clubID: row.clubID,
                userID: row.userID,
                status: ClubMembershipStateMapper.map(raw: row.status)
            )
        }
    }

    func fetchPendingClubJoinRequests(clubID: UUID) async throws -> [ClubJoinRequest] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [ClubJoinRequestRow] = try await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "id,club_id,user_id,status,requested_at"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "status", value: "eq.pending"),
                .init(name: "order", value: "requested_at.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        let userIDs = Array(Set(rows.map(\.userID)))
        var profilesByID: [UUID: OwnerProfileLiteRow] = [:]
        if !userIDs.isEmpty {
            let profileRows: [OwnerProfileLiteRow] = (try? await send(
                path: "profiles",
                queryItems: [
                    .init(name: "select", value: "id,full_name,email"),
                    .init(name: "id", value: "in.(\(userIDs.map(\.uuidString).joined(separator: ",")))")
                ],
                method: "GET",
                body: nil,
                authBearerToken: authToken
            )) ?? []
            profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })
        }

        return rows.map { row in
            let profile = profilesByID[row.userID]
            return ClubJoinRequest(
                id: row.id,
                clubID: row.clubID,
                userID: row.userID,
                status: ClubMembershipStateMapper.map(raw: row.status),
                requestedAt: row.requestedAtRaw.flatMap(SupabaseDateParser.parse),
                memberName: (profile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? (profile?.fullName ?? "Member")
                    : "Member",
                memberEmail: profile?.email
            )
        }
    }

    func fetchOwnerClubMembers(clubID: UUID, ownerUserID: UUID?) async throws -> [ClubOwnerMember] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let membershipRows: [ClubJoinRequestRow] = try await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "id,club_id,user_id,status,requested_at,conduct_accepted_at,cancellation_policy_accepted_at"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "status", value: "eq.approved"),
                .init(name: "order", value: "requested_at.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        let adminRows: [ClubAdminRow] = (try? await send(
            path: "club_admins",
            queryItems: [
                .init(name: "select", value: "club_id,user_id,role"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )) ?? []

        let userIDs = Array(Set(membershipRows.map(\.userID)))
        let profileRows: [OwnerProfileLiteRow] = userIDs.isEmpty ? [] : (try? await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,full_name,email,phone,emergency_contact_name,emergency_contact_phone,dupr_rating,dupr_updated_at,dupr_updated_by_name,avatar_color_key"),
                .init(name: "id", value: "in.(\(userIDs.map(\.uuidString).joined(separator: ",")))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )) ?? []

        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })
        let adminsByUserID = Dictionary(uniqueKeysWithValues: adminRows.map { ($0.userID, $0) })

        return membershipRows.map { row in
            let profile = profilesByID[row.userID]
            let adminRow = adminsByUserID[row.userID]
            let fullName = profile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClubOwnerMember(
                membershipRecordID: row.id,
                userID: row.userID,
                clubID: row.clubID,
                membershipStatus: ClubMembershipStateMapper.map(raw: row.status),
                memberName: (fullName?.isEmpty == false) ? (fullName ?? "Member") : "Member",
                memberEmail: profile?.email,
                memberPhone: profile?.phone,
                emergencyContactName: profile?.emergencyContactName,
                emergencyContactPhone: profile?.emergencyContactPhone,
                isAdmin: adminRow != nil,
                isOwner: ownerUserID == row.userID || adminRow?.role == .owner,
                adminRole: adminRow?.role,
                conductAcceptedAt: row.conductAcceptedAtRaw.flatMap(SupabaseDateParser.parse),
                cancellationPolicyAcceptedAt: row.cancellationPolicyAcceptedAtRaw.flatMap(SupabaseDateParser.parse),
                duprRating: profile?.duprRating,
                duprUpdatedAt: profile?.duprUpdatedAtRaw.flatMap(SupabaseDateParser.parse),
                duprUpdatedByName: profile?.duprUpdatedByName,
                avatarColorKey: profile?.avatarColorKey
            )
        }
        .sorted { lhs, rhs in
            if lhs.isOwner != rhs.isOwner { return lhs.isOwner && !rhs.isOwner }
            if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin && !rhs.isAdmin }
            return lhs.memberName.localizedCaseInsensitiveCompare(rhs.memberName) == .orderedAscending
        }
    }

    func fetchClubDirectoryMembers(clubID: UUID) async throws -> [ClubDirectoryMember] {
        guard SupabaseConfig.isConfigured else {
            return MockData.clubs.first(where: { $0.id == clubID })?.topMembers.map {
                ClubDirectoryMember(id: $0.id, name: $0.name, duprRating: $0.rating, avatarColorKey: nil)
            } ?? []
        }

        let membershipRows: [ClubJoinRequestRow] = try await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "id,club_id,user_id,status,requested_at"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "status", value: "eq.approved")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        let userIDs = Array(Set(membershipRows.map(\.userID)))
        guard !userIDs.isEmpty else { return [] }

        let profileRows: [ClubDirectoryProfileRow] = (try? await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,full_name,dupr_rating,avatar_color_key"),
                .init(name: "id", value: "in.(\(userIDs.map(\.uuidString).joined(separator: ",")))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []

        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })
        return membershipRows.compactMap { row in
            guard let profile = profilesByID[row.userID] else { return nil }
            let name = Self.displayName(profile.fullName)
            return ClubDirectoryMember(id: row.userID, name: name, duprRating: profile.duprRating, avatarColorKey: profile.avatarColorKey)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchClubAdminRole(clubID: UUID, userID: UUID) async throws -> ClubAdminRole? {
        guard SupabaseConfig.isConfigured else { return nil }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [ClubAdminRow] = try await send(
            path: "club_admins",
            queryItems: [
                .init(name: "select", value: "club_id,user_id,role"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.first?.role
    }

    func fetchAllAdminRoles(userID: UUID) async throws -> [UUID: ClubAdminRole] {
        guard SupabaseConfig.isConfigured else { return [:] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [ClubAdminRow] = try await send(
            path: "club_admins",
            queryItems: [
                .init(name: "select", value: "club_id,user_id,role"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.reduce(into: [:]) { dict, row in
            if let role = row.role { dict[row.clubID] = role }
        }
    }

    func fetchClubNewsPosts(clubID: UUID, currentUserID: UUID?) async throws -> [ClubNewsPost] {
        guard SupabaseConfig.isConfigured else { return [] }

        let postRows: [FeedPostRow] = try await send(
            path: "feed_posts",
            queryItems: [
                .init(name: "select", value: "id,user_id,content,image_url,image_urls,created_at,updated_at,club_id,is_announcement"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "order", value: "is_announcement.desc,created_at.desc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )

        guard !postRows.isEmpty else { return [] }

        let postIDList = postRows.map(\.id.uuidString).joined(separator: ",")

        // Fetch comments and reactions concurrently — both depend only on postIDList
        async let commentRowsTask: [FeedCommentRow] = send(
            path: "feed_comments",
            queryItems: [
                .init(name: "select", value: "id,post_id,user_id,content,created_at,parent_id"),
                .init(name: "post_id", value: "in.(\(postIDList))"),
                .init(name: "order", value: "created_at.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )
        async let reactionRowsTask: [FeedReactionRow] = send(
            path: "feed_reactions",
            queryItems: [
                .init(name: "select", value: "id,post_id,user_id,reaction_type,created_at"),
                .init(name: "post_id", value: "in.(\(postIDList))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )
        let commentRows = (try? await commentRowsTask) ?? []
        let reactionRows = (try? await reactionRowsTask) ?? []

        // userID is now optional (null when poster/commenter deleted account) — compact to avoid profile fetches for nil IDs
        let userIDs = Set(postRows.compactMap(\.userID)).union(commentRows.compactMap(\.userID))
        // Only fetch id + full_name — email and other fields are not used here
        let profileRows: [OwnerProfileLiteRow] = userIDs.isEmpty ? [] : (try? await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,full_name,avatar_color_key"),
                .init(name: "id", value: "in.(\(userIDs.map(\.uuidString).joined(separator: ",")))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []
        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })

        let commentsByPost = Dictionary(grouping: commentRows, by: \.postID)
        let reactionsByPost = Dictionary(grouping: reactionRows, by: \.postID)

        // Placeholder UUID for posts/comments whose author deleted their account
        let deletedUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        return postRows.map { row in
            let resolvedUserID = row.userID ?? deletedUserID
            let profile = profilesByID[resolvedUserID]
            let authorName = Self.displayName(profile?.fullName)
            let comments = (commentsByPost[row.id] ?? []).map { commentRow in
                let commentUserID = commentRow.userID ?? deletedUserID
                let commentProfile = profilesByID[commentUserID]
                return ClubNewsComment(
                    id: commentRow.id,
                    postID: commentRow.postID,
                    userID: commentUserID,
                    authorName: Self.displayName(commentProfile?.fullName),
                    avatarColorKey: commentProfile?.avatarColorKey,
                    content: commentRow.content ?? "",
                    createdAt: commentRow.createdAtRaw.flatMap(SupabaseDateParser.parse),
                    parentID: commentRow.parentID
                )
            }
            let reactions = reactionsByPost[row.id] ?? []
            let likeRows = reactions.filter { $0.reactionType.lowercased() == "like" }
            let isLikedByMe = currentUserID.map { uid in likeRows.contains(where: { $0.userID == uid }) } ?? false
            return ClubNewsPost(
                id: row.id,
                clubID: row.clubID ?? clubID,
                userID: resolvedUserID,
                authorName: authorName,
                avatarColorKey: profile?.avatarColorKey,
                content: row.content ?? "",
                imageURLs: row.imageURLsResolved,
                createdAt: row.createdAtRaw.flatMap(SupabaseDateParser.parse),
                updatedAt: row.updatedAtRaw.flatMap(SupabaseDateParser.parse),
                comments: comments,
                likeCount: likeRows.count,
                isLikedByCurrentUser: isLikedByMe,
                isAnnouncement: row.isAnnouncement ?? false
            )
        }
    }

    func updateClubNewsPost(postID: UUID, content: String, imageURLs: [URL]) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let body = FeedPostUpdateBody(
            content: content,
            imageURL: imageURLs.first?.absoluteString ?? "",
            imageURLs: imageURLs.map(\.absoluteString)
        )
        let _: [FeedIDRow] = try await send(
            path: "feed_posts",
            queryItems: [
                .init(name: "id", value: "eq.\(postID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(body),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func uploadClubAvatarImage(_ data: Data, clubID: UUID) async throws -> URL {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let bucket = SupabaseConfig.clubImageBucket
        let objectPath = "club-avatars/\(clubID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await uploadStorageObject(bucket: bucket, objectPath: objectPath,
                                      data: data, contentType: "image/jpeg",
                                      authBearerToken: authToken)
        return publicStorageURL(bucket: bucket, objectPath: objectPath)
    }

    func uploadClubBannerImage(_ data: Data, clubID: UUID) async throws -> URL {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let bucket = SupabaseConfig.clubImageBucket
        let objectPath = "club-banners/\(clubID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await uploadStorageObject(bucket: bucket, objectPath: objectPath,
                                      data: data, contentType: "image/jpeg",
                                      authBearerToken: authToken)
        return publicStorageURL(bucket: bucket, objectPath: objectPath)
    }

    func uploadClubNewsImage(_ image: FeedImageUploadPayload, userID: UUID, clubID: UUID) async throws -> URL {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let bucket = SupabaseConfig.clubNewsImageBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else {
            throw SupabaseServiceError.network("Club news image bucket is not configured.")
        }

        let fileName = "\(UUID().uuidString.lowercased()).\(image.fileExtension)"
        let objectPath = "club-news/\(clubID.uuidString.lowercased())/\(userID.uuidString.lowercased())/\(fileName)"
        try await uploadStorageObject(
            bucket: bucket,
            objectPath: objectPath,
            data: image.data,
            contentType: image.contentType,
            authBearerToken: authToken
        )
        return publicStorageURL(bucket: bucket, objectPath: objectPath)
    }

    func deleteClubNewsImages(_ imageURLs: [URL]) async throws {
        guard SupabaseConfig.isConfigured else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let bucket = SupabaseConfig.clubNewsImageBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else { return }

        let objectPaths = imageURLs.compactMap { storageObjectPathIfManagedClubNewsURL($0, bucket: bucket) }
        guard !objectPaths.isEmpty else { return }

        for path in Array(Set(objectPaths)) {
            try await deleteStorageObject(bucket: bucket, objectPath: path, authBearerToken: authToken)
        }
    }

    func deleteClubStorageImage(at url: URL) async throws {
        guard SupabaseConfig.isConfigured else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let bucket = SupabaseConfig.clubImageBucket
        let prefix = "/storage/v1/object/public/\(bucket)/"
        guard let baseURL = URL(string: SupabaseConfig.urlString),
              url.host == baseURL.host,
              url.path.hasPrefix(prefix) else { return }
        let rawPath = String(url.path.dropFirst(prefix.count))
        let objectPath = rawPath.removingPercentEncoding ?? rawPath
        guard !objectPath.isEmpty else { return }
        try await deleteStorageObject(bucket: bucket, objectPath: objectPath, authBearerToken: authToken)
    }

    func createClubNewsPost(clubID: UUID, userID: UUID, content: String, imageURLs: [URL], isAnnouncement: Bool) async throws -> UUID? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let body = FeedPostInsertBody(
            userID: userID,
            content: content,
            imageURL: imageURLs.first?.absoluteString,
            clubID: clubID,
            imageURLs: imageURLs.map(\.absoluteString),
            isAnnouncement: isAnnouncement
        )
        let rows: [FeedIDRow] = try await send(
            path: "feed_posts",
            queryItems: [.init(name: "select", value: "id")],
            method: "POST",
            body: try JSONEncoder().encode([body]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
        return rows.first?.id
    }

    func toggleClubNewsLike(postID: UUID, userID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let existing: [FeedReactionRow] = try await send(
            path: "feed_reactions",
            queryItems: [
                .init(name: "select", value: "id,post_id,user_id,reaction_type,created_at"),
                .init(name: "post_id", value: "eq.\(postID.uuidString)"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "reaction_type", value: "eq.like"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        if let row = existing.first {
            let _: [FeedIDRow] = try await send(
                path: "feed_reactions",
                queryItems: [
                    .init(name: "id", value: "eq.\(row.id.uuidString)"),
                    .init(name: "select", value: "id")
                ],
                method: "DELETE",
                body: nil,
                authBearerToken: authToken,
                extraHeaders: ["Prefer": "return=representation"]
            )
        } else {
            let insert = FeedReactionInsertBody(postID: postID, userID: userID, reactionType: "like")
            let _: [FeedReactionRow] = try await send(
                path: "feed_reactions",
                queryItems: [.init(name: "select", value: "id,post_id,user_id,reaction_type,created_at")],
                method: "POST",
                body: try JSONEncoder().encode([insert]),
                authBearerToken: authToken,
                extraHeaders: [
                    "Prefer": "return=representation",
                    "Content-Type": "application/json"
                ]
            )
        }
    }

    func createClubNewsComment(postID: UUID, userID: UUID, content: String, parentCommentID: UUID?) async throws -> UUID? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let body = FeedCommentInsertBody(postID: postID, userID: userID, content: content, parentID: parentCommentID)
        let rows: [FeedCommentRow] = try await send(
            path: "feed_comments",
            queryItems: [.init(name: "select", value: "id,post_id,user_id,content,created_at,parent_id")],
            method: "POST",
            body: try JSONEncoder().encode([body]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
        return rows.first?.id
    }

    func deleteClubNewsComment(commentID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let _: [FeedIDRow] = try await send(
            path: "feed_comments",
            queryItems: [
                .init(name: "id", value: "eq.\(commentID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation"]
        )
    }

    func deleteClubNewsPost(postID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let _: [FeedIDRow] = try await send(
            path: "feed_posts",
            queryItems: [
                .init(name: "id", value: "eq.\(postID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation"]
        )
    }

    func createClubNewsModerationReport(
        clubID: UUID,
        senderUserID: UUID,
        targetKind: ClubNewsModerationReport.TargetKind,
        targetID: UUID?,
        reason: String,
        details: String
    ) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let subject = "REPORT_\(targetKind.rawValue.uppercased())\(targetID.map { ":\($0.uuidString.lowercased())" } ?? "")"
        let reportBody = ClubNewsReportMessageBody(
            reason: reason,
            details: details,
            targetKind: targetKind.rawValue,
            targetID: targetID?.uuidString.lowercased()
        )
        let encodedDetails = (try? String(data: JSONEncoder().encode(reportBody), encoding: .utf8)) ?? details
        let insert = ClubMessageInsertBody(
            clubID: clubID,
            senderID: senderUserID,
            parentID: nil,
            subject: subject,
            body: encodedDetails
        )
        struct IDOnly: Decodable { let id: UUID }
        let _: [IDOnly] = try await send(
            path: "club_messages",
            queryItems: [.init(name: "select", value: "id")],
            method: "POST",
            body: try JSONEncoder().encode([insert]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func fetchClubNewsModerationReports(clubID: UUID) async throws -> [ClubNewsModerationReport] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [ClubMessageRow] = try await send(
            path: "club_messages",
            queryItems: [
                .init(name: "select", value: "id,club_id,sender_id,parent_id,subject,body,read,created_at"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "subject", value: "like.REPORT_%"),
                .init(name: "order", value: "created_at.desc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        let senderIDs = Array(Set(rows.map(\.senderID)))
        let profileRows: [OwnerProfileLiteRow] = senderIDs.isEmpty ? [] : (try? await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,full_name,email"),
                .init(name: "id", value: "in.(\(senderIDs.map(\.uuidString).joined(separator: ",")))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )) ?? []
        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })

        return rows.map { row in
            let parsed = parseModerationReport(from: row)
            return ClubNewsModerationReport(
                id: row.id,
                clubID: row.clubID,
                senderUserID: row.senderID,
                senderName: Self.displayName(profilesByID[row.senderID]?.fullName),
                targetKind: parsed.targetKind,
                targetID: parsed.targetID,
                reason: parsed.reason,
                details: parsed.details,
                createdAt: row.createdAtRaw.flatMap(SupabaseDateParser.parse)
            )
        }
    }

    func resolveClubNewsModerationReport(reportID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let _: [FeedIDRow] = try await send(
            path: "club_messages",
            queryItems: [
                .init(name: "id", value: "eq.\(reportID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation"]
        )
    }

    func triggerClubChatPushHook(clubID: UUID, actorUserID: UUID, event: String, referenceID: UUID?, postAuthorID: UUID?, content: String?) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let functionName = SupabaseConfig.clubChatPushHookFunctionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !functionName.isEmpty else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        let url = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(functionName)

        let payload = ClubChatPushHookRequest(
            clubID: clubID,
            actorUserID: actorUserID,
            event: event,
            referenceID: referenceID,
            postAuthorID: postAuthorID,
            content: content
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }
    }

    func triggerBookingConfirmedPush(gameID: UUID, bookingID: UUID, userID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let functionName = SupabaseConfig.bookingConfirmedPushFunctionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !functionName.isEmpty else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        let url = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(functionName)

        let payload = BookingConfirmedPushRequest(gameID: gameID, bookingID: bookingID, userID: userID)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }
    }

    func triggerGameUpdatedNotify(gameID: UUID, clubID: UUID, gameTitle: String, clubName: String, gameDateTime: Date?, changedFields: [String], clubTimezone: String) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let functionName = SupabaseConfig.gameUpdatedNotifyFunctionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !functionName.isEmpty else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        let url = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(functionName)

        struct Payload: Encodable {
            let game_id: String
            let club_id: String
            let game_title: String
            let club_name: String
            let game_date_time: String?
            let changed_fields: [String]
            let club_timezone: String
        }

        let iso = ISO8601DateFormatter()
        let payload = Payload(
            game_id: gameID.uuidString,
            club_id: clubID.uuidString,
            game_title: gameTitle,
            club_name: clubName,
            game_date_time: gameDateTime.map { iso.string(from: $0) },
            changed_fields: changedFields,
            club_timezone: clubTimezone
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }
    }

    func fetchProfile(userID: UUID) async throws -> UserProfile? {
        guard SupabaseConfig.isConfigured else { return nil }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,email,first_name,last_name,full_name,phone,date_of_birth,emergency_contact_name,emergency_contact_phone,dupr_rating,dupr_id,avatar_color_key"),
                .init(name: "id", value: "eq.\(userID.uuidString)"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        guard let row = rows.first else { return nil }
        return UserProfile(
            id: row.id,
            firstName: row.firstName,
            lastName: row.lastName,
            fullName: row.fullName ?? "",
            email: row.email,
            phone: row.phone,
            dateOfBirth: row.dateOfBirth.flatMap { Self.isoDateFormatter.date(from: $0) },
            emergencyContactName: row.emergencyContactName,
            emergencyContactPhone: row.emergencyContactPhone,
            duprRating: row.duprRating,
            duprID: row.duprID,
            favoriteClubName: nil,
            skillLevel: .beginner,
            avatarColorKey: row.avatarColorKey
        )
    }

    func patchDuprID(userID: UUID, duprID: String) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct DuprIDPatch: Encodable {
            let duprID: String
            enum CodingKeys: String, CodingKey { case duprID = "dupr_id" }
        }

        let _: [[String: String]] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
                .init(name: "select", value: "id")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(DuprIDPatch(duprID: duprID)),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func requestMembership(clubID: UUID, userID: UUID, conductAcceptedAt: Date?, cancellationPolicyAcceptedAt: Date?) async throws -> ClubMembershipState {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ClubMembershipInsertBody(
            clubID: clubID,
            userID: userID,
            conductAcceptedAt: conductAcceptedAt.map { SupabaseDateWriter.string(from: $0) },
            cancellationPolicyAcceptedAt: cancellationPolicyAcceptedAt.map { SupabaseDateWriter.string(from: $0) }
        )

        do {
            let createdRows: [ClubMembershipUserRow] = try await send(
                path: "club_members",
                queryItems: [
                    .init(name: "select", value: "club_id,user_id,status")
                ],
                method: "POST",
                body: try JSONEncoder().encode([payload]),
                authBearerToken: authToken,
                extraHeaders: [
                    "Prefer": "return=representation",
                    "Content-Type": "application/json"
                ]
            )

            if let created = createdRows.first {
                return ClubMembershipStateMapper.map(raw: created.status)
            }
            return .pending
        } catch let error as SupabaseServiceError {
            if case let .httpStatus(code, _) = error, code == 409 {
                throw SupabaseServiceError.duplicateMembership
            }
            throw error
        } catch {
            throw error
        }
    }

    func updateClubJoinRequest(requestID: UUID, status: String, respondedBy: UUID?) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ClubMembershipDecisionUpdateBody(
            status: status,
            respondedAt: SupabaseDateWriter.string(from: Date()),
            respondedBy: respondedBy
        )

        let _: [ClubJoinRequestRow] = try await send(
            path: "club_members",
            queryItems: [
                .init(name: "id", value: "eq.\(requestID.uuidString)"),
                .init(name: "select", value: "id,club_id,user_id,status,requested_at")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(payload),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func setClubAdminAccess(clubID: UUID, userID: UUID, makeAdmin: Bool) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        if makeAdmin {
            let body = ClubAdminUpsertBody(clubID: clubID, userID: userID, role: .admin)
            let _: [ClubAdminRow] = try await send(
                path: "club_admins",
                queryItems: [
                    .init(name: "select", value: "club_id,user_id,role"),
                    .init(name: "on_conflict", value: "club_id,user_id")
                ],
                method: "POST",
                body: try JSONEncoder().encode([body]),
                authBearerToken: authToken,
                extraHeaders: [
                    "Prefer": "resolution=merge-duplicates,return=representation",
                    "Content-Type": "application/json"
                ]
            )
        } else {
            let _: [ClubAdminRow] = try await send(
                path: "club_admins",
                queryItems: [
                    .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                    .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                    .init(name: "select", value: "club_id,user_id,role")
                ],
                method: "DELETE",
                body: nil,
                authBearerToken: authToken,
                extraHeaders: [
                    "Prefer": "return=representation"
                ]
            )
        }
    }

    func adminUpdateMemberDUPR(memberUserID: UUID, rating: Double) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let memberUserID: UUID
            let newRating: Double
            enum CodingKeys: String, CodingKey {
                case memberUserID = "member_user_id"
                case newRating = "new_rating"
            }
        }

        let _: [String: String]? = try await send(
            path: "rpc/admin_update_member_dupr",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(memberUserID: memberUserID, newRating: rating)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )
    }

    func createClub(createdBy: UUID, draft: ClubOwnerEditDraft) async throws -> Club {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ClubInsertRow(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nilIfEmpty(draft.description),
            imageURL: draft.imageURLStringForSave ?? "",
            contactEmail: nilIfEmpty(draft.contactEmail),
            contactPhone: nilIfEmpty(draft.contactPhone),
            website: nilIfEmpty(draft.website),
            managerName: nilIfEmpty(draft.managerName),
            membersOnly: draft.membersOnly,
            createdBy: createdBy,
            winCondition: draft.winCondition.rawValue,
            venueName: nilIfEmpty(draft.venueName),
            streetAddress: nilIfEmpty(draft.streetAddress),
            suburb: nilIfEmpty(draft.suburb),
            state: nilIfEmpty(draft.state),
            postcode: nilIfEmpty(draft.postcode),
            country: nilIfEmpty(draft.country),
            heroImageKey: draft.heroImageKey,
            customBannerURL: draft.customBannerURLStringForSave,
            avatarBackgroundColor: draft.avatarBackgroundColor,
            timezone: TimeZone.current.identifier
        )

        let createdRows: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "select", value: "id,name,description,image_url,contact_email,contact_phone,website,manager_name,members_only,created_by,win_condition,default_court_count,venue_name,street_address,suburb,state,postcode,country,latitude,longitude,hero_image_key,custom_banner_url,code_of_conduct,cancellation_policy,stripe_connect_id,avatar_background_color,timezone")
            ],
            method: "POST",
            body: try JSONEncoder().encode([payload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let created = createdRows.first else { throw SupabaseServiceError.notFound }

        let ownerAdminPayload = ClubAdminUpsertBody(clubID: created.id, userID: createdBy, role: .owner)
        let _: [ClubAdminRow]? = try? await send(
            path: "club_admins",
            queryItems: [
                .init(name: "select", value: "club_id,user_id,role"),
                .init(name: "on_conflict", value: "club_id,user_id")
            ],
            method: "POST",
            body: try JSONEncoder().encode([ownerAdminPayload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "resolution=merge-duplicates,return=representation",
                "Content-Type": "application/json"
            ]
        )

        let ownerMembershipPayload = ClubMembershipOwnerInsertBody(clubID: created.id, userID: createdBy, status: "approved")
        let _: [ClubMembershipUserRow]? = try? await send(
            path: "club_members",
            queryItems: [
                .init(name: "select", value: "club_id,user_id,status"),
                .init(name: "on_conflict", value: "club_id,user_id")
            ],
            method: "POST",
            body: try JSONEncoder().encode([ownerMembershipPayload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "resolution=merge-duplicates,return=representation",
                "Content-Type": "application/json"
            ]
        )

        return (try? await fetchClubDetail(id: created.id)) ?? created.toClub(
            memberCount: 1,
            seedMembers: [],
            seedTags: []
        )
    }

    func createGame(for clubID: UUID, createdBy: UUID, draft: ClubOwnerGameDraft, recurrenceGroupID: UUID? = nil) async throws -> Game {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let feeText = draft.feeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let feeAmount = feeText.isEmpty ? nil : Double(feeText)

        let payload = GameInsertRow(
            clubID: clubID,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nilIfEmpty(draft.description),
            dateTime: SupabaseDateWriter.string(from: draft.startDate),
            durationMinutes: max(draft.durationMinutes, 15),
            maxSpots: max(draft.maxSpots, 1),
            courtCount: max(draft.courtCount, 1),
            feeAmount: feeAmount,
            feeCurrency: "aud",
            venueId: draft.selectedVenueID,
            venueName: nilIfEmpty(draft.venueName),
            latitude: draft.venueLatitude,
            longitude: draft.venueLongitude,
            location: nilIfEmpty(draft.location),
            notes: nilIfEmpty(draft.notes),
            createdBy: createdBy,
            requiresDUPR: draft.requiresDUPR,
            skillLevel: draft.skillLevelRaw,
            gameFormat: draft.gameFormatRaw,
            gameType: draft.gameTypeRaw,
            recurrenceGroupID: recurrenceGroupID,
            publishAt: draft.publishAt.map { SupabaseDateWriter.string(from: $0) }
        )

        let rows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,status,notes,requires_dupr,recurrence_group_id,publish_at")
            ],
            method: "POST",
            body: try JSONEncoder().encode([payload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return row.toGame(confirmedCount: 0, waitlistCount: 0)
    }

    func updateGame(gameID: UUID, draft: ClubOwnerGameDraft) async throws -> Game {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let feeText = draft.feeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let feeAmount = feeText.isEmpty ? nil : Double(feeText)

        let payload = GameOwnerUpdateRow(
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: normalizedGameTextField(draft.description),
            dateTime: SupabaseDateWriter.string(from: draft.startDate),
            durationMinutes: max(draft.durationMinutes, 15),
            skillLevel: draft.skillLevelRaw,
            gameFormat: draft.gameFormatRaw,
            gameType: draft.gameTypeRaw,
            maxSpots: max(draft.maxSpots, 1),
            courtCount: max(draft.courtCount, 1),
            feeAmount: feeAmount,
            feeCurrency: "aud",
            venueId: draft.selectedVenueID,
            venueName: nilIfEmpty(draft.venueName),
            location: normalizedGameTextField(draft.location),
            notes: normalizedGameTextField(draft.notes),
            requiresDUPR: draft.requiresDUPR,
            // Only write coordinates when a saved venue was applied this session.
            // This preserves existing game coordinates when only non-venue fields change.
            updateCoordinates: draft.selectedVenueID != nil,
            latitude: draft.venueLatitude,
            longitude: draft.venueLongitude,
            publishAt: draft.publishAt.map { SupabaseDateWriter.string(from: $0) }
        )

        let rows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "id", value: "eq.\(gameID.uuidString)"),
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,status,notes,requires_dupr,recurrence_group_id,publish_at")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(payload),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return row.toGame(confirmedCount: nil, waitlistCount: nil)
    }

    func deleteGame(gameID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let _: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "id", value: "eq.\(gameID.uuidString)"),
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id,publish_at")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )
    }

    func cancelGame(gameID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = try JSONEncoder().encode(GameStatusUpdateRow(status: "cancelled"))

        let _: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "id", value: "eq.\(gameID.uuidString)"),
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id,publish_at")
            ],
            method: "PATCH",
            body: payload,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func updateClubOwnerFields(clubID: UUID, draft: ClubOwnerEditDraft) async throws -> Club {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ClubOwnerUpdateRow(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nilIfEmpty(draft.description),
            imageURL: draft.imageURLStringForSave ?? "",
            contactEmail: nilIfEmpty(draft.contactEmail),
            contactPhone: nilIfEmpty(draft.contactPhone),
            website: nilIfEmpty(draft.website),
            managerName: nilIfEmpty(draft.managerName),
            membersOnly: draft.membersOnly,
            winCondition: draft.winCondition.rawValue,
            defaultCourtCount: max(1, draft.defaultCourtCount),
            venueName: nilIfEmpty(draft.venueName),
            streetAddress: nilIfEmpty(draft.streetAddress),
            suburb: nilIfEmpty(draft.suburb),
            state: nilIfEmpty(draft.state),
            postcode: nilIfEmpty(draft.postcode),
            country: nilIfEmpty(draft.country),
            clearCoordinates: draft.locationChanged,
            heroImageKey: draft.heroImageKey,
            customBannerURL: draft.customBannerURLStringForSave,
            codeOfConduct: nilIfEmpty(draft.codeOfConduct),
            cancellationPolicy: nilIfEmpty(draft.cancellationPolicy),
            avatarBackgroundColor: draft.avatarBackgroundColor
        )

        let updatedRows: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id,name,description,image_url,contact_email,contact_phone,website,manager_name,members_only,created_by,win_condition,default_court_count,venue_name,street_address,suburb,state,postcode,country,latitude,longitude,hero_image_key,custom_banner_url,code_of_conduct,cancellation_policy,stripe_connect_id,avatar_background_color,timezone")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(payload),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
        // Guard against silent RLS failures: PostgREST returns an empty array (no error) when
        // a write is blocked by a policy. Without this check the caller would see "Saved" while
        // no row was actually updated.
        guard !updatedRows.isEmpty else { throw SupabaseServiceError.notFound }

        // Reuse existing detail loader to rebuild derived fields/member count consistently.
        return try await fetchClubDetail(id: clubID)
    }

    func deleteClub(clubID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        // Direct DELETE fails when child tables (games, bookings, club_members, etc.)
        // have FK constraints without ON DELETE CASCADE. Use the delete_club RPC which
        // removes child records in dependency order before deleting the club row.
        struct DeleteClubBody: Encodable { let p_club_id: String }
        try await sendVoid(
            path: "rpc/delete_club",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(DeleteClubBody(p_club_id: clubID.uuidString.lowercased())),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )
    }

    func createBooking(gameID: UUID, userID: UUID, status: String = "confirmed", waitlistPosition: Int? = nil, feePaid: Bool = false, stripePaymentIntentID: String? = nil, paymentMethod: String? = nil, platformFeeCents: Int? = nil, clubPayoutCents: Int? = nil, creditsAppliedCents: Int? = nil) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = BookingInsertBody(
            gameID: gameID,
            userID: userID,
            status: status,
            waitlistPosition: waitlistPosition,
            feePaid: feePaid ? true : nil,
            stripePaymentIntentID: stripePaymentIntentID,
            paymentMethod: paymentMethod,
            platformFeeCents: platformFeeCents,
            clubPayoutCents: clubPayoutCents,
            creditsAppliedCents: creditsAppliedCents
        )

        do {
            // INSERT with minimal return — avoids SELECT errors when Phase 1 columns
            // (platform_fee_cents, club_payout_cents, credits_applied_cents) haven't
            // been migrated yet.  We read back only the stable base columns.
            let rows: [BookingRow] = try await send(
                path: "bookings",
                queryItems: [
                    .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method")
                ],
                method: "POST",
                body: try JSONEncoder().encode([payload]),
                authBearerToken: authToken,
                extraHeaders: [
                    "Prefer": "return=representation",
                    "Content-Type": "application/json"
                ]
            )
            guard let row = rows.first else { throw SupabaseServiceError.notFound }
            // Re-inject the payment breakdown we sent so the in-memory record is complete
            // without requiring a round-trip fetch.
            let base = row.toBookingRecord()
            // Re-inject payment breakdown from the insert payload so the in-memory
            // record is accurate without needing a second round-trip fetch.
            return BookingRecord(
                id: base.id,
                gameID: base.gameID,
                userID: base.userID,
                state: base.state,
                waitlistPosition: base.waitlistPosition,
                createdAt: base.createdAt,
                feePaid: base.feePaid,
                paidAt: base.paidAt,
                stripePaymentIntentID: base.stripePaymentIntentID,
                paymentMethod: base.paymentMethod,
                platformFeeCents: platformFeeCents,
                clubPayoutCents: clubPayoutCents,
                creditsAppliedCents: creditsAppliedCents,
                holdExpiresAt: nil
            )
        } catch let error as SupabaseServiceError {
            if case let .httpStatus(code, _) = error, code == 409 {
                throw SupabaseServiceError.duplicateMembership
            }
            throw error
        }
    }

    func bookGame(gameID: UUID, userID: UUID, feePaid: Bool, holdForPayment: Bool = false, stripePaymentIntentID: String?, paymentMethod: String?, platformFeeCents: Int?, clubPayoutCents: Int?, creditsAppliedCents: Int?) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct BookGameParams: Encodable {
            let pGameId: UUID
            let pUserId: UUID
            let pFeePaid: Bool
            let pHoldForPayment: Bool
            let pStripePiId: String?
            let pPaymentMethod: String?
            let pPlatformFeeCents: Int?
            let pClubPayoutCents: Int?
            let pCreditsAppliedCents: Int?
            enum CodingKeys: String, CodingKey {
                case pGameId = "p_game_id"
                case pUserId = "p_user_id"
                case pFeePaid = "p_fee_paid"
                case pHoldForPayment = "p_hold_for_payment"
                case pStripePiId = "p_stripe_pi_id"
                case pPaymentMethod = "p_payment_method"
                case pPlatformFeeCents = "p_platform_fee_cents"
                case pClubPayoutCents = "p_club_payout_cents"
                case pCreditsAppliedCents = "p_credits_applied_cents"
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(pGameId,          forKey: .pGameId)
                try c.encode(pUserId,          forKey: .pUserId)
                try c.encode(pFeePaid,         forKey: .pFeePaid)
                try c.encode(pHoldForPayment,  forKey: .pHoldForPayment)
                try c.encodeIfPresent(pStripePiId,           forKey: .pStripePiId)
                try c.encodeIfPresent(pPaymentMethod,        forKey: .pPaymentMethod)
                try c.encodeIfPresent(pPlatformFeeCents,     forKey: .pPlatformFeeCents)
                try c.encodeIfPresent(pClubPayoutCents,      forKey: .pClubPayoutCents)
                try c.encodeIfPresent(pCreditsAppliedCents,  forKey: .pCreditsAppliedCents)
            }
        }

        let params = BookGameParams(
            pGameId: gameID,
            pUserId: userID,
            pFeePaid: feePaid,
            pHoldForPayment: holdForPayment,
            pStripePiId: stripePaymentIntentID,
            pPaymentMethod: paymentMethod,
            pPlatformFeeCents: platformFeeCents,
            pClubPayoutCents: clubPayoutCents,
            pCreditsAppliedCents: creditsAppliedCents
        )

        do {
            let encodedBody = try JSONEncoder().encode(params)
            let rows: [BookingRow] = try await send(
                path: "rpc/book_game",
                queryItems: [],
                method: "POST",
                body: encodedBody,
                authBearerToken: authToken,
                extraHeaders: ["Content-Type": "application/json"]
            )
            guard let row = rows.first else { throw SupabaseServiceError.notFound }
            return row.toBookingRecord()
        } catch let error as SupabaseServiceError {
            if case let .httpStatus(code, body) = error {
                if code == 409 { throw SupabaseServiceError.duplicateMembership }
                if body.contains("game_not_found") { throw SupabaseServiceError.notFound }
                if body.contains("membership_required") { throw SupabaseServiceError.membershipRequired }
                if body.contains("dupr_required") { throw SupabaseServiceError.duprRequired }
            }
            throw error
        }
    }

    func ownerCreateBooking(gameID: UUID, userID: UUID, status: String, waitlistPosition: Int?) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        // Server-authoritative path. owner_create_booking() RPC takes a FOR UPDATE
        // lock on the games row and decides confirmed vs waitlisted under the same
        // capacity invariant as book_game(). The status / waitlistPosition args
        // are ignored — kept on the signature for callers but the server is the
        // source of truth.
        struct OwnerCreateBookingParams: Encodable {
            let pGameId: UUID
            let pUserId: UUID
            enum CodingKeys: String, CodingKey {
                case pGameId = "p_game_id"
                case pUserId = "p_user_id"
            }
        }

        let params = OwnerCreateBookingParams(pGameId: gameID, pUserId: userID)

        do {
            let rows: [BookingRow] = try await send(
                path: "rpc/owner_create_booking",
                queryItems: [],
                method: "POST",
                body: try JSONEncoder().encode(params),
                authBearerToken: authToken,
                extraHeaders: ["Content-Type": "application/json"]
            )
            guard let row = rows.first else { throw SupabaseServiceError.notFound }
            return row.toBookingRecord()
        } catch let error as SupabaseServiceError {
            if case let .httpStatus(code, body) = error {
                if code == 409 || body.contains("duplicate_booking") {
                    throw SupabaseServiceError.duplicateMembership
                }
                if body.contains("game_not_found") { throw SupabaseServiceError.notFound }
                if body.contains("forbidden_not_admin") { throw SupabaseServiceError.authenticationRequired }
            }
            throw error
        }
    }

    func removeMembership(clubID: UUID, userID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        // Remove membership
        let _: [ClubMembershipUserRow] = try await send(
            path: "club_members",
            queryItems: [
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "select", value: "club_id,user_id,status")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )

        // Always strip any admin role — non-members must not retain club_admins rows.
        // Uses try? so a missing row (non-admin) doesn't fail the overall removal.
        let _: [ClubAdminRow]? = try? await send(
            path: "club_admins",
            queryItems: [
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "select", value: "club_id,user_id,role")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )
    }

    func cancelBookingWithCredit(bookingID: UUID) async throws -> CancellationResult {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct RequestBody: Encodable {
            let pBookingId: String
            enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
        }
        struct ResultRow: Decodable {
            let creditIssuedCents: Int
            let wasEligible: Bool
            let newBalanceCents: Int
            enum CodingKeys: String, CodingKey {
                case creditIssuedCents = "credit_issued_cents"
                case wasEligible       = "was_eligible"
                case newBalanceCents   = "new_balance_cents"
            }
        }

        let rows: [ResultRow] = try await send(
            path: "rpc/cancel_booking_with_credit",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(RequestBody(pBookingId: bookingID.uuidString.lowercased())),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return CancellationResult(
            creditIssuedCents: row.creditIssuedCents,
            wasEligible: row.wasEligible,
            newBalanceCents: row.newBalanceCents
        )
    }

    func confirmPendingBooking(bookingID: UUID, stripePaymentIntentID: String?, platformFeeCents: Int?, clubPayoutCents: Int?, creditsAppliedCents: Int?) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let resolvedPaymentMethod: String = stripePaymentIntentID != nil ? "stripe"
            : (creditsAppliedCents != nil ? "credits" : "stripe")
        let payload = BookingConfirmPaymentBody(
            status: "confirmed",
            feePaid: stripePaymentIntentID != nil,
            stripePaymentIntentID: stripePaymentIntentID,
            paymentMethod: resolvedPaymentMethod,
            platformFeeCents: platformFeeCents,
            clubPayoutCents: clubPayoutCents,
            creditsAppliedCents: creditsAppliedCents
        )

        // Three-layer server guard — all must match for the PATCH to apply:
        //   1. id          — correct booking
        //   2. status      — still pending_payment (not already confirmed or reverted)
        //   3. hold_expires_at > now() — hold is still active at the moment of execution
        // If any filter fails (0 rows returned) the hold has expired or been reverted
        // and we throw holdExpired so the caller can show an appropriate message.
        let nowISO = SupabaseDateWriter.string(from: Date())
        let rows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "id", value: "eq.\(bookingID.uuidString)"),
                .init(name: "status", value: "eq.pending_payment"),
                .init(name: "hold_expires_at", value: "gt.\(nowISO)"),
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method,platform_fee_cents,club_payout_cents,credits_applied_cents,hold_expires_at")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(payload),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { throw SupabaseServiceError.holdExpired }
        return row.toBookingRecord()
    }

    func ownerUpdateBooking(bookingID: UUID, status: String, waitlistPosition: Int?) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        var payload: [String: Any] = ["status": status]
        payload["waitlist_position"] = waitlistPosition as Any? ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        let rows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "id", value: "eq.\(bookingID.uuidString)"),
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method,platform_fee_cents,club_payout_cents,credits_applied_cents,hold_expires_at")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return row.toBookingRecord()
    }

    func updateBookingPaymentMethod(bookingID: UUID, paymentMethod: String) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let feePaid = paymentMethod == "cash" || paymentMethod == "stripe"
        let payload: [String: Any] = ["payment_method": paymentMethod, "fee_paid": feePaid]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        let rows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "id", value: "eq.\(bookingID.uuidString)"),
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method,platform_fee_cents,club_payout_cents,credits_applied_cents,hold_expires_at")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return row.toBookingRecord()
    }

    func upsertAttendance(gameID: UUID, bookingID: UUID, userID: UUID, checkedInBy: UUID, status: String) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = GameAttendanceUpsertBody(
            gameID: gameID,
            bookingID: bookingID,
            userID: userID,
            checkedInAt: SupabaseDateWriter.string(from: Date()),
            checkedInBy: checkedInBy,
            attendanceStatus: status
        )

        let _: [GameAttendanceRow] = try await send(
            path: "game_attendance",
            queryItems: [
                .init(name: "select", value: "booking_id"),
                .init(name: "on_conflict", value: "booking_id")
            ],
            method: "POST",
            body: try JSONEncoder().encode([payload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "resolution=merge-duplicates,return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func deleteAttendanceCheckIn(bookingID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let _: [GameAttendanceRow] = try await send(
            path: "game_attendance",
            queryItems: [
                .init(name: "booking_id", value: "eq.\(bookingID.uuidString)"),
                .init(name: "select", value: "booking_id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )
    }

    func upsertProfile(_ profile: UserProfile) async throws -> UserProfile {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ProfileUpsertRow(
            id: profile.id,
            email: profile.email,
            firstName: profile.firstName,
            lastName: profile.lastName,
            fullName: profile.fullName,
            phone: profile.phone,
            dateOfBirth: profile.dateOfBirth.map { Self.isoDateFormatter.string(from: $0) },
            emergencyContactName: profile.emergencyContactName,
            emergencyContactPhone: profile.emergencyContactPhone,
            duprRating: profile.duprRating,
            duprID: profile.duprID,
            avatarColorKey: profile.avatarColorKey
        )

        let rows: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,email,first_name,last_name,full_name,phone,date_of_birth,emergency_contact_name,emergency_contact_phone,dupr_rating,dupr_id,avatar_color_key"),
                .init(name: "on_conflict", value: "id")
            ],
            method: "POST",
            body: try JSONEncoder().encode([payload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "resolution=merge-duplicates,return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { return profile }
        return UserProfile(
            id: row.id,
            firstName: row.firstName,
            lastName: row.lastName,
            fullName: row.fullName ?? profile.fullName,
            email: row.email,
            phone: row.phone,
            dateOfBirth: row.dateOfBirth.flatMap { Self.isoDateFormatter.date(from: $0) },
            emergencyContactName: row.emergencyContactName,
            emergencyContactPhone: row.emergencyContactPhone,
            duprRating: row.duprRating,
            duprID: row.duprID,
            favoriteClubName: profile.favoriteClubName,
            skillLevel: profile.skillLevel,
            avatarColorKey: row.avatarColorKey
        )
    }

    /// PATCH (UPDATE) an existing profile row. Requires only the UPDATE RLS policy.
    /// Use this for editing existing profiles — avoids triggering INSERT RLS evaluation.
    func patchProfile(_ profile: UserProfile) async throws -> UserProfile {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ProfileUpsertRow(
            id: profile.id,
            email: profile.email,
            firstName: profile.firstName,
            lastName: profile.lastName,
            fullName: profile.fullName,
            phone: profile.phone,
            dateOfBirth: profile.dateOfBirth.map { Self.isoDateFormatter.string(from: $0) },
            emergencyContactName: profile.emergencyContactName,
            emergencyContactPhone: profile.emergencyContactPhone,
            duprRating: profile.duprRating,
            duprID: profile.duprID,
            avatarColorKey: profile.avatarColorKey
        )

        let rows: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "id", value: "eq.\(profile.id.uuidString)"),
                .init(name: "select", value: "id,email,first_name,last_name,full_name,phone,date_of_birth,emergency_contact_name,emergency_contact_phone,dupr_rating,dupr_id,avatar_color_key")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(payload),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        guard let row = rows.first else { return profile }
        return UserProfile(
            id: row.id,
            firstName: row.firstName,
            lastName: row.lastName,
            fullName: row.fullName ?? profile.fullName,
            email: row.email,
            phone: row.phone,
            dateOfBirth: row.dateOfBirth.flatMap { Self.isoDateFormatter.date(from: $0) },
            emergencyContactName: row.emergencyContactName,
            emergencyContactPhone: row.emergencyContactPhone,
            duprRating: row.duprRating,
            duprID: row.duprID,
            favoriteClubName: profile.favoriteClubName,
            skillLevel: profile.skillLevel,
            avatarColorKey: row.avatarColorKey
        )
    }

    func updatePassword(_ newPassword: String) async throws {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }
        let url = baseURL.appendingPathComponent("auth").appendingPathComponent("v1").appendingPathComponent("user")
        let body = try JSONSerialization.data(withJSONObject: ["password": newPassword])
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SupabaseServiceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0, msg)
        }
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    func updateProfilePushToken(userID: UUID, pushToken: String?) async throws {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        var payload: [String: Any] = [:]
        if let pushToken, !pushToken.isEmpty {
            payload["push_token"] = pushToken
        } else {
            payload["push_token"] = NSNull()
        }
        let body = try JSONSerialization.data(withJSONObject: payload)

        let _: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "id", value: "eq.\(userID.uuidString)"),
                .init(name: "select", value: "id,email,full_name")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
        if let pushToken, !pushToken.isEmpty {
            let pushTokenBody = try JSONSerialization.data(withJSONObject: [
                "user_id": userID.uuidString,
                "token": pushToken
            ])

            struct PushTokenRow: Decodable {
                let id: UUID
            }

            let _: [PushTokenRow] = try await send(
                path: "push_tokens",
                queryItems: [
                    .init(name: "select", value: "id")
                ],
                method: "POST",
                body: pushTokenBody,
                authBearerToken: authToken,
                extraHeaders: [
                    "Prefer": "resolution=merge-duplicates,return=representation",
                    "Content-Type": "application/json"
                ]
            )
        }
    }

    // MARK: - Notifications

    func fetchNotifications(userID: UUID) async throws -> [AppNotification] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let rows: [AppNotificationRow] = try await send(
            path: "notifications",
            queryItems: [
                .init(name: "select", value: "id,user_id,title,body,type,reference_id,read,created_at"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "order", value: "created_at.desc"),
                .init(name: "limit", value: "100")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.map { row in
            AppNotification(
                id: row.id,
                userID: row.userID,
                title: row.title,
                body: row.body,
                type: AppNotification.NotificationType(raw: row.type),
                referenceID: row.referenceID,
                read: row.read,
                createdAt: row.createdAtRaw.flatMap(SupabaseDateParser.parse)
            )
        }
    }

    func markNotificationRead(id: UUID) async throws {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let body = try JSONSerialization.data(withJSONObject: ["read": true])
        let _: [AppNotificationRow] = try await send(
            path: "notifications",
            queryItems: [
                .init(name: "id", value: "eq.\(id.uuidString)"),
                .init(name: "select", value: "id,user_id,title,body,type,reference_id,read,created_at")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation", "Content-Type": "application/json"]
        )
    }

    func markAllNotificationsRead(userID: UUID) async throws {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let body = try JSONSerialization.data(withJSONObject: ["read": true])
        let _: [AppNotificationRow] = try await send(
            path: "notifications",
            queryItems: [
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "read", value: "eq.false"),
                .init(name: "select", value: "id")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation", "Content-Type": "application/json"]
        )
    }

    func deleteAllNotifications(userID: UUID) async throws {
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let _: [AppNotificationRow] = try await send(
            path: "notifications",
            queryItems: [
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation"]
        )
    }

    func submitReview(gameID: UUID, userID: UUID, rating: Int, comment: String?) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        struct ReviewInsertBody: Encodable {
            let gameID: UUID
            let userID: UUID
            let rating: Int
            let comment: String?
            enum CodingKeys: String, CodingKey {
                case gameID = "game_id"
                case userID = "user_id"
                case rating
                case comment
            }
        }
        let payload = ReviewInsertBody(gameID: gameID, userID: userID, rating: rating, comment: comment)
        let _: [[String: String]] = try await send(
            path: "reviews",
            queryItems: [.init(name: "select", value: "id")],
            method: "POST",
            body: try JSONEncoder().encode([payload]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func fetchClubReviews(clubID: UUID) async throws -> [GameReview] {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        // Calls the `get_club_reviews` SECURITY DEFINER function so the profiles
        // join works regardless of profiles RLS restrictions.
        // Dates come back from PostgREST as ISO8601 strings — decode raw then parse,
        // matching the SupabaseDateParser pattern used everywhere else in this service.
        struct ReviewRow: Decodable {
            let id: UUID
            let gameID: UUID
            let userID: UUID
            let rating: Int
            let comment: String?
            let createdAtRaw: String?
            let reviewerName: String?
            let gameTitle: String?
            let reviewerAvatarColorKey: String?
            enum CodingKeys: String, CodingKey {
                case id, rating, comment
                case gameID = "game_id"
                case userID = "user_id"
                case createdAtRaw = "created_at"
                case reviewerName = "reviewer_name"
                case gameTitle = "game_title"
                case reviewerAvatarColorKey = "reviewer_avatar_color_key"
            }
        }

        struct Params: Encodable {
            let pClubId: UUID
            enum CodingKeys: String, CodingKey { case pClubId = "p_club_id" }
        }

        let rows: [ReviewRow] = try await send(
            path: "rpc/get_club_reviews",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        return rows.map {
            GameReview(
                id: $0.id,
                gameID: $0.gameID,
                userID: $0.userID,
                rating: $0.rating,
                comment: $0.comment,
                createdAt: $0.createdAtRaw.flatMap(SupabaseDateParser.parse),
                reviewerName: $0.reviewerName,
                gameTitle: $0.gameTitle,
                avatarColorKey: $0.reviewerAvatarColorKey
            )
        }
    }

    func fetchPendingReviewPrompt(userID: UUID) async throws -> PendingReviewPrompt? {
        guard SupabaseConfig.isConfigured else { return nil }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Row: Decodable {
            let gameID: UUID
            let gameTitle: String
            let gameDateTimeRaw: String?
            let clubID: UUID
            let clubName: String
            enum CodingKeys: String, CodingKey {
                case gameID = "game_id"
                case gameTitle = "game_title"
                case gameDateTimeRaw = "game_date_time"
                case clubID = "club_id"
                case clubName = "club_name"
            }
        }

        struct Params: Encodable {
            let pUserId: UUID
            enum CodingKeys: String, CodingKey { case pUserId = "p_user_id" }
        }

        let rows: [Row] = try await send(
            path: "rpc/get_pending_review_prompt",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pUserId: userID)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { return nil }
        return PendingReviewPrompt(
            id: row.gameID,
            gameTitle: row.gameTitle,
            gameDateTime: row.gameDateTimeRaw.flatMap(SupabaseDateParser.parse) ?? Date(),
            clubID: row.clubID,
            clubName: row.clubName
        )
    }

    func dismissReviewPrompt(gameID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pGameId: UUID
            enum CodingKeys: String, CodingKey { case pGameId = "p_game_id" }
        }

        try await sendVoid(
            path: "rpc/dismiss_review_prompt",
            body: try JSONEncoder().encode(Params(pGameId: gameID)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )
    }

    func fetchClubRevenueSummary(clubID: UUID, days: Int?) async throws -> ClubRevenueSummary? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId: UUID
            let pDays: Int?
            enum CodingKeys: String, CodingKey {
                case pClubId = "p_club_id"
                case pDays   = "p_days"
            }
        }

        struct SummaryRow: Decodable {
            let totalClubPayoutCents: Int
            let totalPlatformFeeCents: Int
            let paidBookingCount: Int
            let freeBookingCount: Int
            let currency: String
            let asOfRaw: String?
            enum CodingKeys: String, CodingKey {
                case totalClubPayoutCents  = "total_club_payout_cents"
                case totalPlatformFeeCents = "total_platform_fee_cents"
                case paidBookingCount      = "paid_booking_count"
                case freeBookingCount      = "free_booking_count"
                case currency
                case asOfRaw               = "as_of"
            }
        }

        let rows: [SummaryRow] = try await send(
            path: "rpc/get_club_revenue_summary",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID, pDays: days)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { return nil }
        return ClubRevenueSummary(
            totalClubPayoutCents: row.totalClubPayoutCents,
            totalPlatformFeeCents: row.totalPlatformFeeCents,
            paidBookingCount: row.paidBookingCount,
            freeBookingCount: row.freeBookingCount,
            currency: row.currency,
            asOf: row.asOfRaw.flatMap(SupabaseDateParser.parse) ?? Date()
        )
    }

    func fetchClubFillRateSummary(clubID: UUID, days: Int?) async throws -> ClubFillRateSummary? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId: UUID
            let pDays: Int?
            enum CodingKeys: String, CodingKey {
                case pClubId = "p_club_id"
                case pDays   = "p_days"
            }
        }

        struct FillRateRow: Decodable {
            let totalGamesCount: Int
            let totalSpotsOffered: Int
            let totalConfirmedBookings: Int
            let averageFillRate: Double
            let fullGamesCount: Int
            let averagePlayersPerGame: Double
            let cancellationRate: Double
            let asOfRaw: String?
            enum CodingKeys: String, CodingKey {
                case totalGamesCount        = "total_games_count"
                case totalSpotsOffered      = "total_spots_offered"
                case totalConfirmedBookings = "total_confirmed_bookings"
                case averageFillRate        = "average_fill_rate"
                case fullGamesCount         = "full_games_count"
                case averagePlayersPerGame  = "average_players_per_game"
                case cancellationRate       = "cancellation_rate"
                case asOfRaw                = "as_of"
            }
        }

        let rows: [FillRateRow] = try await send(
            path: "rpc/get_club_fill_rate_summary",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID, pDays: days)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { return nil }
        return ClubFillRateSummary(
            totalGamesCount: row.totalGamesCount,
            totalSpotsOffered: row.totalSpotsOffered,
            totalConfirmedBookings: row.totalConfirmedBookings,
            averageFillRate: row.averageFillRate,
            fullGamesCount: row.fullGamesCount,
            averagePlayersPerGame: row.averagePlayersPerGame,
            cancellationRate: row.cancellationRate,
            asOf: row.asOfRaw.flatMap(SupabaseDateParser.parse) ?? Date()
        )
    }

    // MARK: - Phase 5B Analytics

    func fetchClubAnalyticsKPIs(clubID: UUID, days: Int, startDate: Date? = nil, endDate: Date? = nil) async throws -> ClubAnalyticsKPIs? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId:    UUID
            let pDays:      Int
            let pStartDate: String?
            let pEndDate:   String?
            enum CodingKeys: String, CodingKey {
                case pClubId    = "p_club_id"
                case pDays      = "p_days"
                case pStartDate = "p_start_date"
                case pEndDate   = "p_end_date"
            }
        }

        struct Row: Decodable {
            let currRevenueCents:        Int
            let currBookingCount:        Int
            let currFillRate:            Double
            let currActivePlayers:       Int
            let prevRevenueCents:        Int
            let prevBookingCount:        Int
            let prevFillRate:            Double
            let prevActivePlayers:       Int
            let cancellationRate:        Double
            let repeatPlayerRate:        Double
            let currency:                String
            let asOfRaw:                 String?
            // Revenue breakdown fields — default to 0 for clubs running the old RPC version
            let currGrossRevenueCents:   Int?
            let currPlatformFeeCents:    Int?
            let currCreditsUsedCents:    Int?
            let prevGrossRevenueCents:   Int?
            let prevPlatformFeeCents:    Int?
            let prevCreditsUsedCents:    Int?
            let currCreditsReturnedCents: Int?
            let currCreditReturnCount:   Int?
            let currManualRevenueCents:  Int?
            let prevManualRevenueCents:  Int?
            enum CodingKeys: String, CodingKey {
                case currRevenueCents        = "curr_revenue_cents"
                case currBookingCount        = "curr_booking_count"
                case currFillRate            = "curr_fill_rate"
                case currActivePlayers       = "curr_active_players"
                case prevRevenueCents        = "prev_revenue_cents"
                case prevBookingCount        = "prev_booking_count"
                case prevFillRate            = "prev_fill_rate"
                case prevActivePlayers       = "prev_active_players"
                case cancellationRate        = "cancellation_rate"
                case repeatPlayerRate        = "repeat_player_rate"
                case currency
                case asOfRaw                 = "as_of"
                case currGrossRevenueCents   = "curr_gross_revenue_cents"
                case currPlatformFeeCents    = "curr_platform_fee_cents"
                case currCreditsUsedCents    = "curr_credits_used_cents"
                case prevGrossRevenueCents   = "prev_gross_revenue_cents"
                case prevPlatformFeeCents    = "prev_platform_fee_cents"
                case prevCreditsUsedCents    = "prev_credits_used_cents"
                case currCreditsReturnedCents = "curr_credits_returned_cents"
                case currCreditReturnCount   = "curr_credit_return_count"
                case currManualRevenueCents  = "curr_manual_revenue_cents"
                case prevManualRevenueCents  = "prev_manual_revenue_cents"
            }
        }

        let rows: [Row] = try await send(
            path: "rpc/get_club_analytics_kpis",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(
                pClubId:    clubID,
                pDays:      days,
                pStartDate: startDate.map(SupabaseDateWriter.string(from:)),
                pEndDate:   endDate.map(SupabaseDateWriter.string(from:))
            )),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { return nil }
        return ClubAnalyticsKPIs(
            currRevenueCents:        row.currRevenueCents,
            currBookingCount:        row.currBookingCount,
            currFillRate:            row.currFillRate,
            currActivePlayers:       row.currActivePlayers,
            prevRevenueCents:        row.prevRevenueCents,
            prevBookingCount:        row.prevBookingCount,
            prevFillRate:            row.prevFillRate,
            prevActivePlayers:       row.prevActivePlayers,
            cancellationRate:        row.cancellationRate,
            repeatPlayerRate:        row.repeatPlayerRate,
            currency:                row.currency.isEmpty ? "AUD" : row.currency.uppercased(),
            asOf:                    row.asOfRaw.flatMap(SupabaseDateParser.parse) ?? Date(),
            currGrossRevenueCents:   row.currGrossRevenueCents   ?? row.currRevenueCents,
            currPlatformFeeCents:    row.currPlatformFeeCents    ?? 0,
            currCreditsUsedCents:    row.currCreditsUsedCents    ?? 0,
            prevGrossRevenueCents:   row.prevGrossRevenueCents   ?? row.prevRevenueCents,
            prevPlatformFeeCents:    row.prevPlatformFeeCents    ?? 0,
            prevCreditsUsedCents:    row.prevCreditsUsedCents    ?? 0,
            currCreditsReturnedCents: row.currCreditsReturnedCents ?? 0,
            currCreditReturnCount:   row.currCreditReturnCount   ?? 0,
            currManualRevenueCents:  row.currManualRevenueCents  ?? 0,
            prevManualRevenueCents:  row.prevManualRevenueCents  ?? 0
        )
    }

    func fetchClubDashboardSummary(clubID: UUID) async throws -> ClubDashboardSummary? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId: UUID
            enum CodingKeys: String, CodingKey { case pClubId = "p_club_id" }
        }

        struct Row: Decodable {
            let totalMembers:            Int
            let memberGrowth30d:         Int
            let monthlyActivePlayers30d: Int
            let prevActivePlayers30d:    Int
            let fillRate30d:             Double?   // nil when no completed games with valid capacity
            let prevFillRate30d:         Double?   // nil when no prior-period games with valid capacity
            let upcomingBookingsCount:   Int
            enum CodingKeys: String, CodingKey {
                case totalMembers            = "total_members"
                case memberGrowth30d         = "member_growth_30d"
                case monthlyActivePlayers30d = "monthly_active_players_30d"
                case prevActivePlayers30d    = "prev_active_players_30d"
                case fillRate30d             = "fill_rate_30d"
                case prevFillRate30d         = "prev_fill_rate_30d"
                case upcomingBookingsCount   = "upcoming_bookings_count"
            }
        }

        let rows: [Row] = try await send(
            path: "rpc/get_club_dashboard_summary",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID)),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { return nil }
        return ClubDashboardSummary(
            totalMembers:            row.totalMembers,
            memberGrowth30d:         row.memberGrowth30d,
            monthlyActivePlayers30d: row.monthlyActivePlayers30d,
            prevActivePlayers30d:    row.prevActivePlayers30d,
            fillRate30d:             row.fillRate30d,
            prevFillRate30d:         row.prevFillRate30d,
            upcomingBookingsCount:   row.upcomingBookingsCount
        )
    }

    func fetchClubAnalyticsSupplemental(clubID: UUID, days: Int, startDate: Date? = nil, endDate: Date? = nil) async throws -> ClubAnalyticsSupplemental? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId:    UUID
            let pDays:      Int
            let pStartDate: String?
            let pEndDate:   String?
            enum CodingKeys: String, CodingKey {
                case pClubId    = "p_club_id"
                case pDays      = "p_days"
                case pStartDate = "p_start_date"
                case pEndDate   = "p_end_date"
            }
        }

        struct Row: Decodable {
            let currMemberJoins:             Int
            let prevMemberJoins:             Int
            let totalActiveMembers:          Int
            let currNewPlayers:              Int
            let currGameCount:               Int
            let currNoShowCount:             Int
            let currCheckedCount:            Int
            let currWaitlistCount:           Int
            let currPaidBookings:            Int
            let currFreeBookings:            Int
            let avgRevPerPlayerCents:        Int
            let currNoShowRate:              Double?  // nil when no attendance data
            let currCreditBookingCount:      Int?
            let currCompBookingCount:        Int?
            let currTrulyFreeBookingCount:   Int?
            let currCashBookingCount:        Int?
            enum CodingKeys: String, CodingKey {
                case currMemberJoins             = "curr_member_joins"
                case prevMemberJoins             = "prev_member_joins"
                case totalActiveMembers          = "total_active_members"
                case currNewPlayers              = "curr_new_players"
                case currGameCount               = "curr_game_count"
                case currNoShowCount             = "curr_no_show_count"
                case currCheckedCount            = "curr_checked_count"
                case currWaitlistCount           = "curr_waitlist_count"
                case currPaidBookings            = "curr_paid_bookings"
                case currFreeBookings            = "curr_free_bookings"
                case avgRevPerPlayerCents        = "avg_rev_per_player_cents"
                case currNoShowRate              = "curr_no_show_rate"
                case currCreditBookingCount      = "curr_credit_booking_count"
                case currCompBookingCount        = "curr_comp_booking_count"
                case currTrulyFreeBookingCount   = "curr_truly_free_booking_count"
                case currCashBookingCount        = "curr_cash_booking_count"
            }
        }

        let rows: [Row] = try await send(
            path: "rpc/get_club_analytics_supplemental",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID, pDays: days, pStartDate: startDate.map(SupabaseDateWriter.string(from:)), pEndDate: endDate.map(SupabaseDateWriter.string(from:)))),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first else { return nil }
        return ClubAnalyticsSupplemental(
            currMemberJoins:             row.currMemberJoins,
            prevMemberJoins:             row.prevMemberJoins,
            totalActiveMembers:          row.totalActiveMembers,
            currNewPlayers:              row.currNewPlayers,
            currGameCount:               row.currGameCount,
            currNoShowCount:             row.currNoShowCount,
            currCheckedCount:            row.currCheckedCount,
            currWaitlistCount:           row.currWaitlistCount,
            currPaidBookings:            row.currPaidBookings,
            currFreeBookings:            row.currFreeBookings,
            avgRevPerPlayerCents:        row.avgRevPerPlayerCents,
            noShowRate:                  row.currNoShowRate,
            currCreditBookingCount:      row.currCreditBookingCount    ?? 0,
            currCompBookingCount:        row.currCompBookingCount      ?? 0,
            currTrulyFreeBookingCount:   row.currTrulyFreeBookingCount ?? 0,
            currCashBookingCount:        row.currCashBookingCount      ?? 0
        )
    }

    func fetchClubRevenueTrend(clubID: UUID, days: Int, startDate: Date? = nil, endDate: Date? = nil) async throws -> [ClubRevenueTrendPoint] {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId:    UUID
            let pDays:      Int
            let pStartDate: String?
            let pEndDate:   String?
            enum CodingKeys: String, CodingKey {
                case pClubId    = "p_club_id"
                case pDays      = "p_days"
                case pStartDate = "p_start_date"
                case pEndDate   = "p_end_date"
            }
        }

        struct TrendRow: Decodable {
            let bucketDateRaw: String
            let revenueCents:  Int
            let bookingCount:  Int
            let fillRate:      Double
            enum CodingKeys: String, CodingKey {
                case bucketDateRaw = "bucket_date"
                case revenueCents  = "revenue_cents"
                case bookingCount  = "booking_count"
                case fillRate      = "fill_rate"
            }
        }

        let rows: [TrendRow] = try await send(
            path: "rpc/get_club_revenue_trend",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID, pDays: days, pStartDate: startDate.map(SupabaseDateWriter.string(from:)), pEndDate: endDate.map(SupabaseDateWriter.string(from:)))),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withFullDate]

        return rows.compactMap { row in
            guard let date = dateParser.date(from: row.bucketDateRaw)
                          ?? SupabaseDateParser.parse(row.bucketDateRaw) else { return nil }
            return ClubRevenueTrendPoint(
                bucketDate:   date,
                revenueCents: row.revenueCents,
                bookingCount: row.bookingCount,
                fillRate:     row.fillRate
            )
        }
    }

    func fetchClubTopGames(clubID: UUID, days: Int, startDate: Date? = nil, endDate: Date? = nil) async throws -> [ClubTopGame] {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId:    UUID
            let pDays:      Int
            let pLimit:     Int
            let pStartDate: String?
            let pEndDate:   String?
            enum CodingKeys: String, CodingKey {
                case pClubId    = "p_club_id"
                case pDays      = "p_days"
                case pLimit     = "p_limit"
                case pStartDate = "p_start_date"
                case pEndDate   = "p_end_date"
            }
        }

        // Pattern-level row (no game_id or game_date — see 20260426_analytics_top_games_time_to_fill.sql)
        struct TopGameRow: Decodable {
            let gameTitle:               String
            let dayOfWeek:               Int
            let hourOfDay:               Int
            let occurrenceCount:         Int
            let filledOccurrenceCount:   Int?
            let avgConfirmed:            Double
            let maxSpots:                Int?
            let avgFillRate:             Double
            let totalRevenueCents:       Int
            let avgWaitlist:             Double
            let avgTimeToFillMinutes:    Double?
            let skillLevel:              String?
            let gameFormat:              String?
            enum CodingKeys: String, CodingKey {
                case gameTitle               = "game_title"
                case dayOfWeek               = "day_of_week"
                case hourOfDay               = "hour_of_day"
                case occurrenceCount         = "occurrence_count"
                case filledOccurrenceCount   = "filled_occurrence_count"
                case avgConfirmed            = "avg_confirmed"
                case maxSpots                = "max_spots"
                case avgFillRate             = "avg_fill_rate"
                case totalRevenueCents       = "total_revenue_cents"
                case avgWaitlist             = "avg_waitlist"
                case avgTimeToFillMinutes    = "avg_time_to_fill_minutes"
                case skillLevel              = "skill_level"
                case gameFormat              = "game_format"
            }
        }

        let rows: [TopGameRow] = try await send(
            path: "rpc/get_club_top_games",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID, pDays: days, pLimit: 5, pStartDate: startDate.map(SupabaseDateWriter.string(from:)), pEndDate: endDate.map(SupabaseDateWriter.string(from:)))),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        return rows.map { row in
            ClubTopGame(
                title:                   row.gameTitle,
                dayOfWeek:               row.dayOfWeek,
                hourOfDay:               row.hourOfDay,
                occurrenceCount:         row.occurrenceCount,
                filledOccurrenceCount:   row.filledOccurrenceCount ?? 0,
                avgConfirmed:            row.avgConfirmed,
                maxSpots:                row.maxSpots ?? 0,
                avgFillRate:             row.avgFillRate,
                totalRevenueCents:       row.totalRevenueCents,
                avgWaitlist:             row.avgWaitlist,
                avgTimeToFillMinutes:    row.avgTimeToFillMinutes,
                skillLevel:              row.skillLevel,
                gameFormat:              row.gameFormat
            )
        }
    }

    func fetchClubPeakTimes(clubID: UUID, days: Int, startDate: Date? = nil, endDate: Date? = nil) async throws -> [ClubPeakTime] {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct Params: Encodable {
            let pClubId:    UUID
            let pDays:      Int
            let pStartDate: String?
            let pEndDate:   String?
            enum CodingKeys: String, CodingKey {
                case pClubId    = "p_club_id"
                case pDays      = "p_days"
                case pStartDate = "p_start_date"
                case pEndDate   = "p_end_date"
            }
        }

        struct PeakRow: Decodable {
            let dayOfWeek:    Int
            let hourOfDay:    Int
            let avgConfirmed: Double
            let gameCount:    Int
            let avgFillRate:  Double
            let avgWaitlist:  Double
            enum CodingKeys: String, CodingKey {
                case dayOfWeek    = "day_of_week"
                case hourOfDay    = "hour_of_day"
                case avgConfirmed = "avg_confirmed"
                case gameCount    = "game_count"
                case avgFillRate  = "avg_fill_rate"
                case avgWaitlist  = "avg_waitlist"
            }
        }

        let rows: [PeakRow] = try await send(
            path: "rpc/get_club_peak_times",
            queryItems: [],
            method: "POST",
            body: try JSONEncoder().encode(Params(pClubId: clubID, pDays: days, pStartDate: startDate.map(SupabaseDateWriter.string(from:)), pEndDate: endDate.map(SupabaseDateWriter.string(from:)))),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        return rows.map {
            ClubPeakTime(
                dayOfWeek:    $0.dayOfWeek,
                hourOfDay:    $0.hourOfDay,
                avgConfirmed: $0.avgConfirmed,
                gameCount:    $0.gameCount,
                avgFillRate:  $0.avgFillRate,
                avgWaitlist:  $0.avgWaitlist
            )
        }
    }

    func fetchGame(gameID: UUID) async throws -> Game? {
        guard SupabaseConfig.isConfigured else { return nil }
        let rows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,game_type,max_spots,court_count,fee_amount,fee_currency,venue_id,venue_name,location,status,notes,requires_dupr,recurrence_group_id,publish_at"),
                .init(name: "id", value: "eq.\(gameID.uuidString.lowercased())"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )
        return rows.first.map { $0.toGame(confirmedCount: nil, waitlistCount: nil) }
    }

    func fetchGameClubID(gameID: UUID) async throws -> UUID? {
        guard SupabaseConfig.isConfigured else { return nil }
        struct Row: Decodable {
            let clubID: UUID
            enum CodingKeys: String, CodingKey { case clubID = "club_id" }
        }
        let rows: [Row] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "club_id"),
                .init(name: "id", value: "eq.\(gameID.uuidString.lowercased())"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )
        return rows.first?.clubID
    }

    func triggerNotify(userID: UUID, title: String, body: String, type: String, referenceID: UUID?, sendPush: Bool) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let request = NotifyRequest(
            userID: userID,
            title: title,
            body: body,
            type: type,
            referenceID: referenceID,
            sendPush: sendPush
        )
        try await invokeEdgeFunction(name: "notify", body: try JSONEncoder().encode(request))
    }

    func triggerGameCancelledNotify(gameID: UUID, gameTitle: String, clubTimezone: String) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let request = GameCancelledNotifyRequest(gameID: gameID, gameTitle: gameTitle, clubTimezone: clubTimezone)
        try await invokeEdgeFunction(name: "game-cancelled-notify", body: try JSONEncoder().encode(request))
    }

    func triggerGamePublishedNotify(gameID: UUID, gameTitle: String, gameDateTime: Date, clubID: UUID, clubName: String, createdByUserID: UUID, skillLevel: String? = nil, clubTimezone: String) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let request = GamePublishedNotifyRequest(
            gameID: gameID,
            gameTitle: gameTitle,
            gameDateTime: gameDateTime,
            clubID: clubID,
            clubName: clubName,
            createdByUserID: createdByUserID,
            skillLevel: skillLevel,
            clubTimezone: clubTimezone
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await invokeEdgeFunction(name: "game-published-notify", body: try encoder.encode(request))
    }

    func triggerClubAnnouncementNotify(clubID: UUID, postID: UUID, posterUserID: UUID, clubName: String, posterName: String, postBody: String) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let request = ClubAnnouncementNotifyRequest(
            clubID: clubID,
            postID: postID,
            posterUserID: posterUserID,
            clubName: clubName,
            posterName: posterName,
            postBody: postBody
        )
        try await invokeEdgeFunction(name: "club-announcement-notify", body: try JSONEncoder().encode(request))
    }

    func createPaymentIntent(amountCents: Int, currency: String, clubID: UUID?, metadata: [String: String]) async throws -> PaymentIntentResult {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.missingConfiguration
        }

        let url = baseURL.appendingPathComponent("functions/v1/\(SupabaseConfig.createPaymentIntentFunctionName)")

        struct PaymentIntentRequest: Encodable {
            let amount: Int
            let currency: String
            let clubID: String?
            let metadata: [String: String]
            enum CodingKeys: String, CodingKey {
                case amount, currency, metadata
                case clubID = "club_id"
            }
        }
        struct PaymentIntentResponse: Decodable {
            let client_secret: String
            let platform_fee_cents: Int?
            let club_payout_cents: Int?
        }

        let body = try JSONEncoder().encode(PaymentIntentRequest(
            amount: amountCents,
            currency: currency,
            clubID: clubID?.uuidString.lowercased(),
            metadata: metadata
        ))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Promote 401 to a typed error so the caller can surface a sign-in message.
            if statusCode == 401 { throw SupabaseServiceError.authenticationRequired }
            // Parse {"error": "...", "error_code": "..."} from the edge function.
            // Fall back to the raw body only if JSON parsing fails.
            struct ErrorBody: Decodable {
                let error: String?
                let error_code: String?
            }
            let parsedMessage: String
            if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data),
               let msg = parsed.error, !msg.isEmpty {
                parsedMessage = msg
            } else {
                parsedMessage = String(data: data, encoding: .utf8) ?? "Payment setup failed"
            }
            throw SupabaseServiceError.httpStatus(statusCode, parsedMessage)
        }

        let decoded = try JSONDecoder().decode(PaymentIntentResponse.self, from: data)
        return PaymentIntentResult(
            clientSecret: decoded.client_secret,
            platformFeeCents: decoded.platform_fee_cents ?? 0,
            clubPayoutCents: decoded.club_payout_cents ?? amountCents
        )
    }

    func fetchClubStripeAccount(clubID: UUID) async throws -> ClubStripeAccount? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let rows: [ClubStripeAccountRow] = try await send(
            path: "club_stripe_accounts",
            queryItems: [
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id,club_id,stripe_account_id,onboarding_complete,payouts_enabled,created_at"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.first.map { row in
            ClubStripeAccount(
                id: row.id,
                clubID: row.clubID,
                stripeAccountID: row.stripeAccountID,
                onboardingComplete: row.onboardingComplete,
                payoutsEnabled: row.payoutsEnabled,
                createdAt: row.createdAtRaw.flatMap(SupabaseDateParser.parse)
            )
        }
    }

    func refreshStripeAccountStatus(clubID: UUID) async throws -> ClubStripeAccount? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.missingConfiguration
        }

        let url = baseURL.appendingPathComponent("functions/v1/\(SupabaseConfig.stripeAccountStatusFunctionName)")

        struct StatusRequest: Encodable {
            let clubID: String
            enum CodingKeys: String, CodingKey { case clubID = "club_id" }
        }
        struct StatusResponse: Decodable {
            let stripeAccountID: String?
            let onboardingComplete: Bool
            let payoutsEnabled: Bool
            enum CodingKeys: String, CodingKey {
                case stripeAccountID = "stripe_account_id"
                case onboardingComplete = "onboarding_complete"
                case payoutsEnabled = "payouts_enabled"
            }
        }

        let body = try JSONEncoder().encode(StatusRequest(clubID: clubID.uuidString.lowercased()))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // On any error fall back to the DB read performed by the caller's catch block
            throw SupabaseServiceError.httpStatus(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? "Status refresh failed"
            )
        }

        let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
        guard let accountID = decoded.stripeAccountID else { return nil }

        // Reconstruct a ClubStripeAccount from the response — we don't have id/createdAt from this endpoint
        // so we fetch the full row from the DB to fill in the missing fields.
        let rows: [ClubStripeAccountRow] = try await send(
            path: "club_stripe_accounts",
            queryItems: [
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id,club_id,stripe_account_id,onboarding_complete,payouts_enabled,created_at"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        if let row = rows.first {
            return ClubStripeAccount(
                id: row.id,
                clubID: row.clubID,
                stripeAccountID: accountID,
                onboardingComplete: decoded.onboardingComplete,
                payoutsEnabled: decoded.payoutsEnabled,
                createdAt: row.createdAtRaw.flatMap(SupabaseDateParser.parse)
            )
        }
        // Fallback: synthesise from the response without id/createdAt
        return ClubStripeAccount(
            id: UUID(),
            clubID: clubID,
            stripeAccountID: accountID,
            onboardingComplete: decoded.onboardingComplete,
            payoutsEnabled: decoded.payoutsEnabled,
            createdAt: nil
        )
    }

    func createConnectOnboarding(clubID: UUID, returnURL: String) async throws -> String {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.missingConfiguration
        }

        let url = baseURL.appendingPathComponent("functions/v1/\(SupabaseConfig.connectOnboardingFunctionName)")

        struct ConnectOnboardingRequest: Encodable {
            let clubID: String
            let returnURL: String
            enum CodingKeys: String, CodingKey {
                case clubID = "club_id"
                case returnURL = "return_url"
            }
        }
        struct ConnectOnboardingResponse: Decodable {
            let onboarding_url: String
        }

        let body = try JSONEncoder().encode(ConnectOnboardingRequest(
            clubID: clubID.uuidString,
            returnURL: returnURL
        ))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "Connect onboarding failed"
            throw SupabaseServiceError.httpStatus(statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(ConnectOnboardingResponse.self, from: data)
        return decoded.onboarding_url
    }

    // MARK: - Club Subscriptions (Phase 4)

    func fetchClubSubscription(clubID: UUID) async throws -> ClubSubscription? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct ClubSubscriptionRow: Decodable {
            let id: String
            let club_id: String
            let stripe_subscription_id: String
            let plan_type: String
            let status: String
            let current_period_end: String?
            let created_at: String?
        }

        let rows: [ClubSubscriptionRow] = try await send(
            path: "club_subscriptions",
            queryItems: [
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id,club_id,stripe_subscription_id,plan_type,status,current_period_end,created_at"),
                .init(name: "limit", value: "1")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        guard let row = rows.first,
              let id = UUID(uuidString: row.id),
              let cid = UUID(uuidString: row.club_id) else { return nil }

        return ClubSubscription(
            id: id,
            clubID: cid,
            stripeSubscriptionID: row.stripe_subscription_id,
            planType: row.plan_type,
            status: row.status,
            currentPeriodEnd: row.current_period_end.flatMap(SupabaseDateParser.parse),
            createdAt: row.created_at.flatMap(SupabaseDateParser.parse)
        )
    }

    func fetchClubEntitlements(clubID: UUID) async throws -> ClubEntitlements? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct EntitlementRow: Decodable {
            let club_id: String
            let plan_tier: String
            let max_active_games: Int
            let max_members: Int
            let can_accept_payments: Bool
            let analytics_access: Bool
            let can_use_recurring_games: Bool
            let can_use_delayed_publishing: Bool
            let locked_features: [String]
            let updated_at: String?
        }

        let rows: [EntitlementRow] = try await send(
            path: "rpc/get_club_entitlements",
            queryItems: [],
            method: "POST",
            body: try? JSONSerialization.data(withJSONObject: ["p_club_id": clubID.uuidString.lowercased()]),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        guard let row = rows.first,
              let cid = UUID(uuidString: row.club_id) else { return nil }

        return ClubEntitlements(
            clubID: cid,
            planTier: row.plan_tier,
            maxActiveGames: row.max_active_games,
            maxMembers: row.max_members,
            canAcceptPayments: row.can_accept_payments,
            analyticsAccess: row.analytics_access,
            canUseRecurringGames: row.can_use_recurring_games,
            canUseDelayedPublishing: row.can_use_delayed_publishing,
            lockedFeatures: row.locked_features,
            updatedAt: row.updated_at.flatMap(SupabaseDateParser.parse) ?? Date()
        )
    }

    func createClubSubscription(clubID: UUID, priceID: String) async throws -> ClubSubscriptionResult {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.missingConfiguration
        }

        let url = baseURL.appendingPathComponent("functions/v1/\(SupabaseConfig.createClubSubscriptionFunctionName)")

        struct RequestBody: Encodable {
            let club_id: String
            let price_id: String
        }
        struct ResponseBody: Decodable {
            let subscription_id: String
            let status: String
            let client_secret: String?
        }

        let body = try JSONEncoder().encode(RequestBody(club_id: clubID.uuidString, price_id: priceID))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "Subscription creation failed"
            throw SupabaseServiceError.httpStatus(statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        return ClubSubscriptionResult(
            subscriptionID: decoded.subscription_id,
            status: decoded.status,
            clientSecret: decoded.client_secret
        )
    }

    func cancelClubSubscription(clubID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.missingConfiguration
        }

        let url = baseURL.appendingPathComponent("functions/v1/\(SupabaseConfig.cancelClubSubscriptionFunctionName)")

        struct RequestBody: Encodable {
            let club_id: String
        }

        let body = try JSONEncoder().encode(RequestBody(club_id: clubID.uuidString))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "Subscription cancellation failed"
            throw SupabaseServiceError.httpStatus(statusCode, msg)
        }
    }

    // MARK: - Credits (Phase 2)

    func fetchCreditBalance(userID: UUID, clubID: UUID) async throws -> Int {
        guard SupabaseConfig.isConfigured else { return 0 }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return 0 }
        struct CreditRow: Decodable { let amount_cents: Int }
        let rows: [CreditRow] = try await send(
            path: "player_credits",
            queryItems: [
                .init(name: "select", value: "amount_cents"),
                .init(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString.lowercased())"),
                .init(name: "currency", value: "eq.aud")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        // Sum all matching rows — normally one row per (user, club, currency),
        // but summing is a safe fallback if the unique constraint ever fails.
        return rows.reduce(0) { $0 + $1.amount_cents }
    }

    func applyCredits(userID: UUID, bookingID: UUID, amountCents: Int, clubID: UUID) async throws -> Bool {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        guard amountCents > 0 else { return false }

        // Fetch live balance — we need it to compute the new value for the PATCH.
        let currentBalance = try await fetchCreditBalance(userID: userID, clubID: clubID)
        guard currentBalance >= amountCents else { return false }

        let newBalance = currentBalance - amountCents
        struct UpdateBody: Encodable { let amount_cents: Int }
        let body = try JSONEncoder().encode(UpdateBody(amount_cents: newBalance))

        // Direct table PATCH — avoids PostgREST schema-cache issues with RPCs.
        // The `amount_cents=gte.{amountCents}` filter is an atomic safety net:
        // if another request already drained the balance the UPDATE matches 0 rows.
        try await sendVoid(
            path: "player_credits",
            queryItems: [
                .init(name: "user_id",      value: "eq.\(userID.uuidString.lowercased())"),
                .init(name: "club_id",      value: "eq.\(clubID.uuidString.lowercased())"),
                .init(name: "currency",     value: "eq.aud"),
                .init(name: "amount_cents", value: "gte.\(amountCents)")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken
        )
        return true
    }


    // MARK: - Waitlist Promotion (Phase 3)

    func promoteWaitlistPlayer(gameID: UUID, bookingID: UUID, holdMinutes: Int) async throws -> Bool {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        // NOTE: The promote_waitlist_player RPC returns PGRST202 — PostgREST's schema cache
        // does not pick up this function (same pattern as use_credits / issue_cancellation_credit).
        // Reimplemented as a direct PATCH on bookings, same approach as applyCredits.
        //
        // Atomicity: the status=eq.waitlisted filter means the PATCH only applies if the
        // booking is still waitlisted — if the DB trigger promote_top_waitlisted() already
        // promoted it (fires on confirmed→cancelled), the PATCH affects 0 rows and we return
        // false, which the caller treats as a safe no-op.

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let holdExpiry = iso.string(from: Date().addingTimeInterval(Double(holdMinutes) * 60))
        let nowStr     = iso.string(from: Date())

        let body = try JSONSerialization.data(withJSONObject: [
            "status":            "pending_payment",
            "waitlist_position": NSNull(),
            "hold_expires_at":   holdExpiry,
            "promoted_at":       nowStr
        ])

        let rows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "id",     value: "eq.\(bookingID.uuidString.lowercased())"),
                .init(name: "status", value: "eq.waitlisted"),
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id,payment_method,platform_fee_cents,club_payout_cents,credits_applied_cents,hold_expires_at")
            ],
            method: "PATCH",
            body: body,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer":       "return=representation",
                "Content-Type": "application/json"
            ]
        )

        // true  = booking was waitlisted and is now promoted to pending_payment
        // false = booking was no longer waitlisted (trigger already handled it, or it was cancelled)
        return !rows.isEmpty
    }

    func fetchClubAdminUserIDs(clubID: UUID) async throws -> [UUID] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return [] }
        let rows: [ClubAdminIDRow] = try await send(
            path: "club_admins",
            queryItems: [
                .init(name: "select", value: "user_id"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.map(\.userID)
    }

    private func invokeEdgeFunction(name: String, body: Data) async throws {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else { return }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return }
        let url = baseURL.appendingPathComponent("functions/v1/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseText = String(data: data, encoding: .utf8) ?? "(no body)"
        guard (200...299).contains(statusCode) else {
            print("[EdgeFunction] ← \(name) \(statusCode): \(responseText)")
            throw SupabaseServiceError.httpStatus(statusCode, responseText)
        }
    }

    // MARK: - Notification Preferences

    func fetchNotificationPreferences(userID: UUID) async throws -> NotificationPreferences? {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let rows: [NotificationPreferences] = try await send(
            path: "notification_preferences",
            queryItems: [
                .init(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                .init(name: "select", value: "booking_confirmed_push,booking_confirmed_email,new_game_push,new_game_email,waitlist_push,waitlist_email,chat_push")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.first
    }

    func saveNotificationPreferences(userID: UUID, prefs: NotificationPreferences) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        struct UpsertBody: Encodable {
            let userID: String
            let bookingConfirmedPush:  Bool
            let bookingConfirmedEmail: Bool
            let newGamePush:           Bool
            let newGameEmail:          Bool
            let waitlistPush:          Bool
            let waitlistEmail:         Bool
            let chatPush:              Bool
            enum CodingKeys: String, CodingKey {
                case userID                = "user_id"
                case bookingConfirmedPush  = "booking_confirmed_push"
                case bookingConfirmedEmail = "booking_confirmed_email"
                case newGamePush           = "new_game_push"
                case newGameEmail          = "new_game_email"
                case waitlistPush          = "waitlist_push"
                case waitlistEmail         = "waitlist_email"
                case chatPush              = "chat_push"
            }
        }

        let body = UpsertBody(
            userID: userID.uuidString.lowercased(),
            bookingConfirmedPush:  prefs.bookingConfirmedPush,
            bookingConfirmedEmail: prefs.bookingConfirmedEmail,
            newGamePush:           prefs.newGamePush,
            newGameEmail:          prefs.newGameEmail,
            waitlistPush:          prefs.waitlistPush,
            waitlistEmail:         prefs.waitlistEmail,
            chatPush:              prefs.chatPush
        )

        try await sendVoid(
            path: "notification_preferences",
            queryItems: [.init(name: "on_conflict", value: "user_id")],
            method: "POST",
            body: try JSONEncoder().encode(body),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "resolution=merge-duplicates",
                "Content-Type": "application/json"
            ]
        )
    }

    // MARK: - Avatar Palettes

    func fetchAvatarPalettes() async throws -> [AvatarPaletteRow] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return [] }
        return try await send(
            path: "avatar_palettes",
            queryItems: [
                .init(name: "select", value: "palette_key,palette_name,category,gradient_start_hex,gradient_end_hex,is_default,display_order"),
                .init(name: "is_active", value: "eq.true"),
                .init(name: "order",  value: "display_order.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
    }

    // MARK: - Plan Tier Limits

    func fetchPlanTierLimits() async throws -> [String: PlanTierLimits] {
        guard SupabaseConfig.isConfigured else { return [:] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return [:] }

        struct Row: Decodable {
            let plan_tier: String
            let max_active_games: Int
            let max_members: Int
            let can_accept_payments: Bool
            let analytics_access: Bool
            let can_use_recurring_games: Bool
            let can_use_delayed_publishing: Bool
        }

        let rows: [Row] = try await send(
            path: "rpc/get_plan_tier_limits",
            queryItems: [],
            method: "POST",
            body: try? JSONSerialization.data(withJSONObject: [:]),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.plan_tier, PlanTierLimits(
                planTier: row.plan_tier,
                maxActiveGames: row.max_active_games,
                maxMembers: row.max_members,
                canAcceptPayments: row.can_accept_payments,
                analyticsAccess: row.analytics_access,
                canUseRecurringGames: row.can_use_recurring_games,
                canUseDelayedPublishing: row.can_use_delayed_publishing
            ))
        })
    }

    func fetchSubscriptionPlans() async throws -> [SubscriptionPlan] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return [] }

        struct Row: Decodable {
            let plan_id: String
            let display_name: String
            let stripe_price_id: String
            let display_price: String
            let billing_interval: String
            let sort_order: Int
        }

        let rows: [Row] = try await send(
            path: "rpc/get_subscription_plans",
            queryItems: [],
            method: "POST",
            body: try? JSONSerialization.data(withJSONObject: [:]),
            authBearerToken: authToken,
            extraHeaders: ["Content-Type": "application/json"]
        )

        return rows.map { row in
            SubscriptionPlan(
                planID: row.plan_id,
                displayName: row.display_name,
                stripePriceID: row.stripe_price_id,
                displayPrice: row.display_price,
                billingInterval: row.billing_interval,
                sortOrder: row.sort_order
            )
        }
    }

    // MARK: - App Config

    func fetchAppConfig() async throws -> [String: String] {
        guard SupabaseConfig.isConfigured else { return [:] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else { return [:] }

        struct Row: Decodable {
            let key: String
            let value: String
        }

        let rows: [Row] = try await send(
            path: "app_config",
            queryItems: [URLQueryItem(name: "select", value: "key,value")],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
    }

    // MARK: - REST

    private func send<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?,
        authBearerToken: String?,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        let request = try buildRequest(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            authBearerToken: authBearerToken,
            extraHeaders: extraHeaders
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SupabaseServiceError.decoding(error.localizedDescription)
        }
    }

    /// Variant of `send` for RPCs that return VOID (HTTP 204 No Content).
    /// Throws on network errors and non-2xx status codes so failures are visible.
    private func sendVoid(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "POST",
        body: Data?,
        authBearerToken: String?,
        extraHeaders: [String: String] = [:]
    ) async throws {
        let request = try buildRequest(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            authBearerToken: authBearerToken,
            extraHeaders: extraHeaders
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }
        // 204 No Content is expected for VOID RPCs — nothing to decode
    }

    private func sendAuth<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?
    ) async throws -> T {
        let request = try buildAuthRequest(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SupabaseServiceError.decoding(error.localizedDescription)
        }
    }

    private func buildRequest(
        path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?,
        authBearerToken: String?,
        extraHeaders: [String: String]
    ) throws -> URLRequest {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        let restBase = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
        var components = URLComponents(url: restBase, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw SupabaseServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        // Never serve stale data from the local HTTP cache — PostgREST GET responses
        // can be cached by URLSession and cause feature-gate state to lag after DB writes.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("public", forHTTPHeaderField: "Accept-Profile")

        if body != nil {
            request.setValue("public", forHTTPHeaderField: "Content-Profile")
        }

        let bearer = (authBearerToken?.isEmpty == false) ? authBearerToken! : SupabaseConfig.anonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    private func buildAuthRequest(
        path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?
    ) throws -> URLRequest {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        let authBase = baseURL
            .appendingPathComponent("auth")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
        var components = URLComponents(url: authBase, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw SupabaseServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func uploadStorageObject(
        bucket: String,
        objectPath: String,
        data: Data,
        contentType: String,
        authBearerToken: String
    ) async throws {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        var url = baseURL
            .appendingPathComponent("storage")
            .appendingPathComponent("v1")
            .appendingPathComponent("object")
            .appendingPathComponent(bucket)
        for component in objectPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authBearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: responseData, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }
    }

    private func deleteStorageObject(
        bucket: String,
        objectPath: String,
        authBearerToken: String
    ) async throws {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else {
            throw SupabaseServiceError.invalidURL
        }

        var url = baseURL
            .appendingPathComponent("storage")
            .appendingPathComponent("v1")
            .appendingPathComponent("object")
            .appendingPathComponent(bucket)
        for component in objectPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authBearerToken)", forHTTPHeaderField: "Authorization")

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw SupabaseServiceError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.network("Non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: responseData, encoding: .utf8) ?? "<no body>"
            throw SupabaseServiceError.httpStatus(httpResponse.statusCode, bodyString)
        }
    }

    private func publicStorageURL(bucket: String, objectPath: String) -> URL {
        let base = URL(string: SupabaseConfig.urlString)!
        var url = base
            .appendingPathComponent("storage")
            .appendingPathComponent("v1")
            .appendingPathComponent("object")
            .appendingPathComponent("public")
            .appendingPathComponent(bucket)
        for component in objectPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func storageObjectPathIfManagedClubNewsURL(_ url: URL, bucket: String) -> String? {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else { return nil }
        guard url.host == baseURL.host else { return nil }
        let expectedPrefix = "/storage/v1/object/public/\(bucket)/"
        guard url.path.hasPrefix(expectedPrefix) else { return nil }
        let objectPath = String(url.path.dropFirst(expectedPrefix.count))
        guard objectPath.hasPrefix("club-news/") else { return nil }
        return objectPath.removingPercentEncoding ?? objectPath
    }

    private func resolvedAccessToken() -> String? {
        if let dynamic = authAccessTokenProvider(), !dynamic.isEmpty {
            return dynamic
        }
        return storedAccessToken
    }

    private func nilIfEmpty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedGameTextField(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // For PATCH updates, send an empty string (not nil) so the field is actually cleared in Supabase.
        return trimmed.isEmpty ? "" : trimmed
    }

    private static func buildMemberCounts(_ rows: [ClubMemberStatusRow]) -> [UUID: Int] {
        // Prefer approved-like statuses when present, otherwise count all requests.
        let approvedKeywords = Set(["approved", "active", "member"])
        let hasApprovedStatuses = rows.contains { approvedKeywords.contains($0.status.lowercased()) }

        return rows.reduce(into: [:]) { counts, row in
            if hasApprovedStatuses {
                guard approvedKeywords.contains(row.status.lowercased()) else { return }
            }
            counts[row.clubID, default: 0] += 1
        }
    }

    private static func buildBookingCounts(_ rows: [GameBookingStatusRow]) -> [UUID: (confirmed: Int, waitlisted: Int)] {
        rows.reduce(into: [:]) { result, row in
            var counts = result[row.gameID] ?? (confirmed: 0, waitlisted: 0)
            switch BookingStateMapper.map(raw: row.status, waitlistPosition: nil) {
            case .confirmed:
                counts.confirmed += 1
            case .waitlisted:
                counts.waitlisted += 1
            case .none, .cancelled, .unknown, .pendingPayment:
                break
            }
            result[row.gameID] = counts
        }
    }

    private func clubIDGamesList(from rows: [GameRow]) -> String {
        let ids = rows.map(\.id.uuidString)
        return ids.isEmpty ? "00000000-0000-0000-0000-000000000000" : ids.joined(separator: ",")
    }

    private func attendeeComparator(lhs: GameAttendee, rhs: GameAttendee) -> Bool {
        let lRank = attendeeSortRank(lhs.booking.state)
        let rRank = attendeeSortRank(rhs.booking.state)
        if lRank != rRank { return lRank < rRank }

        switch (lhs.booking.state, rhs.booking.state) {
        case let (.waitlisted(lp), .waitlisted(rp)):
            let lPos = lp ?? Int.max
            let rPos = rp ?? Int.max
            if lPos != rPos { return lPos < rPos }
        default:
            break
        }

        if lhs.userName.caseInsensitiveCompare(rhs.userName) != .orderedSame {
            return lhs.userName.localizedCaseInsensitiveCompare(rhs.userName) == .orderedAscending
        }
        return lhs.booking.id.uuidString < rhs.booking.id.uuidString
    }

    private func attendeeSortRank(_ state: BookingState) -> Int {
        switch state {
        case .confirmed:
            return 0
        case .pendingPayment:
            return 1
        case .waitlisted:
            return 2
        case .unknown:
            return 3
        case .cancelled:
            return 4
        case .none:
            return 5
        }
    }

    private static func displayName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Member" : trimmed
    }

    private func parseModerationReport(from row: ClubMessageRow) -> (targetKind: ClubNewsModerationReport.TargetKind, targetID: UUID?, reason: String, details: String) {
        let bodyData = row.body.data(using: .utf8)
        if let bodyData,
           let parsed = try? JSONDecoder().decode(ClubNewsReportMessageBody.self, from: bodyData) {
            return (
                targetKind: ClubNewsModerationReport.TargetKind(rawValue: parsed.targetKind) ?? .unknown,
                targetID: parsed.targetID.flatMap(UUID.init(uuidString:)),
                reason: parsed.reason,
                details: parsed.details
            )
        }

        let subject = row.subject.uppercased()
        let targetKind: ClubNewsModerationReport.TargetKind
        if subject.hasPrefix("REPORT_POST") {
            targetKind = .post
        } else if subject.hasPrefix("REPORT_COMMENT") {
            targetKind = .comment
        } else {
            targetKind = .unknown
        }
        let subjectParts = row.subject.split(separator: ":")
        let targetID = subjectParts.count > 1 ? UUID(uuidString: String(subjectParts[1])) : nil
        return (targetKind, targetID, "Reported", row.body)
    }

    // MARK: - Club Venues

    func fetchClubVenues(clubID: UUID) async throws -> [ClubVenue] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let rows: [ClubVenueRow] = try await send(
            path: "club_venues",
            queryItems: [
                .init(name: "select", value: "id,club_id,venue_name,street_address,suburb,state,postcode,country,is_primary,latitude,longitude"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
                .init(name: "order", value: "is_primary.desc,venue_name.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )
        return rows.map { $0.toVenue() }
    }

    func createClubVenue(clubID: UUID, draft: ClubVenueDraft, latitude: Double?, longitude: Double?) async throws -> ClubVenue {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let insert = ClubVenueInsertRow(
            clubID: clubID,
            venueName: draft.venueName.trimmingCharacters(in: .whitespacesAndNewlines),
            streetAddress: draft.streetAddress.isEmpty ? nil : draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            suburb: draft.suburb.isEmpty ? nil : draft.suburb.trimmingCharacters(in: .whitespacesAndNewlines),
            state: draft.state.isEmpty ? nil : draft.state.trimmingCharacters(in: .whitespacesAndNewlines),
            postcode: draft.postcode.isEmpty ? nil : draft.postcode.trimmingCharacters(in: .whitespacesAndNewlines),
            country: draft.country.isEmpty ? nil : draft.country.trimmingCharacters(in: .whitespacesAndNewlines),
            isPrimary: draft.isPrimary,
            latitude: latitude,
            longitude: longitude
        )
        let rows: [ClubVenueRow] = try await send(
            path: "club_venues",
            queryItems: [.init(name: "select", value: "id,club_id,venue_name,street_address,suburb,state,postcode,country,is_primary,latitude,longitude")],
            method: "POST",
            body: try JSONEncoder().encode([insert]),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return row.toVenue()
    }

    func updateClubVenue(venueID: UUID, draft: ClubVenueDraft, latitude: Double?, longitude: Double?, updateCoordinates: Bool) async throws -> ClubVenue {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let update = ClubVenueUpdateRow(
            venueName: draft.venueName.trimmingCharacters(in: .whitespacesAndNewlines),
            streetAddress: draft.streetAddress.isEmpty ? nil : draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            suburb: draft.suburb.isEmpty ? nil : draft.suburb.trimmingCharacters(in: .whitespacesAndNewlines),
            state: draft.state.isEmpty ? nil : draft.state.trimmingCharacters(in: .whitespacesAndNewlines),
            postcode: draft.postcode.isEmpty ? nil : draft.postcode.trimmingCharacters(in: .whitespacesAndNewlines),
            country: draft.country.isEmpty ? nil : draft.country.trimmingCharacters(in: .whitespacesAndNewlines),
            isPrimary: draft.isPrimary,
            updateCoordinates: updateCoordinates,
            newLatitude: latitude,
            newLongitude: longitude
        )
        let rows: [ClubVenueRow] = try await send(
            path: "club_venues",
            queryItems: [
                .init(name: "id", value: "eq.\(venueID.uuidString)"),
                .init(name: "select", value: "id,club_id,venue_name,street_address,suburb,state,postcode,country,is_primary,latitude,longitude")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(update),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
        guard let row = rows.first else { throw SupabaseServiceError.notFound }
        return row.toVenue()
    }

    func deleteClubVenue(venueID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let _: [ClubVenueRow] = try await send(
            path: "club_venues",
            queryItems: [
                .init(name: "id", value: "eq.\(venueID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: ["Prefer": "return=representation"]
        )
    }

    func updateClubCoordinates(clubID: UUID, latitude: Double, longitude: Double) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let patch = ClubCoordinatePatch(latitude: latitude, longitude: longitude)
        let _: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(patch),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func updateClubVenueName(clubID: UUID, venueName: String) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        let patch = ClubVenueNamePatch(venue_name: venueName)
        let _: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(patch),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }

    func demoteOtherPrimaryVenues(clubID: UUID, exceptVenueID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }
        struct Patch: Encodable {
            let is_primary: Bool
        }
        let _: [ClubVenueRow] = try await send(
            path: "club_venues",
            queryItems: [
                .init(name: "club_id",    value: "eq.\(clubID.uuidString)"),
                .init(name: "id",         value: "neq.\(exceptVenueID.uuidString)"),
                .init(name: "is_primary", value: "eq.true"),
                .init(name: "select",     value: "id")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(Patch(is_primary: false)),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )
    }
}

// MARK: - DTOs

private struct SupabaseEmailAuthRequest: Encodable {
    let email: String
    let password: String
}

private struct SupabaseRefreshTokenRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct SupabaseAuthResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let user: SupabaseAuthUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SupabaseAuthUser: Decodable {
    let id: String
    let email: String?
}

private struct ClubRow: Decodable {
    let id: UUID
    let name: String
    let description: String?
    let imageURLString: String?
    let contactEmail: String?
    let contactPhone: String?
    let website: String?
    let managerName: String?
    let membersOnly: Bool
    let createdByUserID: UUID?
    let winConditionRaw: String?
    let defaultCourtCount: Int?
    let venueName: String?
    let streetAddress: String?
    let suburb: String?
    let state: String?
    let postcode: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let heroImageKey: String?
    let customBannerURLString: String?
    let codeOfConduct: String?
    let cancellationPolicy: String?
    let stripeConnectID: String?
    let avatarBackgroundColorHex: String?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case imageURLString = "image_url"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case website
        case managerName = "manager_name"
        case membersOnly = "members_only"
        case createdByUserID = "created_by"
        case winConditionRaw = "win_condition"
        case defaultCourtCount = "default_court_count"
        case venueName = "venue_name"
        case streetAddress = "street_address"
        case suburb
        case state
        case postcode
        case country
        case latitude
        case longitude
        case heroImageKey = "hero_image_key"
        case customBannerURLString = "custom_banner_url"
        case codeOfConduct = "code_of_conduct"
        case cancellationPolicy = "cancellation_policy"
        case stripeConnectID = "stripe_connect_id"
        case avatarBackgroundColorHex = "avatar_background_color"
        case timezone
    }

    func toClub(memberCount: Int, seedMembers: [ClubMember], seedTags: [String]) -> Club {
        let safeName = Self.sanitizedText(name, maxLength: 120) ?? "Club"
        let safeDescription = Self.sanitizedText(description, maxLength: 2000) ?? "No club description yet."
        let safeContactEmail = Self.sanitizedText(contactEmail, maxLength: 320) ?? "No contact email listed"
        let safeContactPhone = Self.sanitizedText(contactPhone, maxLength: 30)
        let safeWebsite = Self.sanitizedText(website, maxLength: 260)
        let safeManagerName = Self.sanitizedText(managerName, maxLength: 160)
        let safeImageURL = Self.sanitizedURL(imageURLString)

        // Derive city/region from structured fields; fall back to empty strings.
        let safeSuburb = Self.sanitizedText(suburb, maxLength: 80) ?? ""
        let safeState = Self.sanitizedText(state, maxLength: 80) ?? ""
        let safeVenueName = Self.sanitizedText(venueName, maxLength: 260)

        // Build a legacy address string from structured fields for map/fallback use.
        let addressParts = [safeVenueName, streetAddress, safeSuburb, safeState, postcode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let derivedAddress = addressParts.joined(separator: ", ")

        return Club(
            id: id,
            name: safeName,
            city: safeSuburb.isEmpty ? safeVenueName ?? "" : safeSuburb,
            region: safeState,
            memberCount: memberCount,
            description: safeDescription,
            contactEmail: safeContactEmail,
            contactPhone: safeContactPhone,
            address: derivedAddress,
            imageSystemName: "building.2.crop.circle.fill",
            imageURL: safeImageURL,
            website: safeWebsite,
            managerName: safeManagerName,
            membersOnly: membersOnly,
            tags: seedTags.isEmpty ? Self.defaultTags(membersOnly: membersOnly) : seedTags,
            topMembers: seedMembers,
            createdByUserID: createdByUserID,
            winCondition: WinCondition(raw: winConditionRaw),
            defaultCourtCount: defaultCourtCount ?? 1,
            venueName: venueName,
            streetAddress: streetAddress,
            suburb: suburb,
            state: state,
            postcode: postcode,
            country: country,
            latitude: latitude,
            longitude: longitude,
            heroImageKey: heroImageKey,
            customBannerURL: Self.sanitizedURL(customBannerURLString),
            codeOfConduct: codeOfConduct,
            cancellationPolicy: cancellationPolicy,
            stripeConnectID: stripeConnectID,
            avatarBackgroundColor: avatarBackgroundColorHex,
            timezone: timezone ?? "Australia/Perth"
        )
    }

    private static func defaultTags(membersOnly: Bool) -> [String] {
        membersOnly ? ["Members Only"] : ["Open Club"]
    }

    private static func parseLocation(_ raw: String?) -> (city: String, region: String) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("Unknown", "")
        }

        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2 {
            return (parts[0], parts.dropFirst().joined(separator: ", "))
        }
        return (raw, "")
    }

    private static func sanitizedText(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    private static func sanitizedURL(_ raw: String?) -> URL? {
        guard let trimmed = sanitizedText(raw, maxLength: 2048) else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let isAllowed = scheme == "http" || scheme == "https"
        return isAllowed ? url : nil
    }
}

private struct ClubMemberStatusRow: Decodable {
    let clubID: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case status
    }
}

private struct ClubMembershipUserRow: Decodable {
    let clubID: UUID
    let userID: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case status
    }
}

private struct ClubJoinRequestRow: Decodable {
    let id: UUID
    let clubID: UUID
    let userID: UUID
    let status: String
    let requestedAtRaw: String?
    let conductAcceptedAtRaw: String?
    let cancellationPolicyAcceptedAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id
        case clubID = "club_id"
        case userID = "user_id"
        case status
        case requestedAtRaw = "requested_at"
        case conductAcceptedAtRaw = "conduct_accepted_at"
        case cancellationPolicyAcceptedAtRaw = "cancellation_policy_accepted_at"
    }
}

private struct OwnerProfileLiteRow: Decodable {
    let id: UUID
    let fullName: String?
    let email: String?
    let phone: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?
    let duprRating: Double?
    let duprUpdatedAtRaw: String?
    let duprUpdatedByName: String?
    let avatarColorKey: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case email
        case phone
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
        case duprRating = "dupr_rating"
        case duprUpdatedAtRaw = "dupr_updated_at"
        case duprUpdatedByName = "dupr_updated_by_name"
        case avatarColorKey = "avatar_color_key"
    }
}

private struct ClubDirectoryProfileRow: Decodable {
    let id: UUID
    let fullName: String?
    let duprRating: Double?
    let avatarColorKey: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case duprRating = "dupr_rating"
        case avatarColorKey = "avatar_color_key"
    }
}

private struct ClubAdminRow: Decodable {
    let clubID: UUID
    let userID: UUID
    let role: ClubAdminRole?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case role
    }
}

private struct ClubMembershipInsertBody: Encodable {
    let clubID: UUID
    let userID: UUID
    let conductAcceptedAt: String?
    let cancellationPolicyAcceptedAt: String?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case conductAcceptedAt = "conduct_accepted_at"
        case cancellationPolicyAcceptedAt = "cancellation_policy_accepted_at"
    }
}

private struct ClubMembershipOwnerInsertBody: Encodable {
    let clubID: UUID
    let userID: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case status
    }
}

private struct ClubMembershipDecisionUpdateBody: Encodable {
    let status: String
    let respondedAt: String
    let respondedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case status
        case respondedAt = "responded_at"
        case respondedBy = "responded_by"
    }
}

private struct ClubAdminUpsertBody: Encodable {
    let clubID: UUID
    let userID: UUID
    let role: ClubAdminRole

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case role
    }
}

private struct ProfileUpsertRow: Encodable {
    let id: UUID
    let email: String
    let firstName: String?
    let lastName: String?
    let fullName: String
    let phone: String?
    let dateOfBirth: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?
    let duprRating: Double?
    let duprID: String?
    let avatarColorKey: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name"
        case lastName = "last_name"
        case fullName = "full_name"
        case phone
        case dateOfBirth = "date_of_birth"
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
        case duprRating = "dupr_rating"
        case duprID = "dupr_id"
        case avatarColorKey = "avatar_color_key"
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let email: String
    let firstName: String?
    let lastName: String?
    let fullName: String?
    let phone: String?
    let dateOfBirth: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?
    let duprRating: Double?
    let duprID: String?
    let avatarColorKey: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name"
        case lastName = "last_name"
        case fullName = "full_name"
        case phone
        case dateOfBirth = "date_of_birth"
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
        case duprRating = "dupr_rating"
        case duprID = "dupr_id"
        case avatarColorKey = "avatar_color_key"
    }
}

private struct GameRow: Decodable {
    let id: UUID
    let clubID: UUID
    let recurrenceGroupID: UUID?
    let title: String
    let description: String?
    let dateTimeRaw: String
    let durationMinutes: Int
    let skillLevel: String
    let gameFormat: String
    let gameType: String?
    let maxSpots: Int
    let feeAmount: Double?
    let feeCurrency: String?
    let venueId: UUID?
    let venueName: String?
    let location: String?
    let latitude: Double?
    let longitude: Double?
    let status: String
    let notes: String?
    let requiresDUPR: Bool?
    let courtCount: Int?
    let publishAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id
        case clubID = "club_id"
        case recurrenceGroupID = "recurrence_group_id"
        case title
        case description
        case dateTimeRaw = "date_time"
        case durationMinutes = "duration_minutes"
        case skillLevel = "skill_level"
        case gameFormat = "game_format"
        case gameType = "game_type"
        case maxSpots = "max_spots"
        case feeAmount = "fee_amount"
        case feeCurrency = "fee_currency"
        case venueId = "venue_id"
        case venueName = "venue_name"
        case location
        case latitude
        case longitude
        case status
        case notes
        case requiresDUPR = "requires_dupr"
        case courtCount = "court_count"
        case publishAtRaw = "publish_at"
    }

    func toGame(confirmedCount: Int?, waitlistCount: Int?) -> Game {
        return Game(
            id: id,
            clubID: clubID,
            recurrenceGroupID: recurrenceGroupID,
            title: title,
            description: description,
            dateTime: SupabaseDateParser.parse(dateTimeRaw) ?? Date(),
            durationMinutes: durationMinutes,
            skillLevel: skillLevel,
            gameFormat: gameFormat,
            gameType: gameType ?? "doubles",
            maxSpots: maxSpots,
            feeAmount: feeAmount,
            feeCurrency: feeCurrency,
            venueId: venueId,
            venueName: venueName,
            location: location,
            latitude: latitude,
            longitude: longitude,
            status: status,
            notes: notes,
            requiresDUPR: requiresDUPR ?? false,
            courtCount: courtCount ?? 1,
            confirmedCount: confirmedCount,
            waitlistCount: waitlistCount,
            publishAt: publishAtRaw.flatMap { SupabaseDateParser.parse($0) }
        )
    }
}

private struct GameInsertRow: Encodable {
    let clubID: UUID
    let title: String
    let description: String?
    let dateTime: String
    let durationMinutes: Int
    let maxSpots: Int
    let courtCount: Int
    let feeAmount: Double?
    let feeCurrency: String?
    let venueId: UUID?
    let venueName: String?
    let latitude: Double?
    let longitude: Double?
    let location: String?
    let notes: String?
    let createdBy: UUID
    let requiresDUPR: Bool
    let skillLevel: String
    let gameFormat: String
    let gameType: String
    let recurrenceGroupID: UUID?
    let publishAt: String?
    let status: String = "upcoming"

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case title
        case description
        case dateTime = "date_time"
        case durationMinutes = "duration_minutes"
        case maxSpots = "max_spots"
        case courtCount = "court_count"
        case feeAmount = "fee_amount"
        case feeCurrency = "fee_currency"
        case venueId = "venue_id"
        case venueName = "venue_name"
        case latitude, longitude
        case location
        case notes
        case createdBy = "created_by"
        case requiresDUPR = "requires_dupr"
        case skillLevel = "skill_level"
        case gameFormat = "game_format"
        case gameType = "game_type"
        case recurrenceGroupID = "recurrence_group_id"
        case publishAt = "publish_at"
        case status
    }
}

private struct GameOwnerUpdateRow: Encodable {
    let title: String
    let description: String?
    let dateTime: String
    let durationMinutes: Int
    let skillLevel: String
    let gameFormat: String
    let gameType: String
    let maxSpots: Int
    let courtCount: Int
    let feeAmount: Double?
    let feeCurrency: String
    let venueId: UUID?
    let venueName: String?
    let location: String?
    let notes: String?
    let requiresDUPR: Bool
    /// When true, latitude/longitude are included in the PATCH (venue was selected this session).
    /// When false, they are omitted entirely — existing DB coordinates are preserved.
    let updateCoordinates: Bool
    let latitude: Double?
    let longitude: Double?
    let publishAt: String?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case dateTime = "date_time"
        case durationMinutes = "duration_minutes"
        case skillLevel = "skill_level"
        case gameFormat = "game_format"
        case gameType = "game_type"
        case maxSpots = "max_spots"
        case courtCount = "court_count"
        case feeAmount = "fee_amount"
        case feeCurrency = "fee_currency"
        case venueId = "venue_id"
        case venueName = "venue_name"
        case location
        case notes
        case requiresDUPR = "requires_dupr"
        case latitude, longitude
        case publishAt = "publish_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title,          forKey: .title)
        try c.encode(description,    forKey: .description)
        try c.encode(dateTime,       forKey: .dateTime)
        try c.encode(durationMinutes, forKey: .durationMinutes)
        try c.encode(skillLevel,     forKey: .skillLevel)
        try c.encode(gameFormat,     forKey: .gameFormat)
        try c.encode(gameType,       forKey: .gameType)
        try c.encode(maxSpots,       forKey: .maxSpots)
        try c.encode(courtCount,     forKey: .courtCount)
        try c.encode(feeAmount,      forKey: .feeAmount)
        try c.encode(feeCurrency,    forKey: .feeCurrency)
        try c.encode(venueId,        forKey: .venueId)
        try c.encode(venueName,      forKey: .venueName)
        try c.encode(location,       forKey: .location)
        try c.encode(notes,          forKey: .notes)
        try c.encode(requiresDUPR,   forKey: .requiresDUPR)
        try c.encode(publishAt,      forKey: .publishAt)
        if updateCoordinates {
            try c.encode(latitude,   forKey: .latitude)
            try c.encode(longitude,  forKey: .longitude)
        }
    }
}

private struct GameBookingStatusRow: Decodable {
    let gameID: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case status
    }
}

private struct BookingRow: Decodable {
    let id: UUID
    let gameID: UUID
    let userID: UUID
    let status: String
    let waitlistPosition: Int?
    let createdAtRaw: String?
    let feePaid: Bool?
    let paidAtRaw: String?
    let stripePaymentIntentID: String?
    let paymentMethod: String?
    let platformFeeCents: Int?
    let clubPayoutCents: Int?
    let creditsAppliedCents: Int?
    let holdExpiresAtRaw: String?
    let gameRow: GameRow?

    enum CodingKeys: String, CodingKey {
        case id
        case gameID = "game_id"
        case userID = "user_id"
        case status
        case waitlistPosition = "waitlist_position"
        case createdAtRaw = "created_at"
        case feePaid = "fee_paid"
        case paidAtRaw = "paid_at"
        case stripePaymentIntentID = "stripe_payment_intent_id"
        case paymentMethod = "payment_method"
        case platformFeeCents = "platform_fee_cents"
        case clubPayoutCents = "club_payout_cents"
        case creditsAppliedCents = "credits_applied_cents"
        case holdExpiresAtRaw = "hold_expires_at"
        case gameRow = "games"
    }

    func toBookingRecord() -> BookingRecord {
        BookingRecord(
            id: id,
            gameID: gameID,
            userID: userID,
            state: BookingStateMapper.map(raw: status, waitlistPosition: waitlistPosition),
            waitlistPosition: waitlistPosition,
            createdAt: createdAtRaw.flatMap(SupabaseDateParser.parse),
            feePaid: feePaid ?? false,
            paidAt: paidAtRaw.flatMap(SupabaseDateParser.parse),
            stripePaymentIntentID: stripePaymentIntentID,
            paymentMethod: paymentMethod,
            platformFeeCents: platformFeeCents,
            clubPayoutCents: clubPayoutCents,
            creditsAppliedCents: creditsAppliedCents,
            holdExpiresAt: holdExpiresAtRaw.flatMap(SupabaseDateParser.parse)
        )
    }
}

private struct BookingInsertBody: Encodable {
    let gameID: UUID
    let userID: UUID
    let status: String
    let waitlistPosition: Int?
    let feePaid: Bool?
    let stripePaymentIntentID: String?
    let paymentMethod: String?
    let platformFeeCents: Int?
    let clubPayoutCents: Int?
    let creditsAppliedCents: Int?

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case userID = "user_id"
        case status
        case waitlistPosition = "waitlist_position"
        case feePaid = "fee_paid"
        case stripePaymentIntentID = "stripe_payment_intent_id"
        case paymentMethod = "payment_method"
        case platformFeeCents = "platform_fee_cents"
        case clubPayoutCents = "club_payout_cents"
        case creditsAppliedCents = "credits_applied_cents"
    }

    // Skip nil optional fields entirely so PostgREST doesn't error on columns
    // that haven't been migrated yet ("column X does not exist").
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gameID,  forKey: .gameID)
        try c.encode(userID,  forKey: .userID)
        try c.encode(status,  forKey: .status)
        try c.encodeIfPresent(waitlistPosition,      forKey: .waitlistPosition)
        try c.encodeIfPresent(feePaid,               forKey: .feePaid)
        try c.encodeIfPresent(stripePaymentIntentID, forKey: .stripePaymentIntentID)
        try c.encodeIfPresent(paymentMethod,         forKey: .paymentMethod)
        try c.encodeIfPresent(platformFeeCents,      forKey: .platformFeeCents)
        try c.encodeIfPresent(clubPayoutCents,       forKey: .clubPayoutCents)
        try c.encodeIfPresent(creditsAppliedCents,   forKey: .creditsAppliedCents)
    }
}

/// PATCH body used to confirm a pending_payment booking after successful Stripe payment.
private struct BookingConfirmPaymentBody: Encodable {
    let status: String
    let feePaid: Bool
    let stripePaymentIntentID: String?
    let paymentMethod: String
    let platformFeeCents: Int?
    let clubPayoutCents: Int?
    let creditsAppliedCents: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case feePaid = "fee_paid"
        case stripePaymentIntentID = "stripe_payment_intent_id"
        case paymentMethod = "payment_method"
        case platformFeeCents = "platform_fee_cents"
        case clubPayoutCents = "club_payout_cents"
        case creditsAppliedCents = "credits_applied_cents"
    }
}

private struct BookingAdminInsertBody: Encodable {
    let gameID: UUID
    let userID: UUID
    let status: String
    let waitlistPosition: Int?
    let paymentMethod: String = "admin"

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case userID = "user_id"
        case status
        case waitlistPosition = "waitlist_position"
        case paymentMethod = "payment_method"
    }
}

private struct BookingStatusUpdateBody: Encodable {
    let status: String
}

private struct GameStatusUpdateRow: Encodable {
    let status: String
}

private struct GameAttendanceRow: Decodable {
    let bookingID: UUID
    let paymentStatus: String?
    let attendanceStatus: String?

    enum CodingKeys: String, CodingKey {
        case bookingID = "booking_id"
        case paymentStatus = "payment_status"
        case attendanceStatus = "attendance_status"
    }
}

private struct GameAttendanceUpsertBody: Encodable {
    let gameID: UUID
    let bookingID: UUID
    let userID: UUID
    let checkedInAt: String
    let checkedInBy: UUID
    let attendanceStatus: String

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case bookingID = "booking_id"
        case userID = "user_id"
        case checkedInAt = "checked_in_at"
        case checkedInBy = "checked_in_by"
        case attendanceStatus = "attendance_status"
    }
}

private struct ClubOwnerUpdateRow: Encodable {
    let name: String
    let description: String?
    let imageURL: String
    let contactEmail: String?
    let contactPhone: String?
    let website: String?
    let managerName: String?
    let membersOnly: Bool
    let winCondition: String
    let defaultCourtCount: Int
    let venueName: String?
    let streetAddress: String?
    let suburb: String?
    let state: String?
    let postcode: String?
    let country: String?
    /// When true, latitude and longitude are encoded as explicit JSON `null`,
    /// invalidating stale coordinates after an address change.
    let clearCoordinates: Bool
    let heroImageKey: String?
    let customBannerURL: String?
    let codeOfConduct: String?
    let cancellationPolicy: String?
    let avatarBackgroundColor: String?

    enum CodingKeys: String, CodingKey {
        case name, description
        case imageURL = "image_url"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case website
        case managerName = "manager_name"
        case membersOnly = "members_only"
        case winCondition = "win_condition"
        case defaultCourtCount = "default_court_count"
        case venueName = "venue_name"
        case streetAddress = "street_address"
        case suburb, state, postcode, country
        case latitude, longitude
        case heroImageKey = "hero_image_key"
        case customBannerURL = "custom_banner_url"
        case codeOfConduct = "code_of_conduct"
        case cancellationPolicy = "cancellation_policy"
        case avatarBackgroundColor = "avatar_background_color"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,                  forKey: .name)
        try c.encode(description,           forKey: .description)
        try c.encode(imageURL,              forKey: .imageURL)
        try c.encode(contactEmail,          forKey: .contactEmail)
        try c.encode(contactPhone,          forKey: .contactPhone)
        try c.encode(website,               forKey: .website)
        try c.encode(managerName,           forKey: .managerName)
        try c.encode(membersOnly,           forKey: .membersOnly)
        try c.encode(winCondition,          forKey: .winCondition)
        try c.encode(defaultCourtCount,     forKey: .defaultCourtCount)
        try c.encode(venueName,             forKey: .venueName)
        try c.encode(streetAddress,         forKey: .streetAddress)
        try c.encode(suburb,                forKey: .suburb)
        try c.encode(state,                 forKey: .state)
        try c.encode(postcode,              forKey: .postcode)
        try c.encode(country,               forKey: .country)
        try c.encode(heroImageKey,          forKey: .heroImageKey)
        try c.encode(customBannerURL,       forKey: .customBannerURL)
        try c.encode(codeOfConduct,         forKey: .codeOfConduct)
        try c.encode(cancellationPolicy,    forKey: .cancellationPolicy)
        try c.encode(avatarBackgroundColor, forKey: .avatarBackgroundColor)
        if clearCoordinates {
            try c.encodeNil(forKey: .latitude)
            try c.encodeNil(forKey: .longitude)
        }
    }
}

private struct ClubInsertRow: Encodable {
    let name: String
    let description: String?
    let imageURL: String
    let contactEmail: String?
    let contactPhone: String?
    let website: String?
    let managerName: String?
    let membersOnly: Bool
    let createdBy: UUID
    let winCondition: String
    let venueName: String?
    let streetAddress: String?
    let suburb: String?
    let state: String?
    let postcode: String?
    let country: String?
    let heroImageKey: String?
    let customBannerURL: String?
    let avatarBackgroundColor: String?
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case imageURL = "image_url"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case website
        case managerName = "manager_name"
        case membersOnly = "members_only"
        case createdBy = "created_by"
        case winCondition = "win_condition"
        case venueName = "venue_name"
        case streetAddress = "street_address"
        case suburb
        case state
        case postcode
        case country
        case heroImageKey = "hero_image_key"
        case customBannerURL = "custom_banner_url"
        case avatarBackgroundColor = "avatar_background_color"
        case timezone
    }
}

private struct ClubCoordinatePatch: Encodable {
    let latitude: Double
    let longitude: Double
}

private struct ClubVenueNamePatch: Encodable {
    let venue_name: String
}

private struct ClubChatPushHookRequest: Encodable {
    let clubID: UUID
    let actorUserID: UUID
    let event: String
    let referenceID: UUID?
    let postAuthorID: UUID?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case actorUserID = "actor_user_id"
        case event
        case referenceID = "reference_id"
        case postAuthorID = "post_author_id"
        case content
    }
}

private struct BookingConfirmedPushRequest: Encodable {
    let gameID: UUID
    let bookingID: UUID
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case bookingID = "booking_id"
        case userID = "user_id"
    }
}

private struct FeedPostRow: Decodable {
    let id: UUID
    // user_id is ON DELETE SET NULL — null when the poster deleted their account
    let userID: UUID?
    // content is null for image-only posts in some DB configurations
    let content: String?
    let imageURLString: String?
    let imageURLStrings: [String]?
    let createdAtRaw: String?
    let updatedAtRaw: String?
    let clubID: UUID?
    let isAnnouncement: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case isAnnouncement = "is_announcement"
        case content
        case imageURLString = "image_url"
        case imageURLStrings = "image_urls"
        case createdAtRaw = "created_at"
        case updatedAtRaw = "updated_at"
        case clubID = "club_id"
    }

    var imageURLsResolved: [URL] {
        let source = (imageURLStrings?.isEmpty == false ? imageURLStrings : nil) ?? (imageURLString.map { [$0] } ?? [])
        var urls: [URL] = []
        var seen: Set<String> = []
        for raw in source {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted, let url = URL(string: trimmed) else { continue }
            urls.append(url)
        }
        return urls
    }
}

private struct FeedCommentRow: Decodable {
    let id: UUID
    let postID: UUID
    // user_id is ON DELETE SET NULL — null when the commenter deleted their account
    let userID: UUID?
    // content is null defensively — should always be present but guard against it
    let content: String?
    let createdAtRaw: String?
    let parentID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case postID = "post_id"
        case userID = "user_id"
        case content
        case createdAtRaw = "created_at"
        case parentID = "parent_id"
    }
}

private struct FeedReactionRow: Decodable {
    let id: UUID
    let postID: UUID
    let userID: UUID
    let reactionType: String
    let createdAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id
        case postID = "post_id"
        case userID = "user_id"
        case reactionType = "reaction_type"
        case createdAtRaw = "created_at"
    }
}

private struct FeedPostInsertBody: Encodable {
    let userID: UUID
    let content: String
    let imageURL: String?
    let clubID: UUID
    let imageURLs: [String]
    let isAnnouncement: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case content
        case imageURL = "image_url"
        case clubID = "club_id"
        case imageURLs = "image_urls"
        case isAnnouncement = "is_announcement"
    }
}

private struct FeedPostUpdateBody: Encodable {
    let content: String
    let imageURL: String
    let imageURLs: [String]

    enum CodingKeys: String, CodingKey {
        case content
        case imageURL = "image_url"
        case imageURLs = "image_urls"
    }
}

private struct FeedCommentInsertBody: Encodable {
    let postID: UUID
    let userID: UUID
    let content: String
    let parentID: UUID?

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case userID = "user_id"
        case content
        case parentID = "parent_id"
    }
}

private struct FeedReactionInsertBody: Encodable {
    let postID: UUID
    let userID: UUID
    let reactionType: String

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case userID = "user_id"
        case reactionType = "reaction_type"
    }
}

private struct FeedIDRow: Decodable {
    let id: UUID
}

private struct ClubMessageRow: Decodable {
    let id: UUID
    let clubID: UUID
    let senderID: UUID
    let parentID: UUID?
    let subject: String
    let body: String
    let read: Bool?
    let createdAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id
        case clubID = "club_id"
        case senderID = "sender_id"
        case parentID = "parent_id"
        case subject
        case body
        case read
        case createdAtRaw = "created_at"
    }
}

private struct ClubMessageInsertBody: Encodable {
    let clubID: UUID
    let senderID: UUID
    let parentID: UUID?
    let subject: String
    let body: String

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case senderID = "sender_id"
        case parentID = "parent_id"
        case subject
        case body
    }
}

private struct ClubNewsReportMessageBody: Codable {
    let reason: String
    let details: String
    let targetKind: String
    let targetID: String?
}

private enum ClubMembershipStateMapper {
    static func map(raw: String) -> ClubMembershipState {
        switch raw.lowercased() {
        case "pending":
            return .pending
        case "approved", "active", "member":
            return .approved
        case "rejected", "declined":
            return .rejected
        default:
            return .unknown(raw)
        }
    }
}

private enum BookingStateMapper {
    static func map(raw: String, waitlistPosition: Int?) -> BookingState {
        switch raw.lowercased() {
        case "confirmed":
            return .confirmed
        case "waitlisted", "waitlist":
            return .waitlisted(position: waitlistPosition)
        case "cancelled", "canceled":
            return .cancelled
        case "pending_payment":
            return .pendingPayment
        default:
            if waitlistPosition != nil {
                return .waitlisted(position: waitlistPosition)
            }
            return .unknown(raw)
        }
    }
}

private enum SupabaseDateParser {
    static func parse(_ raw: String) -> Date? {
        if let date = fractional.date(from: raw) { return date }
        return standard.date(from: raw)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private enum SupabaseDateWriter {
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}


// MARK: - Notification structs

private struct AppNotificationRow: Decodable {
    let id: UUID
    let userID: UUID
    let title: String
    let body: String
    let type: String
    let referenceID: UUID?
    let read: Bool
    let createdAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case body
        case type
        case referenceID = "reference_id"
        case read
        case createdAtRaw = "created_at"
    }
}

private struct NotifyRequest: Encodable {
    let userID: UUID
    let title: String
    let body: String
    let type: String
    let referenceID: UUID?
    let sendPush: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case title
        case body
        case type
        case referenceID = "reference_id"
        case sendPush = "send_push"
    }
}

private struct GameCancelledNotifyRequest: Encodable {
    let gameID: UUID
    let gameTitle: String
    let clubTimezone: String

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case gameTitle = "game_title"
        case clubTimezone = "club_timezone"
    }
}

private struct ClubAnnouncementNotifyRequest: Encodable {
    let clubID: UUID
    let postID: UUID
    let posterUserID: UUID
    let clubName: String
    let posterName: String
    let postBody: String

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case postID = "post_id"
        case posterUserID = "poster_user_id"
        case clubName = "club_name"
        case posterName = "poster_name"
        case postBody = "post_body"
    }
}

private struct GamePublishedNotifyRequest: Encodable {
    let gameID: UUID
    let gameTitle: String
    let gameDateTime: Date
    let clubID: UUID
    let clubName: String
    let createdByUserID: UUID
    let skillLevel: String?
    let clubTimezone: String

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case gameTitle = "game_title"
        case gameDateTime = "game_date_time"
        case clubID = "club_id"
        case clubName = "club_name"
        case createdByUserID = "created_by_user_id"
        case skillLevel = "skill_level"
        case clubTimezone = "club_timezone"
    }
}

private struct ClubAdminIDRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

// MARK: - Club Venue Rows

private struct ClubVenueRow: Codable {
    let id: UUID
    let clubID: UUID
    let venueName: String
    let streetAddress: String?
    let suburb: String?
    let state: String?
    let postcode: String?
    let country: String?
    let isPrimary: Bool
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case clubID = "club_id"
        case venueName = "venue_name"
        case streetAddress = "street_address"
        case suburb
        case state
        case postcode
        case country
        case isPrimary = "is_primary"
        case latitude
        case longitude
    }

    func toVenue() -> ClubVenue {
        ClubVenue(
            id: id, clubID: clubID, venueName: venueName,
            streetAddress: streetAddress, suburb: suburb,
            state: state, postcode: postcode, country: country,
            isPrimary: isPrimary, latitude: latitude, longitude: longitude
        )
    }
}

private struct ClubVenueInsertRow: Encodable {
    let clubID: UUID
    let venueName: String
    let streetAddress: String?
    let suburb: String?
    let state: String?
    let postcode: String?
    let country: String?
    let isPrimary: Bool
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case venueName = "venue_name"
        case streetAddress = "street_address"
        case suburb, state, postcode, country
        case isPrimary = "is_primary"
        case latitude, longitude
    }
}

private struct ClubVenueUpdateRow: Encodable {
    let venueName: String
    let streetAddress: String?
    let suburb: String?
    let state: String?
    let postcode: String?
    let country: String?
    let isPrimary: Bool
    /// When true, latitude and longitude are included in the PATCH body.
    /// newLatitude/newLongitude hold the geocoded value (or nil to clear stale coords).
    /// When false, lat/lng are omitted entirely — preserving existing DB values.
    let updateCoordinates: Bool
    let newLatitude: Double?
    let newLongitude: Double?

    enum CodingKeys: String, CodingKey {
        case venueName = "venue_name"
        case streetAddress = "street_address"
        case suburb, state, postcode, country
        case isPrimary = "is_primary"
        case latitude, longitude
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(venueName,     forKey: .venueName)
        try c.encode(streetAddress, forKey: .streetAddress)
        try c.encode(suburb,        forKey: .suburb)
        try c.encode(state,         forKey: .state)
        try c.encode(postcode,      forKey: .postcode)
        try c.encode(country,       forKey: .country)
        try c.encode(isPrimary,     forKey: .isPrimary)
        if updateCoordinates {
            try c.encode(newLatitude,  forKey: .latitude)
            try c.encode(newLongitude, forKey: .longitude)
        }
    }
}

// MARK: - Avatar Palette rows

/// Decodable row matching the avatar_palettes table.
/// Non-private so AppState and the protocol can reference the type.
struct AvatarPaletteRow: Decodable {
    let paletteKey:       String
    let paletteName:      String
    let category:         String
    let gradientStartHex: String
    let gradientEndHex:   String
    let isDefault:        Bool
    let displayOrder:     Int

    enum CodingKeys: String, CodingKey {
        case paletteKey       = "palette_key"
        case paletteName      = "palette_name"
        case category
        case gradientStartHex = "gradient_start_hex"
        case gradientEndHex   = "gradient_end_hex"
        case isDefault        = "is_default"
        case displayOrder     = "display_order"
    }

    func toEntry() -> AvatarGradients.Entry {
        AvatarGradients.Entry(key: paletteKey, name: paletteName, start: gradientStartHex, end: gradientEndHex)
    }
}

// MARK: - Stripe Connect rows

private struct ClubStripeAccountRow: Decodable {
    let id: UUID
    let clubID: UUID
    let stripeAccountID: String
    let onboardingComplete: Bool
    let payoutsEnabled: Bool
    let createdAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id
        case clubID = "club_id"
        case stripeAccountID = "stripe_account_id"
        case onboardingComplete = "onboarding_complete"
        case payoutsEnabled = "payouts_enabled"
        case createdAtRaw = "created_at"
    }
}
