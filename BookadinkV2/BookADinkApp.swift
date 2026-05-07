
import AVFoundation
import SwiftUI
import UIKit
import UserNotifications
import StripePaymentSheet

extension Notification.Name {
    static let bookADinkDidRegisterForRemoteNotifications = Notification.Name("bookadink.apns.registered")
    static let bookADinkDidFailRemoteNotificationsRegistration = Notification.Name("bookadink.apns.failed")
    /// Posted when a notification tap should navigate to a game or club. Object is a `bookadink://` URL.
    static let bookADinkNotificationGameTapped = Notification.Name("bookadink.notification.game_tapped")
    /// Posted when a notification tap should open the Notifications tab (e.g. rejected/removed membership).
    static let bookADinkOpenNotificationsTab = Notification.Name("bookadink.open.notifications_tab")
    /// Posted whenever a membership status push arrives (tap or foreground) so AppState can refresh immediately.
    static let bookADinkMembershipStatusChanged = Notification.Name("bookadink.membership.status_changed")
    /// Posted when a waitlist_promoted push arrives. Object is the game UUID string.
    static let bookADinkWaitlistPromoted = Notification.Name("bookadink.booking.waitlist_promoted")
    /// Posted when a booking_cancelled push arrives (admin removed the player).
    /// Object is the game UUID string (from `reference_id`) so the listener can refresh attendees too.
    static let bookADinkBookingCancelled = Notification.Name("bookadink.booking.cancelled")
}

final class BookADinkAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NotificationCenter.default.post(name: .bookADinkDidRegisterForRemoteNotifications, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .bookADinkDidFailRemoteNotificationsRegistration, object: error.localizedDescription)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Routes notification taps to the appropriate screen.
    ///
    /// - `booking-confirmed` edge function sends `game_id` + `booking_id`
    /// - `notify` edge function sends `type` + `reference_id` (game or club UUID)
    /// - Local reminders use the identifier prefix `bookadink.game.reminder.{uuid}`
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo

        // Check type first — it's the authoritative routing key sent by all edge functions.
        if let type = userInfo["type"] as? String {
            let gameIDFromPayload = (userInfo["game_id"] as? String).flatMap(UUID.init)
            let clubIDFromPayload = (userInfo["club_id"] as? String).flatMap(UUID.init)
            let referenceID = (userInfo["reference_id"] as? String).flatMap(UUID.init)

            switch type {
            case "booking_confirmed":
                // Open the booked game sheet.
                if let id = gameIDFromPayload ?? referenceID {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.gameURL(id: id)
                    )
                }
                return

            case "waitlist_promoted", "booking_waitlisted":
                if let id = gameIDFromPayload ?? referenceID {
                    if type == "waitlist_promoted" {
                        NotificationCenter.default.post(name: .bookADinkWaitlistPromoted, object: id.uuidString)
                    }
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.gameURL(id: id)
                    )
                }
                return

            case "game_updated", "game_reminder_2h":
                // Game still exists — open game sheet, fall back to club.
                if let id = gameIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.gameURL(id: id)
                    )
                } else if let clubID = clubIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.clubURL(id: clubID)
                    )
                } else {
                    NotificationCenter.default.post(name: .bookADinkOpenNotificationsTab, object: nil)
                }
                return

            case "new_game":
                // Navigate to club (game may not be bookable yet).
                if let clubID = clubIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.clubURL(id: clubID)
                    )
                } else if let id = gameIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.gameURL(id: id)
                    )
                } else {
                    NotificationCenter.default.post(name: .bookADinkOpenNotificationsTab, object: nil)
                }
                return

            case "game_cancelled":
                // Game row is deleted when cancelled — navigate to club instead.
                if let clubID = clubIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.clubURL(id: clubID)
                    )
                } else {
                    NotificationCenter.default.post(name: .bookADinkOpenNotificationsTab, object: nil)
                }
                return

            case "new_post", "new_comment", "new_announcement", "comment_on_post", "mention":
                // Club chat — navigate to the club feed.
                if let clubID = clubIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.clubURL(id: clubID)
                    )
                } else {
                    NotificationCenter.default.post(name: .bookADinkOpenNotificationsTab, object: nil)
                }
                return

            case "membership_approved", "admin_promoted", "membership_request_received":
                NotificationCenter.default.post(name: .bookADinkMembershipStatusChanged, object: nil)
                if let id = referenceID ?? clubIDFromPayload {
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.clubURL(id: id)
                    )
                }
                return

            case "membership_rejected", "membership_removed":
                NotificationCenter.default.post(name: .bookADinkMembershipStatusChanged, object: nil)
                NotificationCenter.default.post(name: .bookADinkOpenNotificationsTab, object: nil)
                return

            default:
                // Unknown type — open notifications tab so the user sees what arrived.
                NotificationCenter.default.post(name: .bookADinkOpenNotificationsTab, object: nil)
                return
            }
        }

        // Fallback for legacy payloads without a type field — use game_id if present.
        if let gameIDString = userInfo["game_id"] as? String,
           let gameID = UUID(uuidString: gameIDString) {
            NotificationCenter.default.post(
                name: .bookADinkNotificationGameTapped,
                object: DeepLink.gameURL(id: gameID)
            )
            return
        }

        // Fallback: extract game_id from local reminder identifier
        let identifier = response.notification.request.identifier
        let reminderPrefix = "bookadink.game.reminder."
        if identifier.hasPrefix(reminderPrefix),
           let gameID = UUID(uuidString: String(identifier.dropFirst(reminderPrefix.count))) {
            NotificationCenter.default.post(
                name: .bookADinkNotificationGameTapped,
                object: DeepLink.gameURL(id: gameID)
            )
        }
    }

    /// Show notification banners even while the app is foregrounded.
    /// Also triggers a membership refresh for membership-related notifications so views update immediately.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String {
            let membershipTypes = ["membership_approved", "membership_rejected", "membership_removed",
                                   "admin_promoted", "membership_request_received"]
            if membershipTypes.contains(type) {
                NotificationCenter.default.post(name: .bookADinkMembershipStatusChanged, object: nil)
            }
            if type == "waitlist_promoted", let gameIDString = userInfo["reference_id"] as? String {
                NotificationCenter.default.post(name: .bookADinkWaitlistPromoted, object: gameIDString)
            }
            if type == "booking_cancelled" {
                let gameIDString = userInfo["reference_id"] as? String
                NotificationCenter.default.post(name: .bookADinkBookingCancelled, object: gameIDString)
            }
        }
        completionHandler([.banner, .sound])
    }
}

