import SwiftUI

// MARK: - Shared gradient palette definitions

enum AvatarGradients {
    struct Entry: Identifiable {
        let key: String
        let name: String
        let start: String   // hex without #
        let end: String
        var id: String { key }

        var gradient: LinearGradient {
            LinearGradient(
                colors: [Color(hex: start), Color(hex: end)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // ── Compile-time static palettes ──────────────────────────────────────────
    // These mirror the avatar_palettes DB table exactly.
    // The DB is the source of truth; these are the compile-time fallback/offline cache.

    /// Player palette — Neon Accent Series (vibrant, white-text safe)
    static let neonAccent: [Entry] = [
        Entry(key: "neon_lime",     name: "Neon Lime",    start: "80FF00", end: "3A7D00"),
        Entry(key: "electric_blue", name: "Electric Blue", start: "0066FF", end: "00A3FF"),
        Entry(key: "neon_violet",   name: "Neon Violet",  start: "7B2DFF", end: "B066FF"),
        Entry(key: "sunset_ember",  name: "Sunset Ember", start: "FF5A36", end: "FF8A3D"),
        Entry(key: "aqua_pulse",    name: "Aqua Pulse",   start: "00C2A8", end: "007D73"),
        Entry(key: "hot_magenta",   name: "Hot Magenta",  start: "D726FF", end: "7B2DFF"),
    ]

    /// Club palette — Soft Luxury Series (refined, white-text safe)
    static let softLuxury: [Entry] = [
        Entry(key: "sandstone",     name: "Sandstone",     start: "C7A97A", end: "8F6F42"),
        Entry(key: "sage",          name: "Sage",          start: "7E9F88", end: "51755F"),
        Entry(key: "frost_blue",    name: "Frost Blue",    start: "4B6FA5", end: "2E4E7A"),
        Entry(key: "dusty_rose",    name: "Dusty Rose",    start: "B76A7D", end: "8A4356"),
        Entry(key: "silver_mist",   name: "Silver Mist",   start: "6B7280", end: "374152"),
        Entry(key: "soft_lavender", name: "Soft Lavender", start: "7B68AC", end: "4A3C7A"),
    ]

    /// High-contrast dark palette — platform-neutral fallback when no DB key is stored
    static let premiumDark: [Entry] = [
        Entry(key: "midnight_navy",  name: "Midnight Navy",  start: "0B1F3A", end: "1E3A5F"),
        Entry(key: "deep_forest",    name: "Deep Forest",    start: "0F3D2E", end: "1E5A45"),
        Entry(key: "plum_noir",      name: "Plum Noir",      start: "2B1638", end: "4A2A5E"),
        Entry(key: "espresso",       name: "Espresso",       start: "3A2418", end: "5C3A28"),
        Entry(key: "obsidian",       name: "Obsidian",       start: "111111", end: "2A2A2A"),
        Entry(key: "graphite",       name: "Graphite",       start: "1E1E1E", end: "3B3B3B"),
    ]

    // ── Live DB cache ─────────────────────────────────────────────────────────
    // Populated by AppState.loadAvatarPalettes() after the first successful DB fetch.
    // Keyed by palette_key. Empty until the first fetch completes (static arrays serve as fallback).
    static var liveCache: [String: Entry] = [:]

    // ── Resolution ────────────────────────────────────────────────────────────

    /// Resolves a palette key to its gradient.
    /// Priority: live DB cache → compile-time static arrays → Midnight Navy default.
    /// All platforms implement the same rule, guaranteeing identical output.
    static func resolveGradient(forKey key: String?) -> LinearGradient {
        guard let key, !key.isEmpty else { return defaultGradient }
        if let cached = liveCache[key] { return cached.gradient }
        return neonGradient(forKey: key)
            ?? luxuryGradient(forKey: key)
            ?? darkGradient(forKey: key)
            ?? defaultGradient
    }

    /// Midnight Navy — the server-authoritative default (is_default = TRUE in avatar_palettes).
    static var defaultGradient: LinearGradient { premiumDark[0].gradient }

    static func neonGradient(forKey key: String?) -> LinearGradient? {
        neonAccent.first { $0.key == key }?.gradient
    }

    static func luxuryGradient(forKey key: String?) -> LinearGradient? {
        softLuxury.first { $0.key == key }?.gradient
    }

    static func darkGradient(forKey key: String?) -> LinearGradient? {
        premiumDark.first { $0.key == key }?.gradient
    }
}

// MARK: - Player avatar badge

/// Initials-based avatar badge used for user profiles throughout the app.
struct ProfileAvatarBadge: View {
    let initials: String
    var colorKey: String? = nil     // nil → Midnight Navy (server default)

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AvatarGradients.resolveGradient(forKey: colorKey))
            .overlay(
                Text(initials)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}
