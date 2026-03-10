import SwiftUI

enum Brand {
    // Core palette
    static let brandPrimary = Color(hex: "4F6FA3")      // Slate Blue (requested)
    static let brandPrimaryDark = Color(hex: "425E8B")
    static let brandPrimaryDarker = Color(hex: "334C74")
    static let brandPrimaryLight = Color(hex: "6F8FC0")
    static let powderBlue = Color(hex: "98C1D9")
    static let lightCyan = Color(hex: "E0FBFC")

    static let emeraldAction = Color(hex: "2ECC71")
    static let softOrangeAccent = Color(hex: "FFA500")
    static let errorRed = Color(hex: "E85C5C")

    // Frosted surfaces
    static let frostedSurface = Color.white.opacity(0.20)
    static let frostedSurfaceStrong = Color.white.opacity(0.26)
    static let frostedSurfaceSoft = Color.white.opacity(0.16)
    static let frostedBorder = Color.white.opacity(0.18)

    // Backward-compatible aliases used across the app (progressively migrating).
    static let slateBlue = brandPrimary
    static let slateBlueLight = brandPrimaryLight
    static let slateBlueDark = brandPrimaryDarker
    static let coralBlaze = errorRed
    static let spicyOrange = softOrangeAccent
    static let pineTeal = brandPrimaryDark
    static let rosyTaupe = powderBlue

    static let ink = brandPrimaryDarker
    static let cream = lightCyan
    static let softCard = lightCyan.opacity(0.72)
    static let mutedText = brandPrimaryLight

    static let pageGradient = LinearGradient(
        colors: [
            brandPrimaryDarker,
            brandPrimaryDark,
            brandPrimary,
            brandPrimaryLight.opacity(0.9)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let accentGradient = LinearGradient(
        colors: [emeraldAction, brandPrimaryLight],
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
