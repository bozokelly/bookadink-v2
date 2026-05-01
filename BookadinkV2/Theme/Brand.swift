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
    static let accentGreen      = Color(hex: "C8FF3D")

    // Tonal card palette — base and deep ends of the diagonal gradient used on game/club cards
    static let tonalTanBase      = Color(hex: "B79F86")
    static let tonalTanDeep      = Color(hex: "7A6451")
    static let tonalNavyBase     = Color(hex: "2A3A52")
    static let tonalNavyDeep     = Color(hex: "16213A")
    static let tonalCharcoalBase = Color(hex: "3A3D40")
    static let tonalCharcoalDeep = Color(hex: "1F2123")
    static let tonalForestBase   = Color(hex: "1F3D2C")
    static let tonalForestDeep   = Color(hex: "0E2418")
    static let tonalRoseBase     = Color(hex: "9A6E73")
    static let tonalRoseDeep     = Color(hex: "5E3F44")
    static let tonalSlateBase    = Color(hex: "4A5560")
    static let tonalSlateDeep    = Color(hex: "2A323B")

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

    // ── Sport Blend palette — settings & account screens ─────────────────────
    static let sportBg        = Color(hex: "FBFAF7")   // cream page background
    static let sportBgAlt     = Color(hex: "F4F2EC")   // subtle elevation / input bg
    static let sportBorder    = Color(hex: "EDEAE0")   // hairline dividers
    static let sportPop       = Color(hex: "D4FF3A")   // electric lime — energy moments only
    static let sportStatement = Color(hex: "1B1A17")   // dark statement surface (hero card)
    static let sportWarn      = Color(hex: "C44545")   // destructive / paused state
    static let sportCream     = Color(hex: "F4F1EA")   // text on dark sport surfaces
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
