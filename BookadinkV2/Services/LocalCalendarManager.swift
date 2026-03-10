import EventKit
import Foundation

enum LocalCalendarError: LocalizedError {
    case permissionDenied
    case restricted
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access is disabled for Book a dink. Enable it in Settings."
        case .restricted:
            return "Calendar access is restricted on this device."
        case let .saveFailed(message):
            return "Could not add event to calendar: \(message)"
        }
    }
}

final class LocalCalendarManager {
    static let shared = LocalCalendarManager()

    private let store = EKEventStore()

    private init() {}

    func addGameToCalendar(game: Game, clubName: String?) async throws -> String {
        try await ensurePermission()

        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        event.title = game.title
        event.startDate = game.dateTime
        event.endDate = game.dateTime.addingTimeInterval(TimeInterval(max(game.durationMinutes, 30) * 60))
        event.location = formattedLocation(game: game, clubName: clubName)
        event.notes = formattedNotes(game: game, clubName: clubName)

        do {
            try store.save(event, span: .thisEvent)
            guard let identifier = event.eventIdentifier else {
                throw LocalCalendarError.saveFailed("Missing calendar event identifier.")
            }
            return identifier
        } catch {
            throw LocalCalendarError.saveFailed(error.localizedDescription)
        }
    }

    func removeGameFromCalendar(eventIdentifier: String) async throws -> Bool {
        try await ensurePermission()

        guard let event = store.event(withIdentifier: eventIdentifier) else {
            return false
        }

        do {
            try store.remove(event, span: .thisEvent)
            return true
        } catch {
            throw LocalCalendarError.saveFailed(error.localizedDescription)
        }
    }

    private func formattedLocation(game: Game, clubName: String?) -> String {
        let club = clubName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let venue = game.displayLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !club.isEmpty, !venue.isEmpty {
            return "\(club) • \(venue)"
        }
        if !club.isEmpty { return club }
        return venue
    }

    private func formattedNotes(game: Game, clubName: String?) -> String {
        var lines: [String] = []
        let formatText = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
        let skillText = game.skillLevel.replacingOccurrences(of: "_", with: " ").capitalized
        if let clubName, !clubName.isEmpty {
            lines.append("Club: \(clubName)")
        }
        lines.append("Format: \(formatText)")
        lines.append("Skill: \(skillText)")
        if let fee = game.feeAmount, fee > 0 {
            lines.append("Fee: \(game.feeCurrency ?? "USD") \(String(format: "%.2f", fee))")
        } else {
            lines.append("Fee: Free")
        }
        if let description = game.description, !description.isEmpty {
            lines.append("")
            lines.append(description)
        }
        if let notes = game.notes, !notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    private func ensurePermission() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            if status == .fullAccess || status == .writeOnly {
                return
            }
        } else {
            if status == .authorized {
                return
            }
        }

        if status == .notDetermined {
            let granted = try await requestCalendarAccess()
            if !granted { throw LocalCalendarError.permissionDenied }
            return
        }

        if status == .denied {
            throw LocalCalendarError.permissionDenied
        }

        if status == .restricted {
            throw LocalCalendarError.restricted
        }

        throw LocalCalendarError.permissionDenied
    }

    private func requestCalendarAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            if #available(iOS 17.0, *) {
                store.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: LocalCalendarError.saveFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            } else {
                store.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: LocalCalendarError.saveFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }
}
