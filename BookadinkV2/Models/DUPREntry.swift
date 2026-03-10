import Foundation

struct DUPREntry: Identifiable, Codable {
    let id: UUID
    let rating: Double
    let recordedAt: Date
    let context: String?

    init(id: UUID = UUID(), rating: Double, recordedAt: Date = Date(), context: String? = nil) {
        self.id = id
        self.rating = rating
        self.recordedAt = recordedAt
        self.context = context
    }
}
