import Foundation

/// Owns all local reminder and calendar-export state for booked games.
///
/// Extracted from AppState to reduce unnecessary re-renders: only views that
/// directly observe GameScheduleStore (GameDetailView, BookingsListView) will
/// re-render when reminder or calendar state changes — not the entire view tree.
///
/// Inject alongside AppState:
///   .environmentObject(appState)
///   .environmentObject(appState.scheduleStore)
@MainActor
final class GameScheduleStore: ObservableObject {

    private enum StorageKeys {
        static let reminderGameIDs        = "bookadink.reminder.gameIDs"
        static let calendarGameIDs        = "bookadink.calendar.gameIDs"
        static let calendarEventIDsByGameID = "bookadink.calendar.eventIDsByGameID"
    }

    @Published var reminderGameIDs: Set<UUID> = []
    @Published var calendarGameIDs: Set<UUID> = []
    @Published var exportingCalendarGameIDs: Set<UUID> = []

    /// Non-published: maps game ID → native calendar event ID for removal.
    var calendarEventIDsByGameID: [UUID: String] = [:]

    init() {
        restoreReminderGameIDs()
        restoreCalendarGameIDs()
    }

    // MARK: - Query

    func hasReminder(for game: Game) -> Bool {
        reminderGameIDs.contains(game.id)
    }

    func hasCalendarExport(for game: Game) -> Bool {
        calendarGameIDs.contains(game.id)
    }

    func isExportingCalendar(for game: Game) -> Bool {
        exportingCalendarGameIDs.contains(game.id)
    }

    // MARK: - Sign-out cleanup

    /// Cancels all scheduled reminders and clears persisted state.
    func clearAll() {
        for gameID in reminderGameIDs {
            LocalNotificationManager.shared.cancelGameReminder(gameID: gameID)
        }
        reminderGameIDs = []
        calendarGameIDs = []
        exportingCalendarGameIDs = []
        calendarEventIDsByGameID = [:]
        persistReminderGameIDs()
        persistCalendarGameIDs()
    }

    // MARK: - Persistence

    func persistReminderGameIDs() {
        let ids = reminderGameIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(ids, forKey: StorageKeys.reminderGameIDs)
    }

    func persistCalendarGameIDs() {
        let ids = calendarGameIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(ids, forKey: StorageKeys.calendarGameIDs)
        let rawMap = Dictionary(uniqueKeysWithValues: calendarEventIDsByGameID.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(rawMap, forKey: StorageKeys.calendarEventIDsByGameID)
    }

    private func restoreReminderGameIDs() {
        guard let rawIDs = UserDefaults.standard.array(forKey: StorageKeys.reminderGameIDs) as? [String] else { return }
        reminderGameIDs = Set(rawIDs.compactMap(UUID.init(uuidString:)))
    }

    private func restoreCalendarGameIDs() {
        if let rawMap = UserDefaults.standard.dictionary(forKey: StorageKeys.calendarEventIDsByGameID) as? [String: String] {
            calendarEventIDsByGameID = rawMap.reduce(into: [:]) { partial, entry in
                if let id = UUID(uuidString: entry.key) {
                    partial[id] = entry.value
                }
            }
            calendarGameIDs = Set(calendarEventIDsByGameID.keys)
        } else if let rawIDs = UserDefaults.standard.array(forKey: StorageKeys.calendarGameIDs) as? [String] {
            // Backward compatibility for installs before event IDs were persisted.
            calendarGameIDs = Set(rawIDs.compactMap(UUID.init(uuidString:)))
            calendarEventIDsByGameID = [:]
        }
    }
}
