import Foundation

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
    func fetchCheckedInBookingIDs(gameID: UUID) async throws -> Set<UUID>
    func fetchUserBookings(userID: UUID) async throws -> [BookingWithGame]
    func fetchProfile(userID: UUID) async throws -> UserProfile?
    func fetchMemberships(userID: UUID) async throws -> [ClubMembershipRecord]
    func fetchPendingClubJoinRequests(clubID: UUID) async throws -> [ClubJoinRequest]
    func fetchOwnerClubMembers(clubID: UUID, ownerUserID: UUID?) async throws -> [ClubOwnerMember]
    func fetchClubDirectoryMembers(clubID: UUID) async throws -> [ClubDirectoryMember]
    func fetchClubAdminRole(clubID: UUID, userID: UUID) async throws -> String?
    func fetchClubNewsPosts(clubID: UUID, currentUserID: UUID?) async throws -> [ClubNewsPost]
    func updateClubNewsPost(postID: UUID, content: String, imageURLs: [URL]) async throws
    func requestMembership(clubID: UUID, userID: UUID) async throws -> ClubMembershipState
    func removeMembership(clubID: UUID, userID: UUID) async throws
    func updateClubJoinRequest(requestID: UUID, status: String, respondedBy: UUID?) async throws
    func setClubAdminAccess(clubID: UUID, userID: UUID, makeAdmin: Bool) async throws
    func createClub(createdBy: UUID, draft: ClubOwnerEditDraft) async throws -> Club
    func createGame(for clubID: UUID, createdBy: UUID, draft: ClubOwnerGameDraft, recurrenceGroupID: UUID?) async throws -> Game
    func updateGame(gameID: UUID, draft: ClubOwnerGameDraft) async throws -> Game
    func deleteGame(gameID: UUID) async throws
    func updateClubOwnerFields(clubID: UUID, draft: ClubOwnerEditDraft) async throws -> Club
    func deleteClub(clubID: UUID) async throws
    func createBooking(gameID: UUID, userID: UUID) async throws -> BookingRecord
    func cancelBooking(bookingID: UUID) async throws -> BookingRecord
    func ownerUpdateBooking(bookingID: UUID, status: String, waitlistPosition: Int?) async throws -> BookingRecord
    func upsertAttendanceCheckIn(gameID: UUID, bookingID: UUID, userID: UUID, checkedInBy: UUID) async throws
    func deleteAttendanceCheckIn(bookingID: UUID) async throws
    func uploadClubNewsImage(_ image: FeedImageUploadPayload, userID: UUID, clubID: UUID) async throws -> URL
    func deleteClubNewsImages(_ imageURLs: [URL]) async throws
    func createClubNewsPost(clubID: UUID, userID: UUID, content: String, imageURLs: [URL], isAnnouncement: Bool) async throws
    func toggleClubNewsLike(postID: UUID, userID: UUID) async throws
    func createClubNewsComment(postID: UUID, userID: UUID, content: String, parentCommentID: UUID?) async throws
    func deleteClubNewsComment(commentID: UUID) async throws
    func deleteClubNewsPost(postID: UUID) async throws
    func createClubNewsModerationReport(clubID: UUID, senderUserID: UUID, targetKind: ClubNewsModerationReport.TargetKind, targetID: UUID?, reason: String, details: String) async throws
    func fetchClubNewsModerationReports(clubID: UUID) async throws -> [ClubNewsModerationReport]
    func resolveClubNewsModerationReport(reportID: UUID) async throws
    func triggerClubChatPushHook(clubID: UUID, actorUserID: UUID, event: String, referenceID: UUID?) async throws
    func triggerBookingConfirmedPush(gameID: UUID, bookingID: UUID, userID: UUID) async throws
    func triggerNotify(userID: UUID, title: String, body: String, type: String, referenceID: UUID?, sendPush: Bool) async throws
    func triggerGameCancelledNotify(gameID: UUID, gameTitle: String) async throws
    func triggerClubAnnouncementNotify(clubID: UUID, postID: UUID, posterUserID: UUID, clubName: String, posterName: String, postBody: String) async throws
    func fetchClubAdminUserIDs(clubID: UUID) async throws -> [UUID]
    func fetchNotifications(userID: UUID) async throws -> [AppNotification]
    func markNotificationRead(id: UUID) async throws
    func markAllNotificationsRead(userID: UUID) async throws
    func updateProfilePushToken(userID: UUID, pushToken: String?) async throws
    func upsertProfile(_ profile: UserProfile) async throws -> UserProfile
    func patchProfile(_ profile: UserProfile) async throws -> UserProfile
    func updatePassword(_ newPassword: String) async throws
}

