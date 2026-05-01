import Foundation
import SwiftUI

struct UserProfile: Identifiable {
    let id: UUID
    var firstName: String?
    var lastName: String?
    var fullName: String
    var email: String
    var phone: String?
    var dateOfBirth: Date?
    var emergencyContactName: String?
    var emergencyContactPhone: String?
    var duprRating: Double?
    var duprID: String? = nil
    var favoriteClubName: String?
    var skillLevel: SkillLevel
    var avatarColorKey: String? = nil   // neon accent palette key (e.g. "electric_blue")
}

struct AuthSessionInfo {
    let accessToken: String
    let refreshToken: String?
    let userID: UUID
    let email: String?
}

enum AuthFlowResult {
    case signedIn(AuthSessionInfo)
    case requiresEmailConfirmation(email: String)
}

enum SkillLevel: String, CaseIterable, Identifiable {
    case all          = "all"
    case beginner     = "beginner"
    case intermediate = "intermediate"
    case advanced     = "advanced"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:          return "All Levels"
        case .beginner:     return "Beginner"
        case .intermediate: return "Intermediate"
        case .advanced:     return "Advanced"
        }
    }
}

/// Returns a DUPR-derived skill label. Falls back to `fallback` when no rating is available.
func duprSkillLabel(for rating: Double?, fallback: String = "Unrated") -> String {
    guard let r = rating else { return fallback }
    switch r {
    case ..<3.0:    return "Beginner"
    case 3.0..<3.5: return "Intermediate"
    case 3.5..<4.0: return "High Intermediate"
    case 4.0..<5.0: return "Advanced"
    default:        return "Elite / Professional"
    }
}

enum ClubAdminRole: String, Codable, Hashable {
    case owner = "owner"
    case admin  = "admin"

    var label: String {
        switch self {
        case .owner: return "Owner"
        case .admin: return "Admin"
        }
    }
}

enum ClubMembershipState: Hashable {
    case none
    case pending
    case approved
    case rejected
    case unknown(String)

    var isJoinActionEnabled: Bool {
        switch self {
        case .none, .rejected:
            return true
        case .pending, .approved, .unknown:
            return false
        }
    }

    var actionTitle: String {
        switch self {
        case .none:
            return "Join Club"
        case .pending:
            return "Request Sent"
        case .approved:
            return "Joined"
        case .rejected:
            return "Request Again"
        case .unknown:
            return "Member"
        }
    }
}

struct ClubMembershipRecord: Identifiable, Hashable {
    var id: UUID { clubID }
    let clubID: UUID
    let userID: UUID
    let status: ClubMembershipState
}

struct ClubJoinRequest: Identifiable, Hashable {
    let id: UUID
    let clubID: UUID
    let userID: UUID
    let status: ClubMembershipState
    let requestedAt: Date?
    let memberName: String
    let memberEmail: String?
}

struct ClubOwnerMember: Identifiable, Hashable {
    var id: UUID { userID }
    let membershipRecordID: UUID
    let userID: UUID
    let clubID: UUID
    let membershipStatus: ClubMembershipState
    let memberName: String
    let memberEmail: String?
    let memberPhone: String?
    let emergencyContactName: String?
    let emergencyContactPhone: String?
    let isAdmin: Bool
    let isOwner: Bool
    let adminRole: ClubAdminRole?
    let conductAcceptedAt: Date?
    let cancellationPolicyAcceptedAt: Date?
    let duprRating: Double?
    let duprUpdatedAt: Date?
    let duprUpdatedByName: String?
    // Avatar colour is identity data. Do not derive per-view.
    let avatarColorKey: String?
}

struct ClubDirectoryMember: Identifiable, Hashable {
    let id: UUID
    let name: String
    let duprRating: Double?
    // Avatar colour is identity data. Do not derive per-view.
    let avatarColorKey: String?
}

// MARK: - Club Venue

struct ClubVenue: Identifiable, Hashable {
    let id: UUID
    let clubID: UUID
    var venueName: String
    var streetAddress: String?
    var suburb: String?
    var state: String?
    var postcode: String?
    var country: String?
    var isPrimary: Bool
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// True when both lat and lng are present — venue can be placed on a map.
    var hasResolvedCoordinates: Bool { latitude != nil && longitude != nil }

    /// "Venue Name" — used as line 1
    var addressLine1: String { venueName }

    /// "Suburb, State" — used as line 2
    var addressLine2: String? {
        let parts = [suburb, state].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Single-line label for pickers: "Venue Name · Suburb, State"
    var pickerLabel: String {
        if let line2 = addressLine2 { return "\(venueName) · \(line2)" }
        return venueName
    }
}

struct ClubVenueDraft {
    var venueName: String = ""
    var streetAddress: String = ""
    var suburb: String = ""
    var state: String = ""
    var postcode: String = ""
    var country: String = "Australia"
    var isPrimary: Bool = false

    /// Coordinates pre-resolved via place search (Stage 3).
    /// When set, the save path skips CLGeocoder and uses these directly.
    /// Not included in _addressKey — does not affect locationChanged detection.
    var resolvedLatitude: Double? = nil
    var resolvedLongitude: Double? = nil

    // Captures the address fingerprint at init time (nil for new venues).
    // Used to detect when any location field changes so stale coordinates
    // can be invalidated before the record is saved.
    private let _originalAddressKey: String?

    /// True when any location field differs from the value at init time.
    /// Always false for new venues (no existing coordinates to invalidate).
    var locationChanged: Bool {
        guard let original = _originalAddressKey else { return false }
        return _addressKey != original
    }

    private var _addressKey: String {
        [venueName, streetAddress, suburb, state, postcode, country].joined(separator: "|")
    }

    init() {
        _originalAddressKey = nil
    }

