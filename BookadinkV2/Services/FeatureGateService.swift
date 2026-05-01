// FeatureGateService.swift
// Phase 4 Part 2A — Scaffold only. No UI wiring. No gates active yet.
//
// DENY BY DEFAULT: every method returns .blocked when entitlements is nil.
// The app must never fall back to .allowed on missing or failed entitlement data.
//
// Usage (future, not wired yet):
//   let gate = FeatureGateService.canAcceptPayments(appState.entitlementsByClubID[club.id])
//   if case .blocked(let reason) = gate { /* show upgrade prompt */ }
//
// Rules:
//   - Never check planTier, subscription status, or any Stripe field here.
//   - Read only the explicit feature columns from ClubEntitlements.
//   - All entitlement logic lives in derive_club_entitlements() (PostgreSQL).
//     This service only reads the output.

enum GateResult {
    case allowed
    case blocked(reason: String)
}

struct FeatureGateService {

    // MARK: - Games

    /// Whether the club can create a new active/upcoming game.
    /// `currentActiveGameCount` = count of games that are upcoming or in progress.
    static func canCreateGame(
        _ entitlements: ClubEntitlements?,
        currentActiveGameCount: Int
    ) -> GateResult {
        guard let e = entitlements else {
            return .blocked(reason: "Plan entitlements unavailable.")
        }
        if e.maxActiveGames == -1 { return .allowed }
        guard currentActiveGameCount < e.maxActiveGames else {
            return .blocked(reason: "Active game limit reached (\(e.maxActiveGames)). Upgrade your plan to add more games.")
        }
        return .allowed
    }

    // MARK: - Payments

    /// Whether the club can accept payments via Stripe Connect.
    static func canAcceptPayments(_ entitlements: ClubEntitlements?) -> GateResult {
        guard let e = entitlements else {
            return .blocked(reason: "Plan entitlements unavailable.")
        }
        return e.canAcceptPayments
            ? .allowed
            : .blocked(reason: "Accepting payments requires a Starter or Pro plan.")
    }

    // MARK: - Members

    /// Whether the club can approve a new member.
    /// `currentMemberCount` = count of currently approved members.
    static func canAddMember(
        _ entitlements: ClubEntitlements?,
        currentMemberCount: Int
    ) -> GateResult {
        guard let e = entitlements else {
            return .blocked(reason: "Plan entitlements unavailable.")
        }
        if e.maxMembers == -1 { return .allowed }
        guard currentMemberCount < e.maxMembers else {
            return .blocked(reason: "Member limit reached (\(e.maxMembers)). Upgrade your plan to accept more members.")
        }
        return .allowed
    }

    // MARK: - Analytics

    /// Whether the club can access analytics features.
    static func canAccessAnalytics(_ entitlements: ClubEntitlements?) -> GateResult {
        guard let e = entitlements else {
            return .blocked(reason: "Plan entitlements unavailable.")
        }
        return e.analyticsAccess
            ? .allowed
            : .blocked(reason: "Analytics requires a Pro plan.")
    }

    // MARK: - Pro Scheduling Features

    /// Whether the club can create recurring weekly game series.
    static func canUseRecurringGames(_ entitlements: ClubEntitlements?) -> GateResult {
        guard let e = entitlements else {
            return .blocked(reason: "Plan entitlements unavailable.")
        }
        return e.canUseRecurringGames
            ? .allowed
            : .blocked(reason: "Recurring games require a Pro plan.")
    }

    /// Whether the club can schedule a delayed publish date for a game.
    static func canUseDelayedPublishing(_ entitlements: ClubEntitlements?) -> GateResult {
        guard let e = entitlements else {
            return .blocked(reason: "Plan entitlements unavailable.")
        }
        return e.canUseDelayedPublishing
            ? .allowed
            : .blocked(reason: "Delayed publishing requires a Pro plan.")
    }
}