enum SupabaseServiceError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case authenticationRequired
    case duplicateMembership
    case notFound
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

        let clubRows: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "select", value: "id,name,description,location,image_url,contact_email,website,manager_name,members_only,created_by")
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
                .init(name: "select", value: "id,name,description,location,image_url,contact_email,website,manager_name,members_only,created_by"),
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
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,max_spots,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id"),
                .init(name: "club_id", value: "eq.\(clubID.uuidString)"),
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

    func fetchGamesInSeries(recurrenceGroupID: UUID) async throws -> [Game] {
        guard SupabaseConfig.isConfigured else { return [] }

        let gameRows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,max_spots,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id"),
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
        let authToken = resolvedAccessToken()

        let bookingRows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id"),
                .init(name: "user_id", value: "eq.\(userID.uuidString)"),
                .init(name: "order", value: "created_at.desc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        let gameIDs = Array(Set(bookingRows.map(\.gameID)))
        var gamesByID: [UUID: Game] = [:]

        if !gameIDs.isEmpty {
            if let gameRows: [GameRow] = try? await send(
                path: "games",
                queryItems: [
                    .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,max_spots,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id"),
                    .init(name: "id", value: "in.(\(gameIDs.map(\.uuidString).joined(separator: ",")))")
                ],
                method: "GET",
                body: nil,
                authBearerToken: authToken
            ) {
                gamesByID = Dictionary(uniqueKeysWithValues: gameRows.map { ($0.id, $0.toGame(confirmedCount: nil, waitlistCount: nil)) })
            }
        }

        return bookingRows.map { row in
            BookingWithGame(
                booking: row.toBookingRecord(),
                game: gamesByID[row.gameID]
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
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id"),
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
                .init(name: "select", value: "id,full_name,email,phone,emergency_contact_name,emergency_contact_phone"),
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
                    userEmail: profile?.email
                )
            }
            .sorted { lhs, rhs in
                self.attendeeComparator(lhs: lhs, rhs: rhs)
            }
    }

    func fetchCheckedInBookingIDs(gameID: UUID) async throws -> Set<UUID> {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [GameAttendanceRow] = try await send(
            path: "game_attendance",
            queryItems: [
                .init(name: "select", value: "booking_id"),
                .init(name: "game_id", value: "eq.\(gameID.uuidString)")
            ],
            method: "GET",
            body: nil,
            authBearerToken: authToken
        )

        return Set(rows.map(\.bookingID))
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
                .init(name: "select", value: "id,club_id,user_id,status,requested_at"),
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
                .init(name: "select", value: "id,full_name,email"),
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
                isOwner: ownerUserID == row.userID || adminRow?.role?.lowercased() == "owner",
                adminRole: adminRow?.role
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
                ClubDirectoryMember(id: $0.id, name: $0.name, duprRating: $0.rating)
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
                .init(name: "select", value: "id,full_name,dupr_rating"),
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
            return ClubDirectoryMember(id: row.userID, name: name, duprRating: profile.duprRating)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchClubAdminRole(clubID: UUID, userID: UUID) async throws -> String? {
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
        let commentRows: [FeedCommentRow] = (try? await send(
            path: "feed_comments",
            queryItems: [
                .init(name: "select", value: "id,post_id,user_id,content,created_at,parent_id"),
                .init(name: "post_id", value: "in.(\(postIDList))"),
                .init(name: "order", value: "created_at.asc")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []
        let reactionRows: [FeedReactionRow] = (try? await send(
            path: "feed_reactions",
            queryItems: [
                .init(name: "select", value: "id,post_id,user_id,reaction_type,created_at"),
                .init(name: "post_id", value: "in.(\(postIDList))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []

        let userIDs = Set(postRows.map(\.userID)).union(commentRows.map(\.userID))
        let profileRows: [OwnerProfileLiteRow] = userIDs.isEmpty ? [] : (try? await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,full_name,email"),
                .init(name: "id", value: "in.(\(userIDs.map(\.uuidString).joined(separator: ",")))")
            ],
            method: "GET",
            body: nil,
            authBearerToken: resolvedAccessToken()
        )) ?? []
        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })

        let commentsByPost = Dictionary(grouping: commentRows, by: \.postID)
        let reactionsByPost = Dictionary(grouping: reactionRows, by: \.postID)

        return postRows.map { row in
            let profile = profilesByID[row.userID]
            let authorName = Self.displayName(profile?.fullName)
            let comments = (commentsByPost[row.id] ?? []).map { commentRow in
                let commentProfile = profilesByID[commentRow.userID]
                return ClubNewsComment(
                    id: commentRow.id,
                    postID: commentRow.postID,
                    userID: commentRow.userID,
                    authorName: Self.displayName(commentProfile?.fullName),
                    content: commentRow.content,
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
                userID: row.userID,
                authorName: authorName,
                content: row.content,
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

    func createClubNewsPost(clubID: UUID, userID: UUID, content: String, imageURLs: [URL], isAnnouncement: Bool) async throws {
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
        let _: [FeedIDRow] = try await send(
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

    func createClubNewsComment(postID: UUID, userID: UUID, content: String, parentCommentID: UUID?) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let body = FeedCommentInsertBody(postID: postID, userID: userID, content: content, parentID: parentCommentID)
        let _: [FeedCommentRow] = try await send(
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
        let _: [ClubMessageRow] = try await send(
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

    func triggerClubChatPushHook(clubID: UUID, actorUserID: UUID, event: String, referenceID: UUID?) async throws {
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
            referenceID: referenceID
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

    func fetchProfile(userID: UUID) async throws -> UserProfile? {
        guard SupabaseConfig.isConfigured else { return nil }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let rows: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,email,full_name,phone,date_of_birth,emergency_contact_name,emergency_contact_phone,dupr_rating"),
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
            fullName: row.fullName ?? "",
            email: row.email,
            phone: row.phone,
            dateOfBirth: row.dateOfBirth.flatMap { Self.isoDateFormatter.date(from: $0) },
            emergencyContactName: row.emergencyContactName,
            emergencyContactPhone: row.emergencyContactPhone,
            duprRating: row.duprRating,
            favoriteClubName: nil,
            skillLevel: .beginner
        )
    }

    func requestMembership(clubID: UUID, userID: UUID) async throws -> ClubMembershipState {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ClubMembershipInsertBody(clubID: clubID, userID: userID)

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
            let body = ClubAdminUpsertBody(clubID: clubID, userID: userID, role: "admin")
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

    func createClub(createdBy: UUID, draft: ClubOwnerEditDraft) async throws -> Club {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = ClubInsertRow(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nilIfEmpty(draft.description),
            location: nilIfEmpty(draft.location),
            imageURL: draft.imageURLStringForSave ?? "",
            contactEmail: nilIfEmpty(draft.contactEmail),
            website: nilIfEmpty(draft.website),
            managerName: nilIfEmpty(draft.managerName),
            membersOnly: draft.membersOnly,
            createdBy: createdBy
        )

        let createdRows: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "select", value: "id,name,description,location,image_url,contact_email,website,manager_name,members_only,created_by")
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

        let ownerAdminPayload = ClubAdminUpsertBody(clubID: created.id, userID: createdBy, role: "owner")
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
            feeAmount: feeAmount,
            feeCurrency: nilIfEmpty(draft.feeCurrency) ?? "USD",
            location: nilIfEmpty(draft.location),
            notes: nilIfEmpty(draft.notes),
            createdBy: createdBy,
            requiresDUPR: draft.requiresDUPR,
            skillLevel: draft.skillLevelRaw,
            gameFormat: draft.gameFormatRaw,
            recurrenceGroupID: recurrenceGroupID
        )

        let rows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,max_spots,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id")
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
            maxSpots: max(draft.maxSpots, 1),
            feeAmount: feeAmount,
            feeCurrency: "USD",
            location: normalizedGameTextField(draft.location),
            notes: normalizedGameTextField(draft.notes),
            requiresDUPR: draft.requiresDUPR
        )

        let rows: [GameRow] = try await send(
            path: "games",
            queryItems: [
                .init(name: "id", value: "eq.\(gameID.uuidString)"),
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,max_spots,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id")
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
                .init(name: "select", value: "id,club_id,title,description,date_time,duration_minutes,skill_level,game_format,max_spots,fee_amount,fee_currency,location,status,notes,requires_dupr,recurrence_group_id")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation"
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
            location: nilIfEmpty(draft.location),
            imageURL: draft.imageURLStringForSave ?? "",
            contactEmail: nilIfEmpty(draft.contactEmail),
            website: nilIfEmpty(draft.website),
            managerName: nilIfEmpty(draft.managerName),
            membersOnly: draft.membersOnly
        )

        let _: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id,name,description,location,image_url,contact_email,website,manager_name,members_only,created_by")
            ],
            method: "PATCH",
            body: try JSONEncoder().encode(payload),
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation",
                "Content-Type": "application/json"
            ]
        )

        // Reuse existing detail loader to rebuild derived fields/member count consistently.
        return try await fetchClubDetail(id: clubID)
    }

    func deleteClub(clubID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let _: [ClubRow] = try await send(
            path: "clubs",
            queryItems: [
                .init(name: "id", value: "eq.\(clubID.uuidString)"),
                .init(name: "select", value: "id,name,description,location,image_url,contact_email,website,manager_name,members_only,created_by")
            ],
            method: "DELETE",
            body: nil,
            authBearerToken: authToken,
            extraHeaders: [
                "Prefer": "return=representation"
            ]
        )
    }

    func createBooking(gameID: UUID, userID: UUID) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = BookingInsertBody(gameID: gameID, userID: userID)

        do {
            let rows: [BookingRow] = try await send(
                path: "bookings",
                queryItems: [
                    .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id")
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
            return row.toBookingRecord()
        } catch let error as SupabaseServiceError {
            if case let .httpStatus(code, _) = error, code == 409 {
                throw SupabaseServiceError.duplicateMembership
            }
            throw error
        }
    }

    func removeMembership(clubID: UUID, userID: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

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
    }

    func cancelBooking(bookingID: UUID) async throws -> BookingRecord {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = BookingStatusUpdateBody(status: "cancelled")

        let rows: [BookingRow] = try await send(
            path: "bookings",
            queryItems: [
                .init(name: "id", value: "eq.\(bookingID.uuidString)"),
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id")
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
                .init(name: "select", value: "id,game_id,user_id,status,waitlist_position,created_at,fee_paid,paid_at,stripe_payment_intent_id")
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

    func upsertAttendanceCheckIn(gameID: UUID, bookingID: UUID, userID: UUID, checkedInBy: UUID) async throws {
        guard SupabaseConfig.isConfigured else { throw SupabaseServiceError.missingConfiguration }
        guard let authToken = resolvedAccessToken(), !authToken.isEmpty else {
            throw SupabaseServiceError.authenticationRequired
        }

        let payload = GameAttendanceUpsertBody(
            gameID: gameID,
            bookingID: bookingID,
            userID: userID,
            checkedInAt: SupabaseDateWriter.string(from: Date()),
            checkedInBy: checkedInBy
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
            fullName: profile.fullName,
            phone: profile.phone,
            dateOfBirth: profile.dateOfBirth.map { Self.isoDateFormatter.string(from: $0) },
            emergencyContactName: profile.emergencyContactName,
            emergencyContactPhone: profile.emergencyContactPhone,
            duprRating: profile.duprRating
        )

        let rows: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "select", value: "id,email,full_name,phone,date_of_birth,emergency_contact_name,emergency_contact_phone,dupr_rating"),
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
            fullName: row.fullName ?? profile.fullName,
            email: row.email,
            phone: row.phone,
            dateOfBirth: row.dateOfBirth.flatMap { Self.isoDateFormatter.date(from: $0) },
            emergencyContactName: row.emergencyContactName,
            emergencyContactPhone: row.emergencyContactPhone,
            duprRating: row.duprRating,
            favoriteClubName: profile.favoriteClubName,
            skillLevel: profile.skillLevel
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
            fullName: profile.fullName,
            phone: profile.phone,
            dateOfBirth: profile.dateOfBirth.map { Self.isoDateFormatter.string(from: $0) },
            emergencyContactName: profile.emergencyContactName,
            emergencyContactPhone: profile.emergencyContactPhone,
            duprRating: profile.duprRating
        )

        let rows: [ProfileRow] = try await send(
            path: "profiles",
            queryItems: [
                .init(name: "id", value: "eq.\(profile.id.uuidString)"),
                .init(name: "select", value: "id,email,full_name,phone,date_of_birth,emergency_contact_name,emergency_contact_phone,dupr_rating")
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
            fullName: row.fullName ?? profile.fullName,
            email: row.email,
            phone: row.phone,
            dateOfBirth: row.dateOfBirth.flatMap { Self.isoDateFormatter.date(from: $0) },
            emergencyContactName: row.emergencyContactName,
            emergencyContactPhone: row.emergencyContactPhone,
            duprRating: row.duprRating,
            favoriteClubName: profile.favoriteClubName,
            skillLevel: profile.skillLevel
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

    func triggerGameCancelledNotify(gameID: UUID, gameTitle: String) async throws {
        guard SupabaseConfig.isConfigured else { return }
        let request = GameCancelledNotifyRequest(gameID: gameID, gameTitle: gameTitle)
        try await invokeEdgeFunction(name: "game-cancelled-notify", body: try JSONEncoder().encode(request))
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
        let url = baseURL.appendingPathComponent("functions/v1/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? "(no body)"
            print("[EdgeFunction] \(name) failed \(http.statusCode): \(text)")
        }
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
            case .none, .cancelled, .unknown:
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
        case .waitlisted:
            return 1
        case .unknown:
            return 2
        case .cancelled:
            return 3
        case .none:
            return 4
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
    let location: String?
    let imageURLString: String?
    let contactEmail: String?
    let website: String?
    let managerName: String?
    let membersOnly: Bool
    let createdByUserID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case location
        case imageURLString = "image_url"
        case contactEmail = "contact_email"
        case website
        case managerName = "manager_name"
        case membersOnly = "members_only"
        case createdByUserID = "created_by"
    }

    func toClub(memberCount: Int, seedMembers: [ClubMember], seedTags: [String]) -> Club {
        let safeName = Self.sanitizedText(name, maxLength: 120) ?? "Club"
        let safeDescription = Self.sanitizedText(description, maxLength: 2000) ?? "No club description yet."
        let safeContactEmail = Self.sanitizedText(contactEmail, maxLength: 320) ?? "No contact email listed"
        let safeLocation = Self.sanitizedText(location, maxLength: 260) ?? "No location listed"
        let safeWebsite = Self.sanitizedText(website, maxLength: 260)
        let safeManagerName = Self.sanitizedText(managerName, maxLength: 160)
        let safeImageURL = Self.sanitizedURL(imageURLString)

        let parsed = Self.parseLocation(safeLocation)
        return Club(
            id: id,
            name: safeName,
            city: parsed.city,
            region: parsed.region,
            memberCount: memberCount,
            description: safeDescription,
            contactEmail: safeContactEmail,
            address: safeLocation,
            imageSystemName: "building.2.crop.circle.fill",
            imageURL: safeImageURL,
            website: safeWebsite,
            managerName: safeManagerName,
            membersOnly: membersOnly,
            tags: seedTags.isEmpty ? Self.defaultTags(membersOnly: membersOnly) : seedTags,
            topMembers: seedMembers,
            createdByUserID: createdByUserID
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
        let isAllowed = scheme == "http" || scheme == "https" || scheme == "bookadink-avatar"
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

    enum CodingKeys: String, CodingKey {
        case id
        case clubID = "club_id"
        case userID = "user_id"
        case status
        case requestedAtRaw = "requested_at"
    }
}

private struct OwnerProfileLiteRow: Decodable {
    let id: UUID
    let fullName: String?
    let email: String?
    let phone: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case email
        case phone
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
    }
}

private struct ClubDirectoryProfileRow: Decodable {
    let id: UUID
    let fullName: String?
    let duprRating: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case duprRating = "dupr_rating"
    }
}

private struct ClubAdminRow: Decodable {
    let clubID: UUID
    let userID: UUID
    let role: String?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case role
    }
}

private struct ClubMembershipInsertBody: Encodable {
    let clubID: UUID
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
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
    let role: String

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case userID = "user_id"
        case role
    }
}

private struct ProfileUpsertRow: Encodable {
    let id: UUID
    let email: String
    let fullName: String
    let phone: String?
    let dateOfBirth: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?
    let duprRating: Double?

    enum CodingKeys: String, CodingKey {
        case id, email
        case fullName = "full_name"
        case phone
        case dateOfBirth = "date_of_birth"
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
        case duprRating = "dupr_rating"
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let email: String
    let fullName: String?
    let phone: String?
    let dateOfBirth: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?
    let duprRating: Double?

    enum CodingKeys: String, CodingKey {
        case id, email
        case fullName = "full_name"
        case phone
        case dateOfBirth = "date_of_birth"
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
        case duprRating = "dupr_rating"
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
    let maxSpots: Int
    let feeAmount: Double?
    let feeCurrency: String?
    let location: String?
    let status: String
    let notes: String?
    let requiresDUPR: Bool?

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
        case maxSpots = "max_spots"
        case feeAmount = "fee_amount"
        case feeCurrency = "fee_currency"
        case location
        case status
        case notes
        case requiresDUPR = "requires_dupr"
    }

    func toGame(confirmedCount: Int?, waitlistCount: Int?) -> Game {
        Game(
            id: id,
            clubID: clubID,
            recurrenceGroupID: recurrenceGroupID,
            title: title,
            description: description,
            dateTime: SupabaseDateParser.parse(dateTimeRaw) ?? Date(),
            durationMinutes: durationMinutes,
            skillLevel: skillLevel,
            gameFormat: gameFormat,
            maxSpots: maxSpots,
            feeAmount: feeAmount,
            feeCurrency: feeCurrency,
            location: location,
            status: status,
            notes: notes,
            requiresDUPR: requiresDUPR ?? false,
            confirmedCount: confirmedCount,
            waitlistCount: waitlistCount
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
    let feeAmount: Double?
    let feeCurrency: String?
    let location: String?
    let notes: String?
    let createdBy: UUID
    let requiresDUPR: Bool
    let skillLevel: String
    let gameFormat: String
    let recurrenceGroupID: UUID?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case title
        case description
        case dateTime = "date_time"
        case durationMinutes = "duration_minutes"
        case maxSpots = "max_spots"
        case feeAmount = "fee_amount"
        case feeCurrency = "fee_currency"
        case location
        case notes
        case createdBy = "created_by"
        case requiresDUPR = "requires_dupr"
        case skillLevel = "skill_level"
        case gameFormat = "game_format"
        case recurrenceGroupID = "recurrence_group_id"
    }
}

private struct GameOwnerUpdateRow: Encodable {
    let title: String
    let description: String?
    let dateTime: String
    let durationMinutes: Int
    let skillLevel: String
    let gameFormat: String
    let maxSpots: Int
    let feeAmount: Double?
    let feeCurrency: String
    let location: String?
    let notes: String?
    let requiresDUPR: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case dateTime = "date_time"
        case durationMinutes = "duration_minutes"
        case skillLevel = "skill_level"
        case gameFormat = "game_format"
        case maxSpots = "max_spots"
        case feeAmount = "fee_amount"
        case feeCurrency = "fee_currency"
        case location
        case notes
        case requiresDUPR = "requires_dupr"
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
            stripePaymentIntentID: stripePaymentIntentID
        )
    }
}

private struct BookingInsertBody: Encodable {
    let gameID: UUID
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case userID = "user_id"
    }
}

private struct BookingStatusUpdateBody: Encodable {
    let status: String
}

private struct GameAttendanceRow: Decodable {
    let bookingID: UUID

    enum CodingKeys: String, CodingKey {
        case bookingID = "booking_id"
    }
}

private struct GameAttendanceUpsertBody: Encodable {
    let gameID: UUID
    let bookingID: UUID
    let userID: UUID
    let checkedInAt: String
    let checkedInBy: UUID

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case bookingID = "booking_id"
        case userID = "user_id"
        case checkedInAt = "checked_in_at"
        case checkedInBy = "checked_in_by"
    }
}

private struct ClubOwnerUpdateRow: Encodable {
    let name: String
    let description: String?
    let location: String?
    let imageURL: String
    let contactEmail: String?
    let website: String?
    let managerName: String?
    let membersOnly: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case location
        case imageURL = "image_url"
        case contactEmail = "contact_email"
        case website
        case managerName = "manager_name"
        case membersOnly = "members_only"
    }
}

private struct ClubInsertRow: Encodable {
    let name: String
    let description: String?
    let location: String?
    let imageURL: String
    let contactEmail: String?
    let website: String?
    let managerName: String?
    let membersOnly: Bool
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case location
        case imageURL = "image_url"
        case contactEmail = "contact_email"
        case website
        case managerName = "manager_name"
        case membersOnly = "members_only"
        case createdBy = "created_by"
    }
}

private struct ClubChatPushHookRequest: Encodable {
    let clubID: UUID
    let actorUserID: UUID
    let event: String
    let referenceID: UUID?

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id"
        case actorUserID = "actor_user_id"
        case event
        case referenceID = "reference_id"
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
    let userID: UUID
    let content: String
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
    let userID: UUID
    let content: String
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

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case gameTitle = "game_title"
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

private struct ClubAdminIDRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}
