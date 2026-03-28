import SwiftUI

enum Brand {
    // ── Core premium off-white palette ────────────────────────────────────────
    static let appBackground    = Color(hex: "F7F7F4")   // warm off-white screen background
    static let cardBackground   = Color.white             // card surface
    static let secondarySurface = Color(hex: "F1F1EC")   // secondary / hover surface
    static let primaryText      = Color(hex: "111111")   // near-black heading + body
    static let secondaryText    = Color(hex: "6B7280")   // muted grey metadata
    static let tertiaryText     = Color(hex: "9CA3AF")   // lighter muted labels
    static let dividerColor     = Color(hex: "E7E5E4")   // dividers
    static let darkOutline      = Color(hex: "111111")   // strong black outline
    static let softOutline      = Color(hex: "D6D3D1")   // subtle neutral outline

    // Signature neon-lime accent — 5–10% usage only (dots, underlines, micro-accents)
    static let accentGreen      = Color(hex: "C3FF45")

    // ── Preserved legacy token names (updated to neutral values) ────────────
    // These keep all existing call sites compiling while shifting the palette.
    static let brandPrimary       = primaryText
    static let brandPrimaryDark   = primaryText
    static let brandPrimaryDarker = primaryText
    static let brandPrimaryLight  = secondaryText
    static let powderBlue         = softOutline
    static let lightCyan          = appBackground

    // Form / destructive CTA buttons (EditProfileSheet, etc.) stay green.
    static let emeraldAction      = Color(hex: "2ECC71")
    static let softOrangeAccent   = Color(hex: "FFA500")
    static let errorRed           = Color(hex: "E85C5C")

    // ── Frosted surface aliases → solid clean surfaces ────────────────────────
    static let frostedSurface       = cardBackground
    static let frostedSurfaceStrong = cardBackground
    static let frostedSurfaceSoft   = secondarySurface
    static let frostedBorder        = softOutline

    // ── Semantic aliases (consumed throughout the app) ────────────────────────
    static let slateBlue      = primaryText
    static let slateBlueLight = secondaryText
    static let slateBlueDark  = primaryText
    static let coralBlaze     = errorRed
    static let spicyOrange    = softOrangeAccent
    static let pineTeal       = primaryText      // was teal → now clean dark neutral
    static let rosyTaupe      = softOutline

    static let ink       = primaryText      // was dark navy → near-black
    static let cream     = appBackground    // was light cyan → warm off-white
    static let softCard  = secondarySurface
    static let mutedText = secondaryText    // was light blue → muted grey

    // ── Page background (flat off-white — no blue gradient) ──────────────────
    static let pageGradient = LinearGradient(
        colors: [appBackground, appBackground],
        startPoint: .top,
        endPoint: .bottom
    )

    // Kept as a token for any future use; now neutral dark-to-secondary
    static let accentGradient = LinearGradient(
        colors: [primaryText, secondaryText],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum AppCopy {
    static func friendlyError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("jwt expired") {
            return "Your session expired. Please try again."
        }
        if lower.contains("aps-environment") || lower.contains("did not register for remote notifications") {
            return "Push notifications are not available on this build yet. Chat alerts in-app and local reminders still work."
        }
        if lower.contains("row-level security") || lower.contains("unauthorized") {
            return "You do not have permission for this action."
        }
        if lower.contains("network") || lower.contains("timed out") {
            return "Network issue. Please try again."
        }
        if lower.contains("invalid input value for enum") {
            return "That option is not supported yet. Please refresh and try again."
        }
        if lower.contains("supabase request failed") {
            return "Something went wrong while loading data. Please try again."
        }
        return raw.count > 140 ? "Something went wrong. Please try again." : raw
    }
}
