// ClubUpgradePaywallView.swift
// Premium upgrade paywall — shown when a club owner taps a feature locked by their current plan.
//
// Architecture:
//   - LockedFeature enum contextualises the header and feature highlights.
//   - UpgradePlan enum drives the plan cards and CTA buttons.
//   - Stripe PaymentSheet is presented from the topmost VC, same pattern as ClubOwnerSheets.
//   - On payment success: polls DB for active subscription (up to ~30s), then refreshes
//     entitlements and shows a success screen. Dismiss only happens after confirmation.

import SwiftUI
import StripePaymentSheet

// MARK: - LockedFeature

enum LockedFeature: String, Identifiable {
    case analytics
    case payments
    case gameLimit
    case memberLimit
    case recurringGames
    case scheduledPublishing
    /// Generic "view / change plan" entry — used from Settings → Plan & Billing.
    case managePlan

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .analytics:           return "chart.bar.fill"
        case .payments:            return "creditcard.fill"
        case .gameLimit:           return "calendar.badge.plus"
        case .memberLimit:         return "person.2.fill"
        case .recurringGames:      return "repeat"
        case .scheduledPublishing: return "eye.slash.fill"
        case .managePlan:          return "sparkles"
        }
    }

    var title: String {
        switch self {
        case .analytics:           return "Unlock Analytics"
        case .payments:            return "Accept Payments"
        case .gameLimit:           return "Create More Games"
        case .memberLimit:         return "Grow Your Club"
        case .recurringGames:      return "Recurring Games"
        case .scheduledPublishing: return "Scheduled Publishing"
        case .managePlan:          return "Choose Your Plan"
        }
    }

    var subtitle: String {
        switch self {
        case .analytics:           return "Revenue, attendance, and fill rate insights for your club."
        case .payments:            return "Collect booking fees and get paid directly to your bank."
        case .gameLimit:           return "Schedule more games and keep your calendar full."
        case .memberLimit:         return "Accept more members and grow your community."
        case .recurringGames:      return "Create a weekly series once and let the calendar fill itself."
        case .scheduledPublishing: return "Control exactly when a game goes live to your members."
        case .managePlan:          return "Pick the plan that fits how your club runs."
        }
    }

    func highlights(limits: [String: PlanTierLimits]) -> [PaywallHighlight] {
        switch self {
        case .analytics:
            return [
                PaywallHighlight(icon: "dollarsign.circle.fill",    text: "Revenue breakdown by period"),
                PaywallHighlight(icon: "chart.line.uptrend.xyaxis", text: "Booking fill rate trends"),
                PaywallHighlight(icon: "person.2.fill",             text: "Member growth over time"),
                PaywallHighlight(icon: "arrow.down.doc.fill",       text: "Exportable reports (coming soon)"),
            ]
        case .payments:
            return [
                PaywallHighlight(icon: "creditcard.fill",           text: "Card and Apple Pay at booking"),
                PaywallHighlight(icon: "arrow.up.circle.fill",      text: "Payouts to your Stripe account"),
                PaywallHighlight(icon: "percent",                   text: "Low 10% platform fee per booking"),
                PaywallHighlight(icon: "lock.shield.fill",          text: "Fraud protection via Stripe"),
            ]
        case .gameLimit:
            let starterGamesLabel: String
            if let n = limits["starter"]?.maxActiveGames {
                starterGamesLabel = n == -1 ? "Unlimited active games on Starter" : "Up to \(n) active games on Starter"
            } else {
                starterGamesLabel = "More active games on Starter"
            }
            let proGamesLabel: String
            if let n = limits["pro"]?.maxActiveGames {
                proGamesLabel = n == -1 ? "Unlimited games on Pro" : "Up to \(n) games on Pro"
            } else {
                proGamesLabel = "Unlimited games on Pro"
            }
            var gameHighlights: [PaywallHighlight] = [
                PaywallHighlight(icon: "calendar.badge.plus", text: starterGamesLabel),
                PaywallHighlight(icon: "infinity",            text: proGamesLabel),
            ]
            if limits["pro"]?.canUseRecurringGames == true {
                gameHighlights.append(PaywallHighlight(icon: "repeat", text: "Recurring weekly series (Pro)"))
            }
            if limits["pro"]?.canUseDelayedPublishing == true {
                gameHighlights.append(PaywallHighlight(icon: "eye.slash.fill", text: "Delayed publishing (Pro)"))
            }
            return gameHighlights
        case .memberLimit:
            let starterMembersLabel: String
            if let n = limits["starter"]?.maxMembers {
                starterMembersLabel = n == -1 ? "Unlimited members on Starter" : "Up to \(n) members on Starter"
            } else {
                starterMembersLabel = "More members on Starter"
            }
            let proMembersLabel: String
            if let n = limits["pro"]?.maxMembers {
                proMembersLabel = n == -1 ? "Unlimited members on Pro" : "Up to \(n) members on Pro"
            } else {
                proMembersLabel = "Unlimited members on Pro"
            }
            return [
                PaywallHighlight(icon: "person.fill.badge.plus", text: starterMembersLabel),
                PaywallHighlight(icon: "infinity",               text: proMembersLabel),
                PaywallHighlight(icon: "checkmark.seal.fill",    text: "Approval-based membership control"),
                PaywallHighlight(icon: "bell.fill",              text: "Notify all members of new games"),
            ]
        case .recurringGames:
            let proGamesLabel: String
            if let n = limits["pro"]?.maxActiveGames {
                proGamesLabel = n == -1 ? "Unlimited active games included" : "Up to \(n) active games"
            } else {
                proGamesLabel = "Unlimited active games"
            }
            return [
                PaywallHighlight(icon: "repeat",              text: "Set up a weekly series in one step"),
                PaywallHighlight(icon: "calendar.badge.plus", text: "Up to 12 recurring occurrences"),
                PaywallHighlight(icon: "infinity",            text: proGamesLabel),
                PaywallHighlight(icon: "eye.slash.fill",      text: "Delayed publishing included"),
            ]
        case .scheduledPublishing:
            return [
                PaywallHighlight(icon: "eye.slash.fill",      text: "Control when a game goes public"),
                PaywallHighlight(icon: "clock.fill",          text: "Set a future publish date and time"),
                PaywallHighlight(icon: "person.fill.checkmark", text: "Build anticipation before doors open"),
                PaywallHighlight(icon: "repeat",              text: "Recurring weekly series included"),
            ]
        case .managePlan:
            var bullets: [PaywallHighlight] = []
            if let n = limits["pro"]?.maxActiveGames {
                bullets.append(PaywallHighlight(icon: "infinity", text: n == -1 ? "Unlimited active games on Pro" : "Up to \(n) active games on Pro"))
            }
            if limits["pro"]?.canAcceptPayments == true {
                bullets.append(PaywallHighlight(icon: "creditcard.fill", text: "Accept paid bookings"))
            }
            if limits["pro"]?.analyticsAccess == true {
                bullets.append(PaywallHighlight(icon: "chart.bar.fill", text: "Analytics dashboard"))
            }
            if limits["pro"]?.canUseRecurringGames == true {
                bullets.append(PaywallHighlight(icon: "repeat", text: "Recurring weekly series"))
            }
            if limits["pro"]?.canUseDelayedPublishing == true {
                bullets.append(PaywallHighlight(icon: "eye.slash.fill", text: "Scheduled publishing"))
            }
            return bullets
        }
    }
}

