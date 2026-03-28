import Foundation
import SwiftUI

struct UserProfile: Identifiable {
    let id: UUID
    var fullName: String
    var email: String
    var phone: String?
    var dateOfBirth: Date?
    var emergencyContactName: String?
    var emergencyContactPhone: String?
    var duprRating: Double?
    var favoriteClubName: String?
    var skillLevel: SkillLevel
    var avatarPresetID: String? = nil
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
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"
    case tournament = "Tournament"

    var id: String { rawValue }
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
    let adminRole: String?
    let conductAcceptedAt: Date?
}

struct ClubDirectoryMember: Identifiable, Hashable {
    let id: UUID
    let name: String
    let duprRating: Double?
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

    var isValid: Bool { !venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
    var city: String
    var region: String
    var memberCount: Int
    var description: String
    var contactEmail: String
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
    // Structured address (prefer these over legacy `address` when present)
    var venueName: String? = nil
    var streetAddress: String? = nil
    var suburb: String? = nil
    var state: String? = nil
    var postcode: String? = nil
    var country: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var heroImageKey: String? = nil
    var codeOfConduct: String? = nil

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
    let content: String
    let createdAt: Date?
    let parentID: UUID?
}

struct ClubNewsPost: Identifiable, Hashable {
    let id: UUID
    let clubID: UUID
    let userID: UUID
    let authorName: String
    let content: String
    let imageURLs: [URL]
    let createdAt: Date?
    let updatedAt: Date?
    var comments: [ClubNewsComment]        // var: supports optimistic inserts
    var likeCount: Int                     // var: supports optimistic like toggle
    var isLikedByCurrentUser: Bool         // var: supports optimistic like toggle
    var isAnnouncement: Bool
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
             .bookingCancelled, .gameCancelled, .gameUpdated:
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
            case .unknown: return "bell.fill"
            }
        }

        // "pineTeal" | "errorRed" | "slateBlue" | "spicyOrange" | "emeraldAction" | "brandPrimary"
        var accentColorName: String {
            switch self {
            case .bookingConfirmed, .membershipApproved, .waitlistPromoted, .adminPromoted:
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
    case confirmed
    case waitlisted(position: Int?)
    case cancelled
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
        case .unknown:
            return "Joined"
        }
    }

    var canBook: Bool {
        switch self {
        case .none, .cancelled:
            return true
        case .confirmed, .waitlisted, .unknown:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .confirmed, .waitlisted:
            return true
        case .none, .cancelled, .unknown:
            return false
        }
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
}

struct BookingWithGame: Identifiable, Hashable {
    var id: UUID { booking.id }
    let booking: BookingRecord
    let game: Game?
}

struct GameAttendee: Identifiable, Hashable {
    var id: UUID { booking.id }
    let booking: BookingRecord
    let userName: String
    let userEmail: String?
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

    var initials: String {
        let parts = (reviewerName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts)
    }
}

struct ClubOwnerGameDraft {
    var title: String = ""
    var description: String = ""
    var startDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var durationMinutes: Int = 90
    var maxSpots: Int = 16
    var courtCount: Int = 1
    var feeAmountText: String = ""
    var feeCurrency: String = "USD"
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
        feeCurrency = game.feeCurrency ?? "USD"
        selectedVenueID = game.venueId
        venueName = game.venueName ?? ""
        location = game.location ?? ""
        notes = game.notes ?? ""
        requiresDUPR = game.requiresDUPR
        publishAt = game.publishAt
        skillLevelRaw = game.skillLevel
        // Backward compat: old games stored "singles"/"doubles" in game_format
        let normalizedFormat = game.gameFormat.caseInsensitiveCompare("ladder") == .orderedSame ? "king_of_court" : game.gameFormat
        if normalizedFormat == "singles" || normalizedFormat == "doubles" {
            gameTypeRaw = normalizedFormat
            gameFormatRaw = "open_play"
        } else {
            gameTypeRaw = game.gameType
            gameFormatRaw = normalizedFormat
        }
        repeatWeekly = false
        repeatCount = 1
    }
}

struct ClubOwnerEditDraft {
    var name: String
    var description: String
    var contactEmail: String
    var website: String
    var managerName: String
    var membersOnly: Bool
    var profilePicturePresetID: String?
    var heroImageKey: String?
    private var existingImageURLString: String?

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
        website = ""
        managerName = ""
        membersOnly = false
        profilePicturePresetID = nil
        heroImageKey = nil
        existingImageURLString = nil
        _originalAddressKey = nil
    }

    var winCondition: WinCondition = .firstTo11By2
    var defaultCourtCount: Int = 1
    var codeOfConduct: String = ""
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
        website = club.website ?? ""
        managerName = club.managerName ?? ""
        membersOnly = club.membersOnly
        winCondition = club.winCondition
        defaultCourtCount = club.defaultCourtCount
        codeOfConduct = club.codeOfConduct ?? ""
        venueName = club.venueName ?? ""
        streetAddress = club.streetAddress ?? ""
        suburb = club.suburb ?? ""
        state = club.state ?? ""
        postcode = club.postcode ?? ""
        country = club.country ?? "Australia"
        profilePicturePresetID = ClubProfileImagePresets.presetID(from: club.imageURL)
        heroImageKey = club.heroImageKey
        if let url = club.imageURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            existingImageURLString = url.absoluteString
        } else {
            existingImageURLString = nil
        }
        _originalAddressKey = [club.venueName ?? "", club.streetAddress ?? "", club.suburb ?? "",
                               club.state ?? "", club.postcode ?? "",
                               club.country ?? "Australia"].joined(separator: "|")
    }

    var imageURLStringForSave: String? {
        if let profilePicturePresetID {
            return ClubProfileImagePresets.presetURL(for: profilePicturePresetID)?.absoluteString
        }
        return existingImageURLString
    }
}

enum RecurringGameScope: String, CaseIterable, Identifiable {
    case singleEvent = "This Event"
    case thisAndFuture = "This & Future"
    case entireSeries = "Entire Series"

    var id: String { rawValue }
}
