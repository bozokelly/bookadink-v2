
import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let bookADinkDidRegisterForRemoteNotifications = Notification.Name("bookadink.apns.registered")
    static let bookADinkDidFailRemoteNotificationsRegistration = Notification.Name("bookadink.apns.failed")
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
}

@main
struct BookADinkApp: App {
    @UIApplicationDelegateAdaptor(BookADinkAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.scheduleStore)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
        }
    }
}
