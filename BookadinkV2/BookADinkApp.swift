
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

        // booking-confirmed edge function — sends game_id directly
        if let gameIDString = userInfo["game_id"] as? String,
           let gameID = UUID(uuidString: gameIDString) {
            NotificationCenter.default.post(
                name: .bookADinkNotificationGameTapped,
                object: DeepLink.gameURL(id: gameID)
            )
            return
        }

        // notify edge function — sends type + reference_id
        if let type = userInfo["type"] as? String {
            let referenceID = (userInfo["reference_id"] as? String).flatMap(UUID.init)
            switch type {
            case "waitlist_promoted", "booking_waitlisted", "booking_confirmed":
                if let id = referenceID {
                    if type == "waitlist_promoted" {
                        NotificationCenter.default.post(name: .bookADinkWaitlistPromoted, object: id.uuidString)
                    }
                    NotificationCenter.default.post(
                        name: .bookADinkNotificationGameTapped,
                        object: DeepLink.gameURL(id: id)
                    )
                }
                return
            case "membership_approved", "admin_promoted", "membership_request_received":
                NotificationCenter.default.post(name: .bookADinkMembershipStatusChanged, object: nil)
                if let id = referenceID {
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
                break
            }
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
        }
        completionHandler([.banner, .sound])
    }
}

@main
struct BookADinkApp: App {
    @UIApplicationDelegateAdaptor(BookADinkAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = LocationManager()

    init() {
        StripeAPI.defaultPublishableKey = SupabaseConfig.stripePublishableKey
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
        }
    }
}