@main
struct BookADinkApp: App {
    @UIApplicationDelegateAdaptor(BookADinkAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = LocationManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        StripeAPI.defaultPublishableKey = SupabaseConfig.stripePublishableKey
        // Mix with background audio (e.g. music) instead of interrupting it.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.scheduleStore)
                .environmentObject(locationManager)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .bookADinkNotificationGameTapped)) { note in
                    if let url = note.object as? URL {
                        appState.handleDeepLink(url)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .bookADinkMembershipStatusChanged)) { _ in
                    Task { await appState.refreshMemberships() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .bookADinkWaitlistPromoted)) { _ in
                    // Push arrived (foreground or background→foreground tap):
                    // refresh bookings so the pending_payment CTA surfaces immediately
                    // regardless of which screen the user is on.
                    Task { await appState.refreshBookings(silent: true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .bookADinkBookingCancelled)) { note in
                    // Admin removed the player from a game. Refresh bookings so the CTA
                    // flips back to "Book"; if we can locate the game, refresh attendees too.
                    let gameIDString = note.object as? String
                    Task {
                        await appState.refreshBookings(silent: true)
                        if let s = gameIDString, let gameID = UUID(uuidString: s) {
                            let cachedGame =
                                appState.bookings.first(where: { $0.booking.gameID == gameID })?.game
                                ?? appState.allUpcomingGames.first(where: { $0.id == gameID })
                                ?? appState.gamesByClubID.values.flatMap({ $0 }).first(where: { $0.id == gameID })
                            if let g = cachedGame {
                                await appState.refreshAttendees(for: g)
                            }
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            // Refresh notifications on foreground so badge counts and indicators
                            // stay in sync without requiring manual pull-to-refresh.
                            await appState.refreshNotifications()
                            // Belt-and-braces: catch up on bookings in case a push was missed
                            // while backgrounded (e.g. silent admin cancellation).
                            await appState.refreshBookings(silent: true)
                            for clubID in appState.entitlementsByClubID.keys {
                                await appState.fetchClubEntitlements(for: clubID)
                            }
                            // Re-fire APNs registration on every foreground when authenticated +
                            // already authorized. Idempotent — Apple returns the same token if
                            // unchanged. This guarantees iPad / second-device tokens land in
                            // push_tokens after a relaunch even though the per-launch guard in
                            // prepareClubChatPushNotificationsIfNeeded would otherwise short-circuit.
                            if appState.authState == .signedIn {
                                await appState.ensureRemotePushRegistrationIfAuthorized()
                            }
                        }
                    }
                }
        }
    }
}
