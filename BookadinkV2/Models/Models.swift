import Foundation

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
}

struct ClubDirectoryMember: Identifiable, Hashable {
    let id: UUID
    let name: String
    let duprRating: Double?
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

    var locationDisplay: String {
        let parts = [city, region].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return address
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
    let comments: [ClubNewsComment]
    let likeCount: Int
    let isLikedByCurrentUser: Bool
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

    enum NotificationType: String, Hashable {
        case bookingConfirmed = "booking_confirmed"
        case bookingWaitlisted = "booking_waitlisted"
        case waitlistPromoted = "waitlist_promoted"
        case bookingCancelled = "booking_cancelled"
        case membershipApproved = "membership_approved"
        case membershipRejected = "membership_rejected"
        case membershipRemoved = "membership_removed"
        case membershipRequestReceived = "membership_request_received"
        case clubNewPost = "club_new_post"
        case clubAnnouncement = "club_announcement"
        case clubNewComment = "club_new_comment"
        case gameCancelled = "game_cancelled"
        case gameUpdated = "game_updated"
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
            case "club_new_post": self = .clubNewPost
            case "club_announcement": self = .clubAnnouncement
            case "club_new_comment": self = .clubNewComment
            case "game_cancelled": self = .gameCancelled
            case "game_updated": self = .gameUpdated
            default: self = .unknown
            }
        }

        var iconName: String {
            switch self {
            case .bookingConfirmed: return "checkmark.circle.fill"
            case .bookingWaitlisted: return "clock.badge"
            case .waitlistPromoted: return "arrow.up.circle.fill"
            case .bookingCancelled: return "xmark.circle.fill"
            case .membershipApproved: return "person.badge.checkmark"
            case .membershipRejected: return "person.badge.xmark"
            case .membershipRemoved: return "person.crop.circle.badge.minus"
            case .membershipRequestReceived: return "person.crop.circle.badge.questionmark"
            case .clubNewPost: return "bubble.left.fill"
            case .clubAnnouncement: return "megaphone.fill"
            case .clubNewComment: return "bubble.right.fill"
            case .gameCancelled: return "calendar.badge.minus"
            case .gameUpdated: return "calendar.badge.exclamationmark"
            case .unknown: return "bell.fill"
            }
        }

        // "pineTeal" | "errorRed" | "slateBlue" | "spicyOrange" | "emeraldAction" | "brandPrimary"
        var accentColorName: String {
            switch self {
            case .bookingConfirmed, .membershipApproved, .waitlistPromoted:
                return "pineTeal"
            case .bookingCancelled, .membershipRejected, .membershipRemoved, .gameCancelled:
                return "errorRed"
            case .bookingWaitlisted:
                return "slateBlue"
            case .clubAnnouncement:
                return "spicyOrange"
            case .membershipRequestReceived:
                return "emeraldAction"
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
    var maxSpots: Int
    var feeAmount: Double?
    var feeCurrency: String?
    var location: String?
    var status: String
    var notes: String?
    var requiresDUPR: Bool
    var confirmedCount: Int?
    var waitlistCount: Int?

    var displayLocation: String {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Club Venue" : trimmed
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

struct ClubOwnerGameDraft {
    var title: String = ""
    var description: String = ""
    var startDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var durationMinutes: Int = 90
    var maxSpots: Int = 16
    var feeAmountText: String = ""
    var feeCurrency: String = "USD"
    var location: String = ""
    var notes: String = ""
    var requiresDUPR: Bool = false
    var skillLevelRaw: String = "all"
    var gameFormatRaw: String = "open_play"
    var repeatWeekly: Bool = false
    var repeatCount: Int = 1

    init() {}

    init(game: Game) {
        title = game.title
        description = game.description ?? ""
        startDate = game.dateTime
        durationMinutes = game.durationMinutes
        maxSpots = game.maxSpots
        if let fee = game.feeAmount, fee > 0 {
            feeAmountText = String(format: "%.2f", fee)
        } else {
            feeAmountText = ""
        }
        feeCurrency = game.feeCurrency ?? "USD"
        location = game.location ?? ""
        notes = game.notes ?? ""
        requiresDUPR = game.requiresDUPR
        skillLevelRaw = game.skillLevel
        gameFormatRaw = game.gameFormat.caseInsensitiveCompare("ladder") == .orderedSame ? "king_of_court" : game.gameFormat
        repeatWeekly = false
        repeatCount = 1
    }
}

struct ClubOwnerEditDraft {
    var name: String
    var location: String
    var description: String
    var contactEmail: String
    var website: String
    var managerName: String
    var membersOnly: Bool
    var profilePicturePresetID: String?
    private var existingImageURLString: String?

    init() {
        name = ""
        location = ""
        description = ""
        contactEmail = ""
        website = ""
        managerName = ""
        membersOnly = false
        profilePicturePresetID = nil
        existingImageURLString = nil
    }

    init(club: Club) {
        name = club.name
        location = club.address
        description = club.description
        contactEmail = club.contactEmail == "No contact email listed" ? "" : club.contactEmail
        website = club.website ?? ""
        managerName = club.managerName ?? ""
        membersOnly = club.membersOnly
        profilePicturePresetID = ClubProfileImagePresets.presetID(from: club.imageURL)
        if let url = club.imageURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            existingImageURLString = url.absoluteString
        } else {
            existingImageURLString = nil
        }
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