struct PaywallHighlight: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

// MARK: - UpgradePlan

enum UpgradePlan: String, CaseIterable {
    case free    = "free"
    case starter = "starter"
    case pro     = "pro"

    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .starter: return "Starter"
        case .pro:     return "Pro"
        }
    }

    func displayPrice(plans: [SubscriptionPlan]) -> String {
        switch self {
        case .free:    return "Free forever"
        case .starter: return plans.first(where: { $0.planID == "starter" }).map { "\($0.displayPrice) · recurring" } ?? "Loading…"
        case .pro:     return plans.first(where: { $0.planID == "pro" }).map { "\($0.displayPrice) · recurring" } ?? "Loading…"
        }
    }

    func priceID(plans: [SubscriptionPlan]) -> String? {
        switch self {
        case .free:    return nil
        case .starter: return plans.first(where: { $0.planID == "starter" })?.stripePriceID
        case .pro:     return plans.first(where: { $0.planID == "pro" })?.stripePriceID
        }
    }

    /// Returns bullet strings for this plan, or nil if the server limits haven't loaded yet.
    /// Callers render a skeleton when nil — never fall back to hardcoded limit numbers.
    func bullets(limits: [String: PlanTierLimits]) -> [String]? {
        switch self {
        case .free:
            guard let l = limits["free"] else { return nil }
            let games = l.maxActiveGames == -1 ? "Unlimited games" : "\(l.maxActiveGames) active games"
            let members = l.maxMembers == -1 ? "Unlimited members" : "\(l.maxMembers) members"
            return [games, members, "Public club listing"]
        case .starter:
            guard let l = limits["starter"] else { return nil }
            let games = l.maxActiveGames == -1 ? "Unlimited games" : "\(l.maxActiveGames) active games"
            let members = l.maxMembers == -1 ? "Unlimited members" : "\(l.maxMembers) members"
            return [games, members, "Accept paid bookings"]
        case .pro:
            guard let l = limits["pro"] else { return nil }
            let games = l.maxActiveGames == -1 ? "Unlimited games" : "\(l.maxActiveGames) active games"
            let members = l.maxMembers == -1 ? "Unlimited members" : "\(l.maxMembers) members"
            var bullets = [games, members]
            if l.canAcceptPayments && l.analyticsAccess { bullets.append("Payments + analytics") }
            else if l.canAcceptPayments { bullets.append("Accept paid bookings") }
            else if l.analyticsAccess { bullets.append("Analytics dashboard") }
            return bullets
        }
    }

    var badge: String? {
        switch self {
        case .pro: return "Best Value"
        default:   return nil
        }
    }

    func successHighlights(limits: [String: PlanTierLimits]) -> [String] {
        switch self {
        case .free:
            return []
        case .starter:
            var items = ["Accept paid bookings"]
            if let l = limits["starter"] {
                items.append(l.maxActiveGames == -1 ? "Unlimited active games" : "Up to \(l.maxActiveGames) active games")
                items.append(l.maxMembers == -1 ? "Unlimited members" : "Up to \(l.maxMembers) members")
            }
            return items
        case .pro:
            guard let l = limits["pro"] else { return [] }
            let games = l.maxActiveGames == -1 ? "Unlimited games" : "\(l.maxActiveGames) active games"
            let members = l.maxMembers == -1 ? "Unlimited members" : "Up to \(l.maxMembers) members"
            var items = ["\(games) & \(members)"]
            if l.analyticsAccess { items.append("Analytics dashboard") }
            switch (l.canUseRecurringGames, l.canUseDelayedPublishing) {
            case (true, true):  items.append("Recurring games & scheduled publishing")
            case (true, false): items.append("Recurring games")
            case (false, true): items.append("Scheduled publishing")
            case (false, false): break
            }
            return items
        }
    }
}