    init(venue: ClubVenue) {
        venueName = venue.venueName
        streetAddress = venue.streetAddress ?? ""
        suburb = venue.suburb ?? ""
        state = venue.state ?? ""
        postcode = venue.postcode ?? ""
        country = venue.country ?? "Australia"
        isPrimary = venue.isPrimary
        _originalAddressKey = [venue.venueName, venue.streetAddress ?? "", venue.suburb ?? "",
                               venue.state ?? "", venue.postcode ?? "",
                               venue.country ?? "Australia"].joined(separator: "|")
    }

    /// True when the venue has a usable name — minimum bar for the form to submit.
    var isValid: Bool { !venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// True when at least one location field has content — enough to attempt geocoding.
    var hasUsableAddress: Bool {
        [streetAddress, suburb, state, postcode]
            .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

// MARK: - Win Condition

enum WinCondition: String, Codable, CaseIterable, Identifiable {
    case firstTo11      = "first_to_11"
    case firstTo11By2   = "first_to_11_by2"
    case firstTo15      = "first_to_15"
    case firstTo15By2   = "first_to_15_by2"
    case firstTo21      = "first_to_21"
    case firstTo21By2   = "first_to_21_by2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .firstTo11:    return "First to 11"
        case .firstTo11By2: return "First to 11 (win by 2)"
        case .firstTo15:    return "First to 15"
        case .firstTo15By2: return "First to 15 (win by 2)"
        case .firstTo21:    return "First to 21"
        case .firstTo21By2: return "First to 21 (win by 2)"
        }
    }

    var targetScore: Int {
        switch self {
        case .firstTo11, .firstTo11By2: return 11
        case .firstTo15, .firstTo15By2: return 15
        case .firstTo21, .firstTo21By2: return 21
        }
    }

    var requiresWinBy2: Bool {
        switch self {
        case .firstTo11By2, .firstTo15By2, .firstTo21By2: return true
        default: return false
        }
    }

    static var `default`: WinCondition { .firstTo11By2 }

    init(raw: String?) {
        self = WinCondition(rawValue: raw ?? "") ?? .firstTo11By2
    }
}

// MARK: - Court Result

enum TeamSide: String, Codable {
    case teamA, teamB
}

struct CourtResult: Identifiable {
    let id: UUID
    let roundNumber: Int
    let courtNumber: Int
    let courtID: UUID
    let teamA: [GameAttendee]
    let teamB: [GameAttendee]
    var teamAScore: Int = 0
    var teamBScore: Int = 0
    var winner: TeamSide? = nil
    var isConfirmed: Bool = false

    func autoWinner(for condition: WinCondition) -> TeamSide? {
        let a = teamAScore, b = teamBScore
        let target = condition.targetScore
        let winBy2 = condition.requiresWinBy2
        if a >= target && (!winBy2 || a - b >= 2) && a > b { return .teamA }
        if b >= target && (!winBy2 || b - a >= 2) && b > a { return .teamB }
        return nil
    }

    func scoreMatchesCondition(_ condition: WinCondition) -> Bool {
        autoWinner(for: condition) != nil
    }
}

// MARK: - Club Banner Preset

enum ClubBannerPreset: String, CaseIterable {
    case courts    // sport/court aesthetic
    case community // social/community feel

