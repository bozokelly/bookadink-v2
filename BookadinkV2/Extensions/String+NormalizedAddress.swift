import Foundation

extension String {
    /// Cleans and normalises a free-text address for consistent display.
    /// - Trims whitespace/newlines and collapses internal gaps
    /// - Title-cases if the string is fully lowercase (e.g. "murry street" → "Murry Street")
    /// - Truncates to 40 characters with "…" to prevent wrapping
    func normalizedAddress() -> String {
        let trimmed = self
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !trimmed.isEmpty else { return trimmed }

        let result = trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
        return result.count > 40 ? String(result.prefix(37)) + "…" : result
    }
}