// MARK: - ClubUpgradePaywallView

struct ClubUpgradePaywallView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    let lockedFeature: LockedFeature

    @State private var paymentError: String?
    @State private var isProcessingUpgrade = false
    @State private var upgradeSucceeded = false
    @State private var subscribedPlan: UpgradePlan? = nil

    private var currentPlanTier: String {
        appState.entitlementsByClubID[club.id]?.planTier ?? "free"
    }

    /// Plans available for upgrade given the current tier.
    private var upgradablePlans: [UpgradePlan] {
        switch currentPlanTier {
        case "pro":     return []
        case "starter": return [.pro]
        default:        return [.starter, .pro]
        }
    }

    var body: some View {
        NavigationStack {
            if upgradeSucceeded, let plan = subscribedPlan {
                successView(plan: plan)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Brand.secondaryText)
                            }
                        }
                    }
            } else {
                ZStack {
                    ScrollView {
                        VStack(spacing: 0) {
                            headerSection
                            highlightsSection
                            if !upgradablePlans.isEmpty {
                                plansSection
                            }
                            if let err = paymentError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(Brand.errorRed)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .padding(.top, 8)
                            }
                            footnoteSection
                        }
                        .padding(.bottom, 40)
                    }
                    .background(Color(.systemGroupedBackground))

                    // Processing overlay — shown while we wait for webhook + DB update
                    if isProcessingUpgrade {
                        processingOverlay
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .disabled(isProcessingUpgrade)
                    }
                }
            }
        }
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(Brand.primaryText)
                VStack(spacing: 6) {
                    Text("Activating your plan…")
                        .font(.headline)
                        .foregroundStyle(Brand.primaryText)
                    Text("This can take a few seconds.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                }
            }
        }
    }

    // MARK: - Success View

    private func successView(plan: UpgradePlan) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    // Checkmark badge
                    ZStack {
                        Circle()
                            .fill(Brand.accentGreen.opacity(0.15))
                            .frame(width: 88, height: 88)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Brand.accentGreen)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 8) {
                        Text("You're on \(plan.displayName)!")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                        Text("Your club has been upgraded. All \(plan.displayName) features are now active.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                }

                // Features unlocked
                VStack(spacing: 0) {
                    Text("What's unlocked")
                        .font(.headline)
                        .foregroundStyle(Brand.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 12)

                    VStack(spacing: 0) {
                        ForEach(Array(plan.successHighlights(limits: appState.planTierLimits).enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 14) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Brand.accentGreen)
                                Text(item)
                                    .font(.subheadline)
                                    .foregroundStyle(Brand.primaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            if index < plan.successHighlights(limits: appState.planTierLimits).count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .background(Brand.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                }

                // Done button
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Brand.accentGreen.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: lockedFeature.icon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
            }
            .padding(.top, 28)

            VStack(spacing: 6) {
                Text(lockedFeature.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Brand.primaryText)
                Text(lockedFeature.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    // MARK: - Highlights

    private var highlightsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(lockedFeature.highlights(limits: appState.planTierLimits).enumerated()), id: \.offset) { index, item in
                HStack(spacing: 14) {
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.accentGreen)
                        .frame(width: 28)
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(Brand.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                if index < lockedFeature.highlights(limits: appState.planTierLimits).count - 1 {
                    Divider().padding(.leading, 62)
                }
            }
        }
        .background(Brand.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Plans

    private var plansSection: some View {
        VStack(spacing: 12) {
            Text("Choose a plan")
                .font(.headline)
                .foregroundStyle(Brand.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                ForEach(upgradablePlans, id: \.rawValue) { plan in
                    planCard(plan)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func planCard(_ plan: UpgradePlan) -> some View {
        let isPro = plan == .pro

        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.displayName)
                            .font(.headline)
                            .foregroundStyle(isPro ? .white : Brand.primaryText)
                        if let badge = plan.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Brand.accentGreen)
                                .foregroundStyle(Brand.primaryText)
                                .clipShape(Capsule())
                        }
                    }
                    Text(plan.displayPrice(plans: appState.subscriptionPlans))
                        .font(.caption)
                        .foregroundStyle(isPro ? .white.opacity(0.75) : Brand.secondaryText)
                }
                Spacer()
                upgradeButton(for: plan, isPro: isPro)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .opacity(isPro ? 0.18 : 1)

            // Feature bullets — skeleton shown until server limits arrive
            Group {
                if let bullets = plan.bullets(limits: appState.planTierLimits) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(bullets, id: \.self) { bullet in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(isPro ? Brand.accentGreen : .green)
                                Text(bullet)
                                    .font(.subheadline)
                                    .foregroundStyle(isPro ? .white.opacity(0.9) : Brand.primaryText)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(0..<3, id: \.self) { i in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isPro ? Color.white.opacity(0.2) : Brand.softOutline)
                                    .frame(width: 10, height: 10)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isPro ? Color.white.opacity(0.15) : Brand.softOutline)
                                    .frame(width: CGFloat([80, 100, 70][i]), height: 12)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(isPro ? Brand.primaryText : Brand.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isPro ? Color.clear : Brand.softOutline, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(isPro ? 0.14 : 0.04),
            radius: isPro ? 10 : 2,
            y: isPro ? 4 : 1
        )
    }

    @ViewBuilder
    private func upgradeButton(for plan: UpgradePlan, isPro: Bool) -> some View {
        if let priceID = plan.priceID(plans: appState.subscriptionPlans) {
            let isLoading = appState.isCreatingSubscription || isProcessingUpgrade
            Button {
                guard !isLoading else { return }
                subscribedPlan = plan
                Task {
                    guard let result = await appState.createClubSubscription(for: club, priceID: priceID) else { return }
                    if let secret = result.clientSecret {
                        var config = PaymentSheet.Configuration()
                        config.merchantDisplayName = "Book A Dink"
                        config.applePay = .init(merchantId: "merchant.com.bookadink", merchantCountryCode: "AU")
                        let ps = PaymentSheet(paymentIntentClientSecret: secret, configuration: config)
                        presentPaymentSheet(ps)
                    } else if result.status == "active" {
                        // Already active (e.g. free trial) — fetch and show success immediately
                        await appState.fetchClubSubscription(for: club.id)
                        await appState.fetchClubEntitlements(for: club.id)
                        upgradeSucceeded = true
                    }
                }
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(isPro ? Brand.primaryText : .white)
                    } else {
                        Text("Subscribe")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(width: 90, height: 36)
                .foregroundStyle(isPro ? Brand.primaryText : .white)
                .background(
                    isPro ? Brand.accentGreen : Brand.primaryText,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    // MARK: - Footnote

    private var footnoteSection: some View {
        VStack(spacing: 4) {
            Text("Monthly subscription — charged automatically each billing cycle.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
            Text("Cancel anytime from Club Settings → Plan & Billing.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
            Text("Prices shown in AUD")
                .font(.caption2)
                .foregroundStyle(Brand.tertiaryText)
                .padding(.top, 2)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    // MARK: - Stripe Payment Sheet

    private func presentPaymentSheet(_ paymentSheet: PaymentSheet) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            paymentError = "Unable to present payment screen."
            return
        }
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        paymentSheet.present(from: top) { result in
            DispatchQueue.main.async {
                switch result {
                case .completed:
                    paymentError = nil
                    isProcessingUpgrade = true
                    Task {
                        // Poll up to ~30 seconds for the Stripe webhook to fire and
                        // update the subscription status to 'active' in the DB.
                        // Delays: 2s, 3s, 4s, 5s, 7s, 10s = 6 attempts over ~31s.
                        let pollDelays: [Double] = [2, 3, 4, 5, 7, 10]
                        for delay in pollDelays {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            await appState.fetchClubSubscription(for: club.id)
                            if appState.subscriptionsByClubID[club.id]?.isActive == true { break }
                        }
                        // Refresh entitlements regardless — webhook may have already run
                        await appState.fetchClubEntitlements(for: club.id)
                        await MainActor.run {
                            isProcessingUpgrade = false
                            upgradeSucceeded = true
                        }
                    }
                case .canceled:
                    break
                case .failed(let error):
                    paymentError = error.localizedDescription
                }
            }
        }
    }
}