    var gradient: LinearGradient {
        switch self {
        case .courts:
            return LinearGradient(
                colors: [Color(hex: "0F4C5C"), Color(hex: "1A2F4A")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .community:
            return LinearGradient(
                colors: [Color(hex: "C4622D"), Color(hex: "1A2544")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    var patternSymbol: String {
        switch self {
        case .courts:    return "sportscourt.fill"
        case .community: return "person.3.fill"
        }
    }
}

struct Club: Identifiable, Hashable {
    let id: UUID
    var name: String
    // LEGACY: city/region/address are derived from structured fields at decode time.
    // Do not use these as authoritative sources — prefer primary ClubVenue for location display.
    var city: String
    var region: String
    var memberCount: Int
    var description: String
    var contactEmail: String
    var contactPhone: String?
    var address: String
    var imageSystemName: String
    var imageURL: URL?
    var website: String?
    var managerName: String?
    var membersOnly: Bool
    var tags: [String]
    var topMembers: [ClubMember]
    var createdByUserID: UUID? = nil
    var winCondition: WinCondition = .firstTo11By2
    var bannerPreset: ClubBannerPreset = .courts
    var defaultCourtCount: Int = 1
    // LEGACY: club-level address fields are soft-deprecated as of Stage 4.
    // Primary ClubVenue is now the location source of truth.
    // These remain as a fallback cache for clubs without venue rows.
    var venueName: String? = nil
    var streetAddress: String? = nil
    var suburb: String? = nil
    var state: String? = nil
    var postcode: String? = nil
    var country: String? = nil
    // LEGACY: club-level coordinates. Prefer LocationService.location(for:venues:).
    var latitude: Double? = nil
    var longitude: Double? = nil
    var heroImageKey: String? = nil
    var customBannerURL: URL? = nil
    var codeOfConduct: String? = nil
    var cancellationPolicy: String? = nil
    /// Denormalised from `club_stripe_accounts`. Non-nil when the club has completed Stripe Connect onboarding.
    var stripeConnectID: String? = nil
    /// Hex colour string (e.g. "#2E7D5B") for the initials-based avatar background.
    /// nil means use the default deterministic colour derived from the club name.
    var avatarBackgroundColor: String? = nil
    /// IANA timezone identifier for the club's venue (e.g. "Australia/Perth").
    /// Set from the creator's device timezone at club creation time.
    var timezone: String = "Australia/Perth"

    // LEGACY display helpers — built from club-level fields.
    // Prefer primary ClubVenue address for display where venues are loaded.
    var locationDisplay: String {
        let parts = [city, region].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return address
    }

    /// Multi-line display for the Info / Contact section
    var formattedAddressFull: String {
        // Line 3: "Suburb, STATE postcode" e.g. "Singleton, WA 6175"
        var line3Parts: [String] = []
        if let sub = suburb, !sub.isEmpty { line3Parts.append(sub) }
        if let st = state, !st.isEmpty { line3Parts.append(st) }
        var line3 = line3Parts.joined(separator: ", ")
        if let pc = postcode, !pc.isEmpty { line3 += (line3.isEmpty ? "" : " ") + pc }
        let lines = [venueName, streetAddress, line3.isEmpty ? nil : line3]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return lines.isEmpty ? address : lines.joined(separator: "\n")
    }

    /// Short single-line: "Venue Name, Suburb" or fallback to legacy address
    var formattedAddressShort: String {
        let parts = [venueName, suburb].compactMap { $0?.isEmpty == false ? $0 : nil }
        let short = parts.joined(separator: ", ")
        return short.isEmpty ? address : short
    }

    /// Line 1 of the two-line short address: venue name, falling back to legacy address
    var addressLine1: String {
        if let v = venueName, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        let parts = [city, region]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return address
    }

    /// Line 2 of the two-line short address: "Suburb, State" — nil if unavailable
    var addressLine2: String? {
        var parts: [String] = []
        if let sub = suburb, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(sub)
        }
        if let st = state, !st.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(st)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct ClubMember: Identifiable, Hashable {
    let id: UUID
    var rank: Int
    var name: String
    var rating: Double
    var reliability: Int
}

enum ClubDetailTab: String, CaseIterable, Identifiable {
    case games = "Games"
    case clubNews = "Club Chat"
    case members = "Members"
    case info = "Info"

    var id: String { rawValue }

    var pillTitle: String {
        switch self {
        case .games:
            return "Games"
        case .clubNews:
            return "Chat"
        case .members:
            return "Members"
        case .info:
            return "Info"
        }
    }
}

struct ClubNewsComment: Identifiable, Hashable {
    let id: UUID
    let postID: UUID
    let userID: UUID
    let authorName: String
    let avatarColorKey: String?
    let content: String
    let createdAt: Date?
    let parentID: UUID?
}

struct ClubNewsPost: Identifiable, Hashable {
    let id: UUID
    let clubID: UUID
    let userID: UUID
    let authorName: String
    let avatarColorKey: String?
    let content: String
    let imageURLs: [URL]
    let createdAt: Date?
    let updatedAt: Date?
    var comments: [ClubNewsComment]        // var: supports optimistic inserts
    var likeCount: Int                     // var: supports optimistic like toggle
    var isLikedByCurrentUser: Bool         // var: supports optimistic like toggle
    var isAnnouncement: Bool
}

// MARK: - Session Result Chat Payload

/// Sentinel prefix that marks a club chat post as a structured session result.
/// The rest of `content` is a JSON-encoded `SessionResultPayload`.
let sessionResultSentinel = "__sr1__:"

struct SessionResultPayload: Codable {
    let gameTitle: String
    let subtitle: String       // e.g. "15 Apr · 2:00 PM · Doubles · 2 courts"
    let rounds: [SRRound]
    let champion: String?      // winner name if applicable
    let championLabel: String? // "King of the Court" / "DUPR King of the Court"

    struct SRRound: Codable {
        let number: Int
        let courts: [SRCourt]
    }

    struct SRCourt: Codable {
        let courtNumber: Int
        let showLabel: Bool
        let result: SRMatch?
    }

    struct SRMatch: Codable {
        let topNames: String
        let topScore: Int
        let topIsWinner: Bool
        let bottomNames: String
        let bottomScore: Int
        let bottomIsWinner: Bool
    }
}

// MARK: - Notification Preferences

struct NotificationPreferences: Codable, Equatable {
    var bookingConfirmedPush:  Bool
    var bookingConfirmedEmail: Bool
    var newGamePush:           Bool
    var newGameEmail:          Bool
    var waitlistPush:          Bool
    var waitlistEmail:         Bool
    /// Club member chat posts and comments. Announcements always push through regardless.
    var chatPush:              Bool

    init(
        bookingConfirmedPush:  Bool = true,
        bookingConfirmedEmail: Bool = true,
        newGamePush:           Bool = true,
        newGameEmail:          Bool = true,
        waitlistPush:          Bool = true,
        waitlistEmail:         Bool = true,
        chatPush:              Bool = true
    ) {
        self.bookingConfirmedPush  = bookingConfirmedPush
        self.bookingConfirmedEmail = bookingConfirmedEmail
        self.newGamePush           = newGamePush
        self.newGameEmail          = newGameEmail
        self.waitlistPush          = waitlistPush
        self.waitlistEmail         = waitlistEmail
        self.chatPush              = chatPush
    }

    enum CodingKeys: String, CodingKey {
        case bookingConfirmedPush  = "booking_confirmed_push"
        case bookingConfirmedEmail = "booking_confirmed_email"
        case newGamePush           = "new_game_push"
        case newGameEmail          = "new_game_email"
        case waitlistPush          = "waitlist_push"
        case waitlistEmail         = "waitlist_email"
        case chatPush              = "chat_push"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookingConfirmedPush  = try c.decode(Bool.self, forKey: .bookingConfirmedPush)
        bookingConfirmedEmail = try c.decode(Bool.self, forKey: .bookingConfirmedEmail)
        newGamePush           = try c.decode(Bool.self, forKey: .newGamePush)
        newGameEmail          = try c.decode(Bool.self, forKey: .newGameEmail)
        waitlistPush          = try c.decode(Bool.self, forKey: .waitlistPush)
        waitlistEmail         = try c.decode(Bool.self, forKey: .waitlistEmail)
        // chat_push may be NULL in older rows (column added without DEFAULT) — treat NULL as opted-in
        chatPush              = (try? c.decodeIfPresent(Bool.self, forKey: .chatPush)) ?? true
    }
}

struct AppNotification: Identifiable, Hashable {
    let id: UUID
    let userID: UUID
    let title: String
    let body: String
    let type: NotificationType
    let referenceID: UUID?
    var read: Bool
    let createdAt: Date?

    /// Returns the deep link destination for this notification, if any.
    var deepLink: DeepLink? {
        guard let id = referenceID else { return nil }
        switch type {
        case .bookingConfirmed, .bookingWaitlisted, .waitlistPromoted,
             .bookingCancelled, .gameCancelled, .gameUpdated, .newGame, .gameReminder2h:
            return .game(id: id)
        case .gameReviewRequest:
            return .review(gameID: id)
        case .membershipApproved, .membershipRejected, .membershipRemoved,
             .membershipRequestReceived, .adminPromoted,
             .clubNewPost, .clubAnnouncement, .clubNewComment:
            return .club(id: id)
        case .unknown:
            return nil
        }
    }

    enum NotificationType: String, Hashable {
        case bookingConfirmed = "booking_confirmed"
        case bookingWaitlisted = "booking_waitlisted"
        case waitlistPromoted = "waitlist_promoted"
        case bookingCancelled = "booking_cancelled"
        case membershipApproved = "membership_approved"
        case membershipRejected = "membership_rejected"
        case membershipRemoved = "membership_removed"
        case membershipRequestReceived = "membership_request_received"
        case adminPromoted = "admin_promoted"
        case clubNewPost = "club_new_post"
        case clubAnnouncement = "club_announcement"
        case clubNewComment = "club_new_comment"
        case gameCancelled = "game_cancelled"
        case gameUpdated = "game_updated"
        case gameReviewRequest = "game_review_request"
        case newGame = "new_game"
        case gameReminder2h = "game_reminder_2h"
        case unknown

        init(raw: String) {
            switch raw {
            case "booking_confirmed": self = .bookingConfirmed
            case "booking_waitlisted": self = .bookingWaitlisted
            case "waitlist_promoted": self = .waitlistPromoted
            case "booking_cancelled": self = .bookingCancelled
            case "membership_approved": self = .membershipApproved
            case "membership_rejected": self = .membershipRejected
            case "membership_removed": self = .membershipRemoved
            case "membership_request_received": self = .membershipRequestReceived
            case "admin_promoted": self = .adminPromoted
            case "club_new_post": self = .clubNewPost
            case "club_announcement": self = .clubAnnouncement
            case "club_new_comment": self = .clubNewComment
            case "game_cancelled": self = .gameCancelled
            case "game_updated": self = .gameUpdated
            case "game_review_request": self = .gameReviewRequest
            case "new_game": self = .newGame
            case "game_reminder_2h": self = .gameReminder2h
            default: self = .unknown
            }
        }

        var iconName: String {
            switch self {
            case .bookingConfirmed: return "checkmark.circle.fill"
            case .bookingWaitlisted: return "clock.badge"
            case .waitlistPromoted: return "arrow.up.circle.fill"
            case .bookingCancelled: return "xmark.circle.fill"
            case .membershipApproved: return "checkmark.seal.fill"
            case .membershipRejected: return "xmark.seal.fill"
            case .membershipRemoved: return "minus.circle.fill"
            case .membershipRequestReceived: return "person.crop.circle.badge.questionmark"
            case .adminPromoted: return "crown.fill"
            case .clubNewPost: return "bubble.left.fill"
            case .clubAnnouncement: return "megaphone.fill"
            case .clubNewComment: return "bubble.right.fill"
            case .gameCancelled: return "calendar.badge.minus"
            case .gameUpdated: return "calendar.badge.exclamationmark"
            case .gameReviewRequest: return "star.fill"
            case .newGame: return "calendar.badge.plus"
            case .gameReminder2h: return "bell.badge.fill"
            case .unknown: return "bell.fill"
            }
        }

        // "pineTeal" | "errorRed" | "slateBlue" | "spicyOrange" | "emeraldAction" | "brandPrimary"
        var accentColorName: String {
            switch self {
            case .bookingConfirmed, .membershipApproved, .waitlistPromoted, .adminPromoted, .newGame, .gameReminder2h:
                return "pineTeal"
            case .bookingCancelled, .membershipRejected, .membershipRemoved, .gameCancelled:
                return "errorRed"
            case .bookingWaitlisted:
                return "slateBlue"
            case .clubAnnouncement:
                return "spicyOrange"
            case .membershipRequestReceived:
                return "emeraldAction"
            case .gameReviewRequest:
                return "spicyOrange"
            default:
                return "brandPrimary"
            }
        }
    }
}

struct ClubNewsModerationReport: Identifiable, Hashable {
    enum TargetKind: String, Hashable {
        case post
        case comment
        case unknown
    }

    let id: UUID
    let clubID: UUID
    let senderUserID: UUID
    let senderName: String
    let targetKind: TargetKind
    let targetID: UUID?
    let reason: String
    let details: String
    let createdAt: Date?
}

struct FeedImageUploadPayload {
    let data: Data
    let contentType: String
    let fileExtension: String
}

enum BookingState: Hashable {
    case none
    /// Booking exists and is confirmed — player has a spot.
    case confirmed
    case waitlisted(position: Int?)
    case cancelled
    /// Booking created before payment is collected. Spot IS counted toward game capacity
    /// (confirmed + pending_payment both hold a physical seat in the DB).
    /// Transitions to `.confirmed` after successful payment or `.cancelled` on timeout/explicit release.
    case pendingPayment
    case unknown(String)

    var actionTitle: String {
        switch self {
        case .none:
            return "Join Game"
        case .confirmed:
            return "Booked"
        case .waitlisted:
            return "Waitlisted"
        case .cancelled:
            return "Book Again"
        case .pendingPayment:
            return "Complete Payment"
        case .unknown:
            return "Joined"
        }
    }

    var canBook: Bool {
        switch self {
        case .none, .cancelled:
            return true
        case .confirmed, .waitlisted, .pendingPayment, .unknown:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .confirmed, .waitlisted:
            return true
        case .none, .cancelled, .pendingPayment, .unknown:
            return false
        }
    }

    /// True when the booking exists but payment has not been completed.
    var requiresPaymentCompletion: Bool {
        if case .pendingPayment = self { return true }
        return false
    }
}

struct Game: Identifiable, Hashable {
    let id: UUID
    let clubID: UUID
    var recurrenceGroupID: UUID? = nil
    var title: String
    var description: String?
    var dateTime: Date
    var durationMinutes: Int
    var skillLevel: String
    var gameFormat: String
    var gameType: String
    var maxSpots: Int
    var feeAmount: Double?
    var feeCurrency: String?
    var venueId: UUID? = nil       // FK to club_venues.id
    var venueName: String? = nil   // kept for backward compat + display safety
    var location: String?
    var latitude: Double? = nil
    var longitude: Double? = nil
    var status: String
    var notes: String?
    var requiresDUPR: Bool
    var courtCount: Int = 1
    var confirmedCount: Int?
    var waitlistCount: Int?
    var publishAt: Date? = nil

    /// True when the game has a future publish date — it exists in the DB but is not yet visible to members.
    var isScheduled: Bool {
        guard let pa = publishAt else { return false }
        return pa > Date()
    }

    var startsInPast: Bool {
        dateTime < Date()
    }

    var spotsFilled: Int? {
        confirmedCount
    }

    var spotsLeft: Int? {
        guard let confirmedCount else { return nil }
        return max(maxSpots - confirmedCount, 0)
    }

    var isFull: Bool {
        guard let confirmedCount else { return false }
        return confirmedCount >= maxSpots
    }
}

struct BookingRecord: Identifiable, Hashable {
    let id: UUID
    let gameID: UUID
    let userID: UUID
    let state: BookingState
    let waitlistPosition: Int?
    let createdAt: Date?
    let feePaid: Bool
    let paidAt: Date?
    let stripePaymentIntentID: String?
    /// "stripe" = paid via card/Apple Pay, "admin" = added by club owner bypassing payment, nil = self-booked free game
    let paymentMethod: String?
    /// Platform fee retained (in cents) — nil for free games or pre-Connect bookings.
    let platformFeeCents: Int?
    /// Amount transferred to the club via Stripe Connect (in cents) — nil for free games or pre-Connect bookings.
    let clubPayoutCents: Int?
    /// Credits applied from the user's balance at checkout (in cents). nil = no credits used.
    let creditsAppliedCents: Int?
    /// Phase 3: when non-nil, this booking is a promoted waitlist hold. Spot is reserved until this timestamp.
    let holdExpiresAt: Date?

    /// True when the booking is a promoted waitlist hold that has not yet expired.
    var hasActiveHold: Bool {
        guard let exp = holdExpiresAt else { return false }
        return exp > Date()
    }
}

struct BookingWithGame: Identifiable, Hashable {
    var id: UUID { booking.id }
    let booking: BookingRecord
    let game: Game?
}

// MARK: - Stripe Connect

/// Returned from `createPaymentIntent` — carries the client secret plus computed fee breakdown.
struct PaymentIntentResult {
    let clientSecret: String
    /// Platform fee retained (in cents). Zero for free games or when club has no Connect account.
    let platformFeeCents: Int
    /// Amount to be transferred to the club (in cents).
    let clubPayoutCents: Int
}

/// Stripe Connect Express account status for a club.
struct ClubStripeAccount: Identifiable, Equatable {
    let id: UUID
    let clubID: UUID
    /// Stripe account ID (acct_xxx).
    let stripeAccountID: String
    let onboardingComplete: Bool
    let payoutsEnabled: Bool
    let createdAt: Date?
}

/// Platform subscription for a club (Phase 4).
struct ClubSubscription {
    let id: UUID
    let clubID: UUID
    let stripeSubscriptionID: String
    let planType: String   // "starter" | "pro"
    let status: String     // "active" | "past_due" | "canceled" | "incomplete"
    let currentPeriodEnd: Date?
    let createdAt: Date?

    /// True while the subscription provides active access (including the grace period after cancellation is scheduled).
    var isActive: Bool { status == "active" || status == "canceling" }
    var isPastDue: Bool { status == "past_due" }
    var isCanceling: Bool { status == "canceling" }

    var planDisplayName: String {
        switch planType {
        case "starter": return "Starter"
        case "pro":     return "Pro"
        default:        return planType.capitalized
        }
    }

    var statusDisplayName: String {
        switch status {
        case "active":     return "Active"
        case "canceling":  return "Active (cancels at period end)"
        case "past_due":   return "Payment overdue"
        case "canceled":   return "Canceled"
        case "incomplete": return "Awaiting payment"
        default:           return status.capitalized
        }
    }
}

/// Returned by the create-club-subscription Edge Function.
struct ClubSubscriptionResult {
    let subscriptionID: String
    let status: String
    /// Non-nil when `status == "incomplete"` — pass to StripePaymentSheet.
    let clientSecret: String?
}

/// Derived entitlement state for a club. The app reads ONLY this — never plan_type,
/// subscription status, or any Stripe field directly.
///
/// All values are derived by derive_club_entitlements() in PostgreSQL.
/// Do not reimplement the tier → feature mapping in Swift.
struct ClubEntitlements {
    let clubID: UUID
    /// Display label only. Never branch on this in app logic — use the feature fields below.
    let planTier: String
    /// Maximum concurrent active/upcoming games. -1 = unlimited.
    let maxActiveGames: Int
    /// Maximum approved members. -1 = unlimited.
    let maxMembers: Int
    let canAcceptPayments: Bool
    let analyticsAccess: Bool
    let canUseRecurringGames: Bool
    let canUseDelayedPublishing: Bool
    /// Server-computed locked feature keys. Canonical payload for Android/web parity.
    /// Keys: "payments", "analytics", "recurring_games", "delayed_publishing".
    /// iOS gating reads the individual boolean fields above via FeatureGateService — this
    /// array is additive and not used for iOS gating decisions.
    let lockedFeatures: [String]
    let updatedAt: Date
}

/// Per-tier plan limit definitions returned by get_plan_tier_limits().
/// Fetched once at launch and cached in AppState.planTierLimits.
/// Paywall UI reads from this — no hardcoded limit numbers in Swift.
struct PlanTierLimits {
    let planTier: String
    let maxActiveGames: Int
    let maxMembers: Int
    let canAcceptPayments: Bool
    let analyticsAccess: Bool
    let canUseRecurringGames: Bool
    let canUseDelayedPublishing: Bool
}

/// Active subscription plan definition returned by get_subscription_plans().
/// Fetched once at launch and cached in AppState.subscriptionPlans.
/// Clients use this for paywall display prices and Stripe price IDs — never hardcode either.
struct SubscriptionPlan {
    let planID: String          // "starter" | "pro" — matches club_subscriptions.plan_type
    let displayName: String     // "Starter" | "Pro"
    let stripePriceID: String   // Stripe Price API ID sent to create-club-subscription
    let displayPrice: String    // Localised price string shown in UI ("A$19/mo")
    let billingInterval: String // "monthly"
    let sortOrder: Int
}

/// Phase 5A-1 — returned by get_club_revenue_summary RPC.
/// All monetary values are in cents. Divide by 100 for display.
struct ClubRevenueSummary {
    let totalClubPayoutCents: Int
    let totalPlatformFeeCents: Int
    let paidBookingCount: Int
    let freeBookingCount: Int
    let currency: String
    let asOf: Date
}

/// Phase 5A-2 — returned by get_club_fill_rate_summary RPC.
/// averageFillRate and cancellationRate are 0.0–1.0. Multiply by 100 for display as percentage.
struct ClubFillRateSummary {
    let totalGamesCount: Int
    let totalSpotsOffered: Int
    let totalConfirmedBookings: Int
    let averageFillRate: Double
    let fullGamesCount: Int
    let averagePlayersPerGame: Double
    let cancellationRate: Double
    let asOf: Date
}

// MARK: - Phase 5B Analytics Models

/// Period options for the advanced analytics dashboard. Always finite (no all-time)
/// so that prior-period comparison is always meaningful.
enum AnalyticsPeriod: Int, CaseIterable, Identifiable {
    case last7  = 7
    case last30 = 30
    case last90 = 90

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .last7:  return "7d"
        case .last30: return "30d"
        case .last90: return "90d"
        }
    }

    var comparisonLabel: String {
        switch self {
        case .last7:  return "vs prev 7d"
        case .last30: return "vs prev 30d"
        case .last90: return "vs prev 90d"
        }
    }
}

/// Returned by get_club_dashboard_summary — lightweight dashboard snapshot for all plan tiers.
/// No analytics entitlement required. Rates are 0.0–1.0. Counts are non-negative integers.
struct ClubDashboardSummary {
    /// Current approved member count.
    let totalMembers: Int
    /// Members whose requested_at is within the last 30 days (join-date proxy; removal not tracked).
    let memberGrowth30d: Int
    /// Distinct players with a confirmed booking on a past club game in the last 30 days.
    let monthlyActivePlayers30d: Int
    /// Same metric, prior 30-day window — used for delta display.
    let prevActivePlayers30d: Int
    /// Weighted fill rate (total confirmed / total capacity) across completed games in last 30 days.
    /// `nil` when no completed games with valid capacity exist in the window.
    let fillRate30d: Double?
    /// Same metric, prior 30-day window — used for delta display.
    /// `nil` when no completed games with valid capacity exist in the prior window.
    let prevFillRate30d: Double?
    /// Confirmed bookings across all future non-cancelled games.
    let upcomingBookingsCount: Int
}

/// Returned by get_club_analytics_supplemental — operational and membership metrics.
/// Complements ClubAnalyticsKPIs. All counts are non-negative. Rates are DB-computed.
struct ClubAnalyticsSupplemental {
    let currMemberJoins:       Int     // new approved members in period (requested_at proxy)
    let prevMemberJoins:       Int     // same, prior period — for delta
    let totalActiveMembers:    Int     // all currently approved members
    let currNewPlayers:        Int     // first-time bookers at this club in the period
    let currGameCount:         Int     // past games hosted in the period
    let currNoShowCount:       Int     // game_attendance rows with no_show status (raw count for auditing)
    let currCheckedCount:      Int     // total game_attendance rows (attended + no_show, raw count)
    let currWaitlistCount:     Int     // waitlisted bookings across current period games
    let currPaidBookings:             Int     // Stripe + cash-paid confirmed bookings
    let currFreeBookings:             Int     // credits, comp/admin, and free-game bookings
    let avgRevPerPlayerCents:         Int     // (Stripe payout + cash) / distinct paying players
    /// DB-computed no-show rate (0.0–1.0). `nil` when no attendance rows exist for the period.
    /// Authoritative source: get_club_analytics_supplemental.curr_no_show_rate.
    let noShowRate:                   Double? // nil = no attendance data
    // Booking type breakdown
    let currCreditBookingCount:       Int     // paid entirely with credits (payment_method='credits')
    let currCompBookingCount:         Int     // comp/admin bookings (payment_method='admin')
    let currTrulyFreeBookingCount:    Int     // free games with no payment method (payment_method IS NULL)
    let currCashBookingCount:         Int     // cash-paid confirmed bookings (payment_method='cash', fee_paid=true)
}

/// Returned by get_club_analytics_kpis — current period + prior-period comparison.
/// All monetary values are in cents. Rates are 0.0–1.0.
/// Revenue hierarchy:
///   currRevenueCents = Stripe club payout + cash revenue (primary KPI — total club net revenue)
///   currGrossRevenueCents = Stripe gross (platform_fee + payout) + cash revenue (player-facing total)
///   currManualRevenueCents = cash-only revenue (separable from Stripe)
///   currPlatformFeeCents = platform fee (Stripe only; no platform cut on cash)
struct ClubAnalyticsKPIs {
    let currRevenueCents:  Int   // total club net revenue: Stripe payout + cash
    let currBookingCount:  Int
    let currFillRate:      Double
    let currActivePlayers: Int

    let prevRevenueCents:  Int   // total club net revenue prior period
    let prevBookingCount:  Int
    let prevFillRate:      Double
    let prevActivePlayers: Int

    let cancellationRate:  Double
    let repeatPlayerRate:  Double
    let currency:          String
    let asOf:              Date

    // Revenue breakdown
    let currGrossRevenueCents:   Int   // player-facing total: Stripe gross + cash
    let currPlatformFeeCents:    Int   // platform fee (Stripe only)
    let currCreditsUsedCents:    Int   // credits_applied_cents across all confirmed bookings
    let prevGrossRevenueCents:   Int
    let prevPlatformFeeCents:    Int
    let prevCreditsUsedCents:    Int
    let currCreditsReturnedCents: Int  // credits issued to players from eligible cancellations (NOT a Stripe cash refund)
    let currCreditReturnCount:   Int  // number of cancellations that triggered a credit return
    let currManualRevenueCents:  Int   // cash/manual revenue current period
    let prevManualRevenueCents:  Int   // cash/manual revenue prior period
}

/// One data point in the revenue trend time-series (get_club_revenue_trend).
struct ClubRevenueTrendPoint: Identifiable {
    var id: Date { bucketDate }
    let bucketDate:   Date
    let revenueCents: Int
    let bookingCount: Int
    let fillRate:     Double
}

/// A single top-performing game entry (get_club_top_games).
/// A recurring game pattern ranked by average attendance (get_club_top_games).
/// Groups game instances by title + day-of-week + hour + skill + format + venue
/// so consistently popular slots rank above one-off high-attendance events.
struct ClubTopGame: Identifiable {
    // Stable pattern key — no instance-specific date or UUID.
    var id: String { "\(title.lowercased())-\(dayOfWeek)-\(hourOfDay)" }

    let title:              String
    let dayOfWeek:          Int     // 0 = Sunday … 6 = Saturday (club local TZ)
    let hourOfDay:          Int     // 0–23 (club local TZ)
    let occurrenceCount:         Int     // how many sessions matched this pattern
    let filledOccurrenceCount:   Int     // sessions that reached full capacity
    let avgConfirmed:            Double  // average confirmed attendees per session
    let maxSpots:                Int     // most-common capacity for the pattern
    let avgFillRate:             Double  // average fill rate (0–1)
    let totalRevenueCents:       Int     // sum of club payout for all instances
    let avgWaitlist:             Double  // average waitlist demand per session
    let avgTimeToFillMinutes:    Double? // avg minutes from open to first fill; nil when no instance ever filled
    let skillLevel:              String?
    let gameFormat:              String?

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var dayLabel: String {
        guard dayOfWeek >= 0, dayOfWeek < Self.dayNames.count else { return "?" }
        return Self.dayNames[dayOfWeek]
    }

    var hourLabel: String {
        let h  = hourOfDay % 12 == 0 ? 12 : hourOfDay % 12
        let ap = hourOfDay < 12 ? "am" : "pm"
        return "\(h)\(ap)"
    }
}

/// A peak day/time slot (get_club_peak_times).
struct ClubPeakTime: Identifiable {
    var id: String { "\(dayOfWeek)-\(hourOfDay)" }
    let dayOfWeek:    Int     // 0 = Sunday … 6 = Saturday (club local TZ)
    let hourOfDay:    Int     // 0–23 (club local TZ)
    let avgConfirmed: Double
    let gameCount:    Int
    let avgFillRate:  Double  // average fill rate across games in this slot
    let avgWaitlist:  Double  // average waitlist demand per game in this slot

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var dayLabel: String {
        guard dayOfWeek >= 0, dayOfWeek < Self.dayNames.count else { return "?" }
        return Self.dayNames[dayOfWeek]
    }

    var hourLabel: String {
        let h  = hourOfDay % 12 == 0 ? 12 : hourOfDay % 12
        let ap = hourOfDay < 12 ? "am" : "pm"
        return "\(h)\(ap)"
    }
}

struct GameAttendee: Identifiable, Hashable {
    var id: UUID { booking.id }
    let booking: BookingRecord
    let userName: String
    let userEmail: String?
    let duprRating: Double?
    // Avatar colour is identity data. Do not derive per-view.
    let avatarColorKey: String?
}

struct GameReview: Identifiable, Hashable {
    let id: UUID
    let gameID: UUID
    let userID: UUID
    let rating: Int
    let comment: String?
    let createdAt: Date?
    /// Reviewer's full name, resolved from a joined profiles query.
    let reviewerName: String?
    /// Game title, resolved from a joined games query.
    let gameTitle: String?
    // Avatar colour is identity data. Do not derive per-view.
    let avatarColorKey: String?

    var initials: String {
        let parts = (reviewerName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts)
    }
}

/// A server-authoritative review prompt returned by get_pending_review_prompt().
/// Presented proactively on app open/home load when the server says a review is due.
struct PendingReviewPrompt: Identifiable, Equatable {
    let id: UUID            // game ID
    let gameTitle: String
    let gameDateTime: Date
    let clubID: UUID
    let clubName: String
}

struct ClubOwnerGameDraft {
    var title: String = ""
    var description: String = ""
    var startDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var durationMinutes: Int = 90
    var maxSpots: Int = 16
    var courtCount: Int = 1
    var feeAmountText: String = ""
    var feeCurrency: String = "AUD"
    var selectedVenueID: UUID? = nil   // nil = custom / no saved venue
    var venueName: String = ""
    var venueLatitude: Double? = nil   // copied from venue at selection time
    var venueLongitude: Double? = nil
    var location: String = ""
    var notes: String = ""
    var requiresDUPR: Bool = false
    var skillLevelRaw: String = "all"
    var gameFormatRaw: String = "open_play"
    var gameTypeRaw: String = "doubles"
    var repeatWeekly: Bool = false
    var repeatCount: Int = 1
    /// Absolute date/time at which the game becomes visible to members.
    /// nil = publish immediately. For recurring games, each instance derives its
    /// own publishAt from the same offset (game.startDate - publishAt) applied to
    /// that instance's start time.
    var publishAt: Date? = nil

    /// True when a venue is selected from saved venues or a custom name has been entered.
    var hasVenue: Bool {
        selectedVenueID != nil || !venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Populate venue fields from a saved ClubVenue.
    /// Captures coordinates at selection time so they are written to the game row on save.
    mutating func applyVenue(_ venue: ClubVenue) {
        selectedVenueID = venue.id
        venueName = venue.venueName
        venueLatitude = venue.latitude
        venueLongitude = venue.longitude
    }

    /// Clear venue selection back to custom entry.
    mutating func clearVenue() {
        selectedVenueID = nil
        venueName = ""
        venueLatitude = nil
        venueLongitude = nil
        location = ""
    }

    init() {}

    init(game: Game) {
        title = game.title
        description = game.description ?? ""
        startDate = game.dateTime
        durationMinutes = game.durationMinutes
        maxSpots = game.maxSpots
        courtCount = game.courtCount
        if let fee = game.feeAmount, fee > 0 {
            feeAmountText = String(format: "%.2f", fee)
        } else {
            feeAmountText = ""
        }
        feeCurrency = game.feeCurrency ?? "AUD"
        selectedVenueID = game.venueId
        venueName = game.venueName ?? ""
        location = game.location ?? ""
        notes = game.notes ?? ""
        requiresDUPR = game.requiresDUPR
        publishAt = game.publishAt
        skillLevelRaw = game.skillLevel
        gameTypeRaw = game.gameType
        gameFormatRaw = game.gameFormat
        repeatWeekly = false
        repeatCount = 1
    }
}

struct ClubOwnerEditDraft: Equatable {
    var name: String
    var description: String
    var contactEmail: String
    var contactPhone: String
    var website: String
    var managerName: String
    var membersOnly: Bool
    var avatarBackgroundColor: String? = nil
    var uploadedAvatarURL: URL? = nil      // set after a custom avatar is uploaded
    var heroImageKey: String?
    var uploadedBannerURL: URL? = nil      // set after a custom banner is uploaded
    private var existingImageURLString: String?
    private var existingBannerURLString: String?

    // Captures the address fingerprint at init time (nil for new clubs).
    // Used to detect when any location field changes so stale coordinates
    // can be invalidated before the record is saved.
    private let _originalAddressKey: String?

    /// True when any location field differs from the value at init time.
    /// Always false for new clubs (no existing coordinates to invalidate).
    var locationChanged: Bool {
        guard let original = _originalAddressKey else { return false }
        return _addressKey != original
    }

    private var _addressKey: String {
        [venueName, streetAddress, suburb, state, postcode, country].joined(separator: "|")
    }

    init() {
        name = ""
        description = ""
        contactEmail = ""
        contactPhone = ""
        website = ""
        managerName = ""
        membersOnly = false
        avatarBackgroundColor = nil
        heroImageKey = nil
        existingImageURLString = nil
        existingBannerURLString = nil
        _originalAddressKey = nil
    }

    var winCondition: WinCondition = .firstTo11By2
    var defaultCourtCount: Int = 1
    var codeOfConduct: String = ""
    var cancellationPolicy: String = ""
    var venueName: String = ""
    var streetAddress: String = ""
    var suburb: String = ""
    var state: String = ""
    var postcode: String = ""
    var country: String = "Australia"

    init(club: Club) {
        name = club.name
        description = club.description
        contactEmail = club.contactEmail == "No contact email listed" ? "" : club.contactEmail
        contactPhone = club.contactPhone ?? ""
        website = club.website ?? ""
        managerName = club.managerName ?? ""
        membersOnly = club.membersOnly
        winCondition = club.winCondition
        defaultCourtCount = club.defaultCourtCount
        codeOfConduct = club.codeOfConduct ?? ""
        cancellationPolicy = club.cancellationPolicy ?? ""
        venueName = club.venueName ?? ""
        streetAddress = club.streetAddress ?? ""
        suburb = club.suburb ?? ""
        state = club.state ?? ""
        postcode = club.postcode ?? ""
        country = club.country ?? "Australia"
        avatarBackgroundColor = club.avatarBackgroundColor
        heroImageKey = club.heroImageKey
        existingImageURLString = club.imageURL?.absoluteString
        existingBannerURLString = club.customBannerURL?.absoluteString
        _originalAddressKey = [club.venueName ?? "", club.streetAddress ?? "", club.suburb ?? "",
                               club.state ?? "", club.postcode ?? "",
                               club.country ?? "Australia"].joined(separator: "|")
    }

    var imageURLStringForSave: String? {
        if let uploadedAvatarURL { return uploadedAvatarURL.absoluteString }
        return existingImageURLString
    }

    var customBannerURLStringForSave: String? {
        if let uploadedBannerURL { return uploadedBannerURL.absoluteString }
        return existingBannerURLString
    }
}

enum RecurringGameScope: String, CaseIterable, Identifiable {
    case singleEvent = "This Event"
    case thisAndFuture = "This & Future"
    case entireSeries = "Entire Series"

    var id: String { rawValue }
}
