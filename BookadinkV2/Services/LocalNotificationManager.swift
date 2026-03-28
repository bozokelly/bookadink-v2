import Foundation
import UserNotifications

enum LocalNotificationError: LocalizedError {
    case permissionDenied
    case gameAlreadyStarted
    case gameStartingTooSoon
    case schedulingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Notifications are disabled for Book a dink. Enable them in Settings."
        case .gameAlreadyStarted:
            return "This game has already started."
        case .gameStartingTooSoon:
            return "This game starts too soon to schedule a reminder."
        case let .schedulingFailed(message):
            return "Could not schedule reminder: \(message)"
        }
    }
}

final class LocalNotificationManager {
    static let shared = LocalNotificationManager()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func scheduleGameReminder(for game: Game, clubName: String = "") async throws -> Date {
        let now = Date()
        guard game.dateTime > now else { throw LocalNotificationError.gameAlreadyStarted }

        try await ensurePermission()

        let fireDate = try reminderDate(for: game, now: now)

        let locationSuffix = Self.locationSuffix(venueName: game.venueName, clubName: clubName)

        let content = UNMutableNotificationContent()
        content.title = "Upcoming Game"
        content.body = "\(game.title) starts \(game.dateTime.formatted(date: .omitted, time: .shortened))\(locationSuffix)."
        content.sound = .default
        // game_id in userInfo enables deep-link routing when the notification is tapped
        content.userInfo = ["game_id": game.id.uuidString]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: reminderIdentifier(for: game.id),
            content: content,
            trigger: trigger
        )

        try await addRequest(request)
        return fireDate
    }

    func cancelGameReminder(gameID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier(for: gameID)])
    }

    func scheduleClubNewsActivityNotification(id: String, title: String, body: String) async {
        do {
            try await ensurePermission()
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "bookadink.clubnews.\(id)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try await addRequest(request)
        } catch {
            // Non-fatal: club news refresh should continue even if notifications are disabled.
        }
    }

    private func reminderIdentifier(for gameID: UUID) -> String {
        "bookadink.game.reminder.\(gameID.uuidString)"
    }

    private func reminderDate(for game: Game, now: Date) throws -> Date {
        let oneHourBefore = game.dateTime.addingTimeInterval(-3600)
        if oneHourBefore.timeIntervalSince(now) >= 60 {
            return oneHourBefore
        }

        let tenMinutesBefore = game.dateTime.addingTimeInterval(-600)
        if tenMinutesBefore.timeIntervalSince(now) >= 60 {
            return tenMinutesBefore
        }

        let oneMinuteFromNow = now.addingTimeInterval(60)
        if game.dateTime.timeIntervalSince(oneMinuteFromNow) >= 0 {
            return oneMinuteFromNow
        }

        throw LocalNotificationError.gameStartingTooSoon
    }

    private func ensurePermission() async throws {
        let settings = await loadNotificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            let granted = try await requestAuthorization()
            if !granted { throw LocalNotificationError.permissionDenied }
        case .denied:
            throw LocalNotificationError.permissionDenied
        @unknown default:
            throw LocalNotificationError.permissionDenied
        }
    }

    private func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: LocalNotificationError.schedulingFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func loadNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { (continuation: CheckedContinuation<UNNotificationSettings, Never>) in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    /// Canonical location suffix for game notification bodies.
    ///
    /// Rule (mirrors UI and Edge Function logic):
    ///   venue name → club name → omit
    ///
    /// Returns " at {name}" or "" — never placeholder text.
    static func locationSuffix(venueName: String?, clubName: String) -> String {
        let venue = venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name  = venue.isEmpty ? clubName.trimmingCharacters(in: .whitespacesAndNewlines) : venue
        return name.isEmpty ? "" : " at \(name)"
    }

    private func addRequest(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: LocalNotificationError.schedulingFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
