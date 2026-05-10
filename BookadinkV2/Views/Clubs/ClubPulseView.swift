// ClubPulseView.swift
// Club Intelligence — full-screen Analytics destination pushed from the
// Manage Club hub via NavigationLink. NOT a modal sheet — this is
// foundational club operating-system tooling, navigated like any other
// permanent destination.
//
// Tab structure (stable mental model):
//   Overview    — KPI snapshot + top cross-category insights + revenue glance
//   Revenue     — period selector, hero number, expanded trend, breakdown
//   Members     — membership snapshot + member-category insights
//   Operations  — top performing patterns, peak times, ops insights
//
// Pulse insights are category-tagged. Overview shows the highest-severity
// insights across all categories; the dedicated tabs filter to their
// category. No invented data — categories with no real signal render empty.
//
// Reuses AppState's existing analytics surface (KPIs, supplemental,
// trend, top games, peak times, summary). Period changes refetch via
// fetchClubAdvancedAnalytics(for:days:). No new RPCs, no backend changes.

import SwiftUI
import Charts
import UIKit

// MARK: - Tab + Period enums

enum PulseTab: String, CaseIterable, Identifiable {
    case overview, revenue, members, operations
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview:   return "Overview"
        case .revenue:    return "Revenue"
        case .members:    return "Members"
        case .operations: return "Operations"
        }
    }
}

/// Display extensions for the existing `AnalyticsPeriod` (defined in Models.swift).
/// Pulse adds a slightly louder uppercase short label for the segmented selector
/// and a friendly long-form label for the meta strip / VoiceOver — neither
/// belongs in the model layer.
extension AnalyticsPeriod {
    fileprivate var pulseShortLabel: String { label.uppercased() }
    fileprivate var pulseDisplayLabel: String {
        switch self {
        case .last7:  return "Last 7 days"
        case .last30: return "Last 30 days"
        case .last90: return "Last 90 days"
        }
    }
}

// MARK: - ClubPulseView

struct ClubPulseView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    let club: Club

    @State private var selectedTab: PulseTab = .overview
    @State private var period: AnalyticsPeriod = .last30
    @State private var stripeStatusLoaded = false
    @State private var isRefreshing = false
    @State private var lastRefreshAt: Date?
    @State private var childSheet: OwnerToolSheet?

    private let isOnIPad = UIDevice.current.userInterfaceIdiom == .pad

    // MARK: Derived state

    private var entitlements: ClubEntitlements? { appState.entitlementsByClubID[club.id] }
    private var planTier: String { entitlements?.planTier ?? "free" }
    private var summary: ClubDashboardSummary? { appState.dashboardSummaryByClubID[club.id] }
    private var kpis: ClubAnalyticsKPIs? { appState.analyticsKPIsByClubID[club.id] }
    private var supplemental: ClubAnalyticsSupplemental? { appState.analyticsSupplementalByClubID[club.id] }
    private var revenueTrend: [ClubRevenueTrendPoint] { appState.revenueTrendByClubID[club.id] ?? [] }
    private var topGames: [ClubTopGame] { appState.topGamesByClubID[club.id] ?? [] }
    private var peakTimes: [ClubPeakTime] { appState.peakTimesByClubID[club.id] ?? [] }
    private var stripeAccount: ClubStripeAccount? { appState.stripeAccountByClubID[club.id] }
    private var pendingCount: Int { appState.ownerJoinRequests(for: club).count }

    private var analyticsLocked: Bool {
        if case .blocked = FeatureGateService.canAccessAnalytics(entitlements) { return true }
        return false
    }

    // MARK: Setup banner state

    private var paidUpcomingGamesCount: Int {
        appState.games(for: club)
            .filter { $0.status != "cancelled" && $0.dateTime >= Date() }
            .filter { ($0.feeAmount ?? 0) > 0 }
            .count
    }

    private enum SetupIssue {
        case planRequired
        case stripeNotConfigured
        case stripeVerificationPending

        var icon: String {
            switch self {
            case .planRequired:              return "lock.fill"
            case .stripeNotConfigured:       return "creditcard.trianglebadge.exclamationmark"
            case .stripeVerificationPending: return "clock.badge.exclamationmark"
            }
        }
        var title: String {
            switch self {
            case .planRequired:              return "Payment processing disabled"
            case .stripeNotConfigured:       return "Stripe not connected"
            case .stripeVerificationPending: return "Stripe verification pending"
            }
        }
        var detail: String {
            switch self {
            case .planRequired:              return "Upgrade to Starter or Pro to accept booking fees."
            case .stripeNotConfigured:       return "Connect Stripe in Club Settings → Payments."
            case .stripeVerificationPending: return "Stripe is reviewing your account."
            }
        }
        var isCritical: Bool {
            switch self {
            case .planRequired, .stripeNotConfigured: return true
            case .stripeVerificationPending:          return false
            }
        }
    }

    private var activeSetupIssue: SetupIssue? {
        guard paidUpcomingGamesCount > 0, let e = entitlements, stripeStatusLoaded else { return nil }
        if !e.canAcceptPayments          { return .planRequired }
        if stripeAccount == nil          { return .stripeNotConfigured }
        if stripeAccount?.payoutsEnabled == false { return .stripeVerificationPending }
        return nil
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                tabBar
                metaStrip
                pastDueBanner
                setupBanner

                Group {
                    switch selectedTab {
                    case .overview:   overviewContent
                    case .revenue:    revenueContent
                    case .members:    membersContent
                    case .operations: operationsContent
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 40)
            // iPad / large phone landscape: cap reading width so the operational
            // layout stays a single readable column rather than stretching.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refreshAll() }
        .background(Brand.appBackground)
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(club.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(1)
                    Text("Analytics")
                        .font(.caption2)
                        .foregroundStyle(Brand.tertiaryText)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if entitlements != nil { tierPill }
            }
        }
        .sheet(item: $childSheet) { sheet in childSheetContent(sheet) }
        .task { await refreshAll() }
        .onChange(of: period) { _ in
            Task { await refreshPeriod() }
        }
        .onChange(of: appState.lastConfirmedBookingClubID) { newClubID in
            guard newClubID == club.id else { return }
            Task { await appState.loadDashboardSummary(for: club.id) }
        }
        .onChange(of: appState.lastCancellationCredit) { credit in
            guard credit?.clubID == club.id else { return }
            Task { await appState.loadDashboardSummary(for: club.id) }
        }
        .onChange(of: appState.lastAttendanceUpdateClubID) { newClubID in
            guard newClubID == club.id else { return }
            Task { await appState.loadDashboardSummary(for: club.id) }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await refreshAll() }
        }
    }

    // MARK: Refresh

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let fetchEntitlements: Void = appState.fetchClubEntitlements(for: club.id)
        async let fetchMembers: Void = appState.refreshClubDirectoryMembers(for: club)
        async let fetchSummary: Void = appState.loadDashboardSummary(for: club.id)
        async let fetchStripe: Void = appState.refreshStripeAccountStatus(for: club.id)
        _ = await (fetchEntitlements, fetchMembers, fetchSummary, fetchStripe)

        stripeStatusLoaded = true

        if !analyticsLocked {
            async let advanced: Void = appState.fetchClubAdvancedAnalytics(for: club.id, days: period.rawValue)
            async let memberActivity: Void = appState.loadClubMemberActivity(for: club.id, days: period.rawValue)
            _ = await (advanced, memberActivity)
        }

        lastRefreshAt = Date()
    }

    /// Fired only when the period selector changes — refetches advanced
    /// analytics with the new window. Summary stays at its native 30-day
    /// rolling window since the RPC does not accept a period.
    private func refreshPeriod() async {
        guard !analyticsLocked else { return }
        async let advanced: Void = appState.fetchClubAdvancedAnalytics(for: club.id, days: period.rawValue)
        async let memberActivity: Void = appState.loadClubMemberActivity(for: club.id, days: period.rawValue)
        _ = await (advanced, memberActivity)
        lastRefreshAt = Date()
    }

    // MARK: Banners

    @ViewBuilder
    private var pastDueBanner: some View {
        if let sub = appState.subscriptionsByClubID[club.id], sub.isPastDue {
            Label("Payment failed — update billing in Plan & Billing to restore access.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var setupBanner: some View {
        if let issue = activeSetupIssue {
            Button { childSheet = .editClub } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: issue.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(issue.isCritical ? Brand.errorRed : Brand.spicyOrange)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                            .lineLimit(2)
                        Text(issue.detail)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    (issue.isCritical ? Brand.errorRed : Brand.spicyOrange).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (issue.isCritical ? Brand.errorRed : Brand.spicyOrange).opacity(0.22),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(issue.title). \(issue.detail)")
            .accessibilityHint("Opens club settings to resolve.")
        }
    }

    // MARK: Tier pill (toolbar)

    private var tierPill: some View {
        let (label, icon, isPro): (String, String, Bool) = {
            switch planTier.lowercased() {
            case "pro":     return ("Pro Plan", "bolt.fill", true)
            case "starter": return ("Starter",  "star.fill", false)
            default:        return ("Free Plan", "",          false)
            }
        }()

        return Button(action: {}) {
            HStack(spacing: 4) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                }
                Text(label)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(isPro ? Color(hex: "3D6B00") : Brand.secondaryText)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(true)
    }

    // MARK: Tab bar

    /// Premium underline tabs — premium SaaS rhythm (Stripe / Linear).
    /// The thin baseline rule extends the full width to anchor the section.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PulseTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 8) {
                        Text(tab.label)
                            .font(.subheadline.weight(selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? Brand.primaryText : Brand.tertiaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Rectangle()
                            .fill(selectedTab == tab ? Brand.primaryText : Color.clear)
                            .frame(height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityLabel(tab.label)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.dividerColor)
                .frame(height: 0.5)
        }
    }

    // MARK: Meta strip

    private var metaStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(period.pulseDisplayLabel.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.9)
                .foregroundStyle(Brand.tertiaryText)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(Brand.secondaryText.opacity(0.40))
                    .frame(width: 4, height: 4)
                Text(freshnessText)
                    .font(.caption2)
                    .foregroundStyle(Brand.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Period: \(period.pulseDisplayLabel). \(freshnessText).")
    }

    private var freshnessText: String {
        guard let date = lastRefreshAt else { return "Refreshing" }
        return "Updated \(PulseFormatters.relative(date))"
    }

    // MARK: Overview tab

    @ViewBuilder
    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            kpiQuartet

            // Top insights — cross-category, surfaces what's most important
            // right now regardless of which category it belongs to.
            let topInsights = insights(for: nil)
            if !topInsights.isEmpty {
                pulseSection(title: "Pulse", insights: topInsights, max: 5)
            } else if entitlements != nil && summary != nil {
                emptyTabBody("Pulse insights appear here as your club generates data — bookings, members joining, sessions filling. New clubs see fewer rows by design.")
            }

            // Compact revenue glance — links into Revenue tab for detail.
            if !analyticsLocked, let k = kpis {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sectionHeader("Revenue")
                        Spacer()
                        Button { selectedTab = .revenue } label: {
                            HStack(spacing: 3) {
                                Text("View detail")
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Brand.slateBlue)
                        }
                        .buttonStyle(.plain)
                    }
                    PulseRevenueStripCompact(kpis: k, trend: revenueTrend)
                }
            }
        }
    }

    // MARK: Revenue tab

    @ViewBuilder
    private var revenueContent: some View {
        if analyticsLocked {
            revenueLockedCard
        } else if let k = kpis {
            VStack(alignment: .leading, spacing: 22) {
                periodSelector
                PulseRevenueStripExpanded(kpis: k, trend: revenueTrend)
                breakdownTable(kpis: k)
                topEarningSessionsSection(currency: k.currency)
                revenueByFormatSection(currency: k.currency)

                let revenueInsights = insights(for: .revenue)
                if !revenueInsights.isEmpty {
                    pulseSection(title: "Revenue Insights", insights: revenueInsights, max: 4)
                }
            }
        } else if appState.loadingAnalyticsClubIDs.contains(club.id) {
            VStack(alignment: .leading, spacing: 22) {
                periodSelector
                loadingPlaceholder("Loading revenue…")
            }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                periodSelector
                emptyPlaceholder(
                    icon: "creditcard",
                    title: "No revenue yet",
                    body: "Once paid bookings are confirmed, the trend will appear here."
                )
            }
        }
    }

    // MARK: Members tab

    @ViewBuilder
    private var membersContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            membersSnapshot

            memberHealthSection

            mostActiveMemberSection
            reliabilityWatchSection
            previouslyActiveSection

            let memberInsights = insights(for: .members)
            if !memberInsights.isEmpty {
                pulseSection(title: "Member Insights", insights: memberInsights, max: 5)
            }

            if memberHealthRows.isEmpty
                && insights(for: .members).isEmpty
                && mostActiveMember == nil
                && reliabilityWatchList.isEmpty
                && previouslyActiveList.isEmpty {
                emptyTabBody("Member intelligence builds as your club grows. Health metrics, activity rankings, and category insights will appear here as your data fills in.")
            }
        }
    }

    // MARK: Operations tab

    @ViewBuilder
    private var operationsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            operationsSnapshot

            sessionIntelligenceSection

            if !topGames.isEmpty {
                topPatternsSection
            }

            if !peakTimes.isEmpty {
                peakTimesSection
            }

            let opsInsights = insights(for: .operations)
            if !opsInsights.isEmpty {
                pulseSection(title: "Operations Insights", insights: opsInsights, max: 5)
            }

            if sessionIntelligenceRows.isEmpty
                && topGames.isEmpty && peakTimes.isEmpty && opsInsights.isEmpty {
                emptyTabBody("Operations intelligence builds from session activity. Once you've hosted a few games, top performing patterns and demand windows will appear here.")
            }
        }
    }

    // MARK: KPI snapshot strips

    /// 4-cell horizontal KPI strip used by Overview, Members, Operations.
    /// Restrained financial-strip aesthetic: thin vertical dividers between
    /// cells, single rounded surface, hairline border. Not a 4-card grid.
    private func kpiStrip(_ cells: [PulseKPICell]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                kpiCell(
                    label: cell.label,
                    value: cell.value,
                    delta: cell.delta,
                    isCurrency: cell.isCurrency
                )
                if index < cells.count - 1 {
                    Rectangle()
                        .fill(Brand.dividerColor)
                        .frame(width: 0.5, height: 36)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.025), radius: 4, x: 0, y: 1)
    }

    private func kpiCell(label: String, value: String, delta: PulseDelta?, isCurrency: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.7)
                .foregroundStyle(Brand.tertiaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: isCurrency ? 16 : 17, weight: .semibold, design: .rounded))
                .foregroundStyle(value == "—" ? Brand.tertiaryText : Brand.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Group {
                if let delta = delta {
                    HStack(spacing: 2) {
                        Image(systemName: delta.isPositive ? "arrow.up" : "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                        Text(delta.label)
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(delta.isPositive ? PulseColors.positiveAccent : PulseColors.negativeAccent)
                } else {
                    // Reserve vertical space so cells stay aligned even when
                    // some have no delta to render.
                    Text(" ").font(.caption2)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)\(delta.map { ", \($0.isPositive ? "up" : "down") \($0.label)" } ?? "")")
    }

    private var kpiQuartet: some View {
        kpiStrip([
            .init(label: "Revenue",  value: kpiRevenueValue,  delta: kpiRevenueDelta,  isCurrency: true),
            .init(label: "Bookings", value: kpiBookingsValue, delta: kpiBookingsDelta, isCurrency: false),
            .init(label: "Fill",     value: kpiFillValue,     delta: kpiFillDelta,     isCurrency: false),
            .init(label: "Players",  value: kpiPlayersValue,  delta: kpiPlayersDelta,  isCurrency: false)
        ])
    }

    private var membersSnapshot: some View {
        kpiStrip([
            .init(label: "Members",   value: snapshotTotalMembers,   delta: nil, isCurrency: false),
            .init(label: "New",       value: snapshotNewMembers,     delta: nil, isCurrency: false),
            .init(label: "1st-time",  value: snapshotFirstTime,      delta: nil, isCurrency: false),
            .init(label: "Repeat",    value: snapshotRepeatRate,     delta: nil, isCurrency: false)
        ])
    }

    private var operationsSnapshot: some View {
        kpiStrip([
            .init(label: "Games",    value: snapshotGameCount,    delta: nil, isCurrency: false),
            .init(label: "Fill",     value: kpiFillValue,         delta: nil, isCurrency: false),
            .init(label: "No-show",  value: snapshotNoShowRate,   delta: nil, isCurrency: false),
            .init(label: "Cancel",   value: snapshotCancelRate,   delta: nil, isCurrency: false)
        ])
    }

    // MARK: KPI value derivations

    private var kpiRevenueValue: String {
        guard !analyticsLocked, let k = kpis else { return "—" }
        return PulseFormatters.currency(k.currRevenueCents, code: k.currency)
    }
    private var kpiRevenueDelta: PulseDelta? {
        guard !analyticsLocked, let k = kpis, k.prevRevenueCents > 0 else { return nil }
        let pct = Double(k.currRevenueCents - k.prevRevenueCents) / Double(k.prevRevenueCents) * 100
        if abs(pct) < 1 { return nil }
        return PulseDelta(label: "\(String(format: "%.0f", abs(pct)))%", isPositive: pct >= 0)
    }

    private var kpiBookingsValue: String {
        if let k = kpis, !analyticsLocked { return "\(k.currBookingCount)" }
        if let s = summary { return "\(s.upcomingBookingsCount)" }
        return "—"
    }
    private var kpiBookingsDelta: PulseDelta? {
        guard !analyticsLocked, let k = kpis else { return nil }
        let diff = k.currBookingCount - k.prevBookingCount
        if diff == 0 { return nil }
        return PulseDelta(label: "\(abs(diff))", isPositive: diff > 0)
    }

    private var kpiFillValue: String {
        if let s = summary, let r = s.fillRate30d { return "\(Int(round(r * 100)))%" }
        if !analyticsLocked, let k = kpis, k.currBookingCount > 0 {
            return "\(Int(round(k.currFillRate * 100)))%"
        }
        return "—"
    }
    private var kpiFillDelta: PulseDelta? {
        if let s = summary, let c = s.fillRate30d, let p = s.prevFillRate30d {
            let diffPP = (c - p) * 100
            if abs(diffPP) < 1 { return nil }
            return PulseDelta(label: "\(String(format: "%.0f", abs(diffPP)))pt", isPositive: diffPP >= 0)
        }
        return nil
    }

    private var kpiPlayersValue: String {
        if let s = summary { return "\(s.monthlyActivePlayers30d)" }
        if !analyticsLocked, let k = kpis { return "\(k.currActivePlayers)" }
        return "—"
    }
    private var kpiPlayersDelta: PulseDelta? {
        guard let s = summary else { return nil }
        let diff = s.monthlyActivePlayers30d - s.prevActivePlayers30d
        if diff == 0 { return nil }
        return PulseDelta(label: "\(abs(diff))", isPositive: diff > 0)
    }

    // Members snapshot derivations

    private var snapshotTotalMembers: String {
        if let s = summary { return "\(s.totalMembers)" }
        return "—"
    }
    private var snapshotNewMembers: String {
        if let s = summary { return "\(s.memberGrowth30d)" }
        return "—"
    }
    private var snapshotFirstTime: String {
        if !analyticsLocked, let s = supplemental { return "\(s.currNewPlayers)" }
        return "—"
    }
    private var snapshotRepeatRate: String {
        guard !analyticsLocked, let k = kpis, k.currBookingCount >= 5 else { return "—" }
        return "\(Int(round(k.repeatPlayerRate * 100)))%"
    }

    // Operations snapshot derivations

    private var snapshotGameCount: String {
        if !analyticsLocked, let s = supplemental { return "\(s.currGameCount)" }
        return "—"
    }
    private var snapshotNoShowRate: String {
        guard !analyticsLocked, let s = supplemental, let rate = s.noShowRate, s.currCheckedCount >= 5 else { return "—" }
        return "\(Int(round(rate * 100)))%"
    }
    private var snapshotCancelRate: String {
        guard !analyticsLocked, let k = kpis, k.currBookingCount >= 5 else { return "—" }
        return "\(Int(round(k.cancellationRate * 100)))%"
    }

    // MARK: Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(1.1)
    }

    // MARK: Pulse section helper

    /// Flat list with hairline dividers — Linear/Apple-Mail rhythm. No
    /// surrounding card, no rounded outer chrome. The leading-inset hairline
    /// keeps the tonal status chip as the visual anchor.
    private func pulseSection(title: String, insights: [PulseInsight], max maxRows: Int) -> some View {
        let rows = Array(insights.prefix(maxRows))
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
                .padding(.bottom, 10)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, insight in
                PulseRow(insight: insight) { handleInsightTap(insight) }
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Brand.dividerColor)
                        .frame(height: 0.5)
                        .padding(.leading, 38)
                }
            }
        }
    }

    // MARK: Insights — accessor

    private func insights(for category: PulseInsightCategory?) -> [PulseInsight] {
        let all = PulseInsightBuilder.build(
            summary: summary,
            kpis: kpis,
            supplemental: supplemental,
            topGames: topGames,
            peakTimes: peakTimes,
            pendingRequestCount: pendingCount,
            currencyCode: kpis?.currency
        )
        guard let category = category else { return all }
        return all.filter { $0.category == category }
    }

    private func handleInsightTap(_ insight: PulseInsight) {
        switch insight.destination {
        case .ownerSheet(let sheet):
            childSheet = sheet
        case .none:
            break
        }
    }

    // MARK: Top performing patterns (Operations)

    private var topPatternsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Top performing patterns")
            VStack(spacing: 0) {
                let rows = Array(topGames.prefix(5))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, game in
                    topPatternRow(game)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(Brand.dividerColor)
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.dividerColor, lineWidth: 1)
            )
        }
    }

    private func topPatternRow(_ game: ClubTopGame) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(game.dayLabel) \(game.hourLabel)")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                    Circle().fill(Brand.tertiaryText).frame(width: 2, height: 2)
                    Text("\(game.occurrenceCount) sessions")
                        .font(.caption)
                        .foregroundStyle(Brand.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            Text("\(Int(round(game.avgFillRate * 100)))%")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title) on \(game.dayLabel) \(game.hourLabel), \(game.occurrenceCount) sessions, \(Int(round(game.avgFillRate * 100)))% average fill")
    }

    // MARK: Peak times (Operations)

    private var peakTimesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Peak times")
            VStack(spacing: 0) {
                let rows = Array(peakTimes.prefix(5))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, slot in
                    peakTimeRow(slot)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(Brand.dividerColor)
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.dividerColor, lineWidth: 1)
            )
        }
    }

    private func peakTimeRow(_ slot: ClubPeakTime) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(slot.dayLabel) \(slot.hourLabel)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                Text("\(slot.gameCount) sessions · avg \(String(format: "%.1f", slot.avgConfirmed)) attending")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(round(slot.avgFillRate * 100)))%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .monospacedDigit()
                if slot.avgWaitlist >= 0.5 {
                    Text("WL \(String(format: "%.1f", slot.avgWaitlist))")
                        .font(.caption2)
                        .foregroundStyle(Brand.tertiaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Session intelligence (Operations tab)

    /// One row of cross-cutting session intelligence — answers concrete
    /// operator questions like "what fills fastest" / "what underperforms".
    /// Computed from existing topGames + peakTimes; rows are only emitted
    /// when the underlying signal is real.
    fileprivate struct SessionIntelRow {
        let dimension: String  // e.g. "Highest fill"
        let session: String    // e.g. "Sat 9am Open Play"
        let metric: String     // e.g. "100%"
    }

    /// Cached so the section's empty-check and the section render share the
    /// same source of truth (avoids drift between "section is empty" and
    /// "section actually rendered nothing").
    private var sessionIntelligenceRows: [SessionIntelRow] {
        var rows: [SessionIntelRow] = []
        let qualifiedTop = topGames.filter { $0.occurrenceCount >= 2 }

        // Highest fill rate
        if let top = qualifiedTop.max(by: { $0.avgFillRate < $1.avgFillRate }), top.avgFillRate > 0 {
            rows.append(.init(
                dimension: "Highest fill",
                session: "\(top.dayLabel) \(top.hourLabel) \(top.title)",
                metric: "\(Int(round(top.avgFillRate * 100)))%"
            ))
        }

        // Strongest waitlist demand (peak times)
        if let topWait = peakTimes.filter({ $0.gameCount >= 2 })
            .max(by: { $0.avgWaitlist < $1.avgWaitlist }),
           topWait.avgWaitlist >= 1.0 {
            rows.append(.init(
                dimension: "Strongest demand",
                session: "\(topWait.dayLabel) \(topWait.hourLabel)",
                metric: "\(String(format: "%.1f", topWait.avgWaitlist)) waitlist"
            ))
        }

        // Fastest to fill
        if let fastest = qualifiedTop
            .filter({ $0.avgTimeToFillMinutes != nil })
            .min(by: { ($0.avgTimeToFillMinutes ?? .infinity) < ($1.avgTimeToFillMinutes ?? .infinity) }),
           let mins = fastest.avgTimeToFillMinutes {
            rows.append(.init(
                dimension: "Fastest to fill",
                session: "\(fastest.dayLabel) \(fastest.hourLabel) \(fastest.title)",
                metric: PulseFormatters.duration(minutes: mins)
            ))
        }

        // Slowest to fill (only when meaningfully slow — avoid false alarms
        // on clubs whose patterns all fill quickly)
        if let slowest = qualifiedTop
            .filter({ ($0.avgTimeToFillMinutes ?? 0) >= 60 })
            .max(by: { ($0.avgTimeToFillMinutes ?? 0) < ($1.avgTimeToFillMinutes ?? 0) }),
           let mins = slowest.avgTimeToFillMinutes,
           // Don't show both fastest and slowest as the same session.
           rows.first(where: { $0.dimension == "Fastest to fill" })
            .map({ $0.session != "\(slowest.dayLabel) \(slowest.hourLabel) \(slowest.title)" }) ?? true {
            rows.append(.init(
                dimension: "Slowest to fill",
                session: "\(slowest.dayLabel) \(slowest.hourLabel) \(slowest.title)",
                metric: PulseFormatters.duration(minutes: mins)
            ))
        }

        // Weakest fill (only flag when notably below typical)
        if let weakest = qualifiedTop
            .filter({ $0.avgFillRate < 0.7 })
            .min(by: { $0.avgFillRate < $1.avgFillRate }) {
            rows.append(.init(
                dimension: "Weakest fill",
                session: "\(weakest.dayLabel) \(weakest.hourLabel) \(weakest.title)",
                metric: "\(Int(round(weakest.avgFillRate * 100)))%"
            ))
        }

        // Underperforming timeslot (peak times — slot averages low fill)
        if let underperformer = peakTimes
            .filter({ $0.gameCount >= 3 && $0.avgFillRate < 0.55 })
            .min(by: { $0.avgFillRate < $1.avgFillRate }) {
            rows.append(.init(
                dimension: "Underperforming slot",
                session: "\(underperformer.dayLabel) \(underperformer.hourLabel)",
                metric: "\(Int(round(underperformer.avgFillRate * 100)))%"
            ))
        }

        return rows
    }

    @ViewBuilder
    private var sessionIntelligenceSection: some View {
        let rows = sessionIntelligenceRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Session intelligence")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        sessionIntelRowView(row)
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Brand.dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Brand.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Brand.dividerColor, lineWidth: 1)
                )
            }
        }
    }

    private func sessionIntelRowView(_ row: SessionIntelRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.dimension.uppercased())
                    .font(.caption2.weight(.medium))
                    .tracking(0.7)
                    .foregroundStyle(Brand.tertiaryText)
                Text(row.session)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.metric)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.dimension), \(row.session), \(row.metric)")
    }

    // MARK: Top earning sessions (Revenue tab)

    @ViewBuilder
    private func topEarningSessionsSection(currency: String?) -> some View {
        let earners = Array(
            topGames
                .filter { $0.totalRevenueCents > 0 }
                .sorted { $0.totalRevenueCents > $1.totalRevenueCents }
                .prefix(5)
        )
        if !earners.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Top earning sessions")
                VStack(spacing: 0) {
                    ForEach(Array(earners.enumerated()), id: \.element.id) { idx, game in
                        topEarningRow(game, currency: currency)
                        if idx < earners.count - 1 {
                            Rectangle()
                                .fill(Brand.dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Brand.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Brand.dividerColor, lineWidth: 1)
                )
            }
        }
    }

    private func topEarningRow(_ game: ClubTopGame, currency: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(game.dayLabel) \(game.hourLabel)")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                    Circle().fill(Brand.tertiaryText).frame(width: 2, height: 2)
                    Text("\(game.occurrenceCount) sessions")
                        .font(.caption)
                        .foregroundStyle(Brand.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            Text(PulseFormatters.currency(game.totalRevenueCents, code: currency))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title) on \(game.dayLabel) \(game.hourLabel), \(game.occurrenceCount) sessions, \(PulseFormatters.currency(game.totalRevenueCents, code: currency))")
    }

    // MARK: Revenue by format (Revenue tab)

    @ViewBuilder
    private func revenueByFormatSection(currency: String?) -> some View {
        let buckets = topGames
            .filter { $0.totalRevenueCents > 0 }
        let totalCents = buckets.reduce(0) { $0 + $1.totalRevenueCents }
        let grouped = Dictionary(grouping: buckets) { $0.gameFormat ?? "" }
            .map { (format: $0.key, total: $0.value.reduce(0) { $0 + $1.totalRevenueCents }) }
            .sorted { $0.total > $1.total }

        // Only render when there's enough variety to make a breakdown
        // meaningful — clubs running a single format see no value here.
        if totalCents > 0 && grouped.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Revenue by format")
                VStack(spacing: 0) {
                    ForEach(Array(grouped.enumerated()), id: \.offset) { idx, item in
                        revenueByFormatRow(
                            label: prettyGameFormat(item.format),
                            value: item.total,
                            total: totalCents,
                            currency: currency
                        )
                        if idx < grouped.count - 1 {
                            Rectangle()
                                .fill(Brand.dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Brand.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Brand.dividerColor, lineWidth: 1)
                )
            }
        }
    }

    private func revenueByFormatRow(label: String, value: Int, total: Int, currency: String?) -> some View {
        let pct = total > 0 ? Int(round(Double(value) / Double(total) * 100)) : 0
        return HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(PulseFormatters.currency(value, code: currency))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .monospacedDigit()
                Text("\(pct)%")
                    .font(.caption2)
                    .foregroundStyle(Brand.tertiaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(PulseFormatters.currency(value, code: currency)), \(pct) percent")
    }

    private func prettyGameFormat(_ raw: String) -> String {
        switch raw {
        case "open_play":          return "Open Play"
        case "random":             return "Random"
        case "round_robin":        return "Round Robin"
        case "king_of_court":      return "King of the Court"
        case "dupr_king_of_court": return "DUPR King of the Court"
        case "":                   return "Other"
        default:
            return raw
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    // MARK: Member health (Members tab)

    fileprivate struct MemberHealthRow {
        let dimension: String   // e.g. "Retention"
        let value: String       // e.g. "78%"
        let note: String?       // e.g. "healthy"
    }

    /// Cached so the empty-check and the render share the same source of
    /// truth. Each row is omitted unless its underlying metric has a real
    /// signal — no placeholders, no fake notes.
    private var memberHealthRows: [MemberHealthRow] {
        var rows: [MemberHealthRow] = []

        // Active rate — % of total members who actually played in the last
        // 30 days. Pure summary metric; available on free tier.
        if let s = summary, s.totalMembers > 0 {
            let pct = Int(round(Double(s.monthlyActivePlayers30d) / Double(s.totalMembers) * 100))
            rows.append(.init(
                dimension: "Active rate",
                value: "\(pct)%",
                note: pct >= 60 ? "strong" : pct >= 35 ? "healthy" : "soft"
            ))
        }

        // Retention rate — Pro only. Requires a non-trivial sample so the
        // percentage isn't a coin-flip.
        if let k = kpis, k.currBookingCount >= 5 {
            let pct = Int(round(k.repeatPlayerRate * 100))
            rows.append(.init(
                dimension: "Retention",
                value: "\(pct)%",
                note: pct >= 70 ? "strong" : pct >= 50 ? "healthy" : "soft"
            ))
        }

        // Member growth — last 30 days. Always available from summary.
        if let s = summary, s.memberGrowth30d != 0 {
            let n = s.memberGrowth30d
            rows.append(.init(
                dimension: "Net new members",
                value: n > 0 ? "+\(n)" : "\(n)",
                note: "last 30 days"
            ))
        }

        // Cancellation rate — Pro only. Sample threshold + only flag when
        // notably above benchmark; otherwise a quiet positive.
        if let k = kpis, k.currBookingCount >= 10 {
            let pct = Int(round(k.cancellationRate * 100))
            let note: String
            if k.cancellationRate >= 0.18      { note = "above benchmark" }
            else if k.cancellationRate <= 0.05 { note = "low" }
            else                                { note = "normal" }
            rows.append(.init(dimension: "Cancellation rate", value: "\(pct)%", note: note))
        }

        return rows
    }

    @ViewBuilder
    private var memberHealthSection: some View {
        let rows = memberHealthRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Member health")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        memberHealthRowView(row)
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Brand.dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Brand.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Brand.dividerColor, lineWidth: 1)
                )
            }
        }
    }

    private func memberHealthRowView(_ row: MemberHealthRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(row.dimension)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
            if let note = row.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Brand.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.dimension), \(row.value)\(row.note.map { ", \($0)" } ?? "")")
    }

    // MARK: Member-level intelligence (Members tab)
    //
    // Server-authoritative per-member rankings. The RPC enforces admin-only
    // access and the data is operator-facing only — never publicly surfaced.
    // Tone is recognition / operational reliability awareness, not
    // leaderboard / shaming.

    private var memberActivity: [ClubMemberActivity] {
        appState.memberActivityByClubID[club.id] ?? []
    }

    /// Top member by attendance count (preferred, since check-in is the
    /// strongest commitment signal), falling back to bookings when no
    /// attendance data exists. Requires a minimum activity threshold so a
    /// single-session member doesn't get the spotlight.
    private var mostActiveMember: ClubMemberActivity? {
        let qualified = memberActivity.filter { ($0.attendanceCount + $0.bookingCount) >= 4 }
        return qualified.max { lhs, rhs in
            (lhs.attendanceCount, lhs.bookingCount) < (rhs.attendanceCount, rhs.bookingCount)
        }
    }

    /// Members with elevated late-cancellation activity. Threshold of 3+
    /// avoids surfacing single-event noise. Capped at 2 rows so the section
    /// stays a calm operational nudge, not a shame list.
    private var reliabilityWatchList: [ClubMemberActivity] {
        memberActivity
            .filter { $0.cancellationCount >= 3 }
            .sorted { $0.cancellationCount > $1.cancellationCount }
            .prefix(2)
            .map { $0 }
    }

    /// Members who were meaningfully active in the prior window but have
    /// gone quiet in the current window AND haven't played in the last 21
    /// days. These are the highest-value re-engagement targets.
    private var previouslyActiveList: [ClubMemberActivity] {
        memberActivity
            .filter {
                $0.priorBookingCount >= 3
                && $0.bookingCount == 0
                && ($0.daysSinceLastPlayed ?? 0) >= 21
            }
            .sorted {
                // Primary sort: who was MOST active before going quiet.
                // Secondary sort: most recently active first within that group.
                if $0.priorBookingCount != $1.priorBookingCount {
                    return $0.priorBookingCount > $1.priorBookingCount
                }
                return ($0.daysSinceLastPlayed ?? .max) < ($1.daysSinceLastPlayed ?? .max)
            }
            .prefix(5)
            .map { $0 }
    }

    @ViewBuilder
    private var mostActiveMemberSection: some View {
        if let top = mostActiveMember {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Most active")
                memberCardSurface {
                    memberRow(
                        activity: top,
                        primary: top.displayName,
                        secondary: mostActiveSecondary(top)
                    )
                }
            }
        }
    }

    private func mostActiveSecondary(_ m: ClubMemberActivity) -> String {
        if m.attendanceCount > 0 {
            return "\(m.attendanceCount) \(m.attendanceCount == 1 ? "session" : "sessions") attended this period"
        }
        return "\(m.bookingCount) \(m.bookingCount == 1 ? "session" : "sessions") booked this period"
    }

    @ViewBuilder
    private var reliabilityWatchSection: some View {
        let rows = reliabilityWatchList
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Reliability watch")
                memberCardSurface {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, member in
                        memberRow(
                            activity: member,
                            primary: member.displayName,
                            secondary: reliabilitySecondary(member)
                        )
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Brand.dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    /// Tone is reliability-focused, not punitive. "Frequent late withdrawals"
    /// when sustained, "High cancellation activity" otherwise. Never "worst"
    /// language — this is operational awareness, not a shame list.
    private func reliabilitySecondary(_ m: ClubMemberActivity) -> String {
        let label = m.cancellationCount >= 6 ? "Frequent late withdrawals" : "High cancellation activity"
        return "\(label) · \(m.cancellationCount) this period"
    }

    @ViewBuilder
    private var previouslyActiveSection: some View {
        let rows = previouslyActiveList
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Previously active")
                memberCardSurface {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, member in
                        memberRow(
                            activity: member,
                            primary: member.displayName,
                            secondary: previouslyActiveSecondary(member)
                        )
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Brand.dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private func previouslyActiveSecondary(_ m: ClubMemberActivity) -> String {
        guard let days = m.daysSinceLastPlayed else { return "Inactive" }
        if days < 30 { return "Last active \(days) days ago" }
        let weeks = days / 7
        if weeks < 12 { return "Last active \(weeks) \(weeks == 1 ? "week" : "weeks") ago" }
        let months = days / 30
        return "Last active \(months) \(months == 1 ? "month" : "months") ago"
    }

    /// Compact operator-row helper used by all three member-intel sections.
    /// Avatar + two-line text + no chevron (no actions yet — "DO NOT build
    /// actions yet" per the Phase 2 spec; just surface the intelligence).
    private func memberRow(activity: ClubMemberActivity, primary: String, secondary: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            memberAvatar(activity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(primary). \(secondary).")
    }

    /// Neutral identity avatar — grey surface + initials. Deliberately
    /// understated so reliability/dormancy sections never read as social
    /// or gamified. A future Phase can resolve avatarColorKey through the
    /// avatar_palettes system if richer identity is desired.
    private func memberAvatar(_ activity: ClubMemberActivity) -> some View {
        ZStack {
            Circle()
                .fill(Brand.secondarySurface)
                .frame(width: 32, height: 32)
            Text(activity.initials)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Brand.secondaryText)
        }
    }

    /// Shared card chrome for member intel sections — same 12pt corner +
    /// hairline as other Pulse cards so the Members tab stays cohesive.
    private func memberCardSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.dividerColor, lineWidth: 1)
            )
    }

    // MARK: Period selector (Revenue tab)

    private var periodSelector: some View {
        HStack(spacing: 4) {
            ForEach(AnalyticsPeriod.allCases) { p in
                Button { period = p } label: {
                    Text(p.pulseShortLabel)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(period == p ? Brand.primaryText : Brand.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            period == p ? Brand.cardBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    period == p ? Brand.dividerColor : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.pulseDisplayLabel)
                .accessibilityAddTraits(period == p ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Revenue locked / placeholders

    private var revenueLockedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.slateBlue)
                    .frame(width: 28, height: 28)
                    .background(Brand.slateBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Revenue analytics on Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
            }
            Text("Upgrade your plan to unlock revenue trends, breakdowns, and trustworthy financial reporting for your club.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
    }

    private func loadingPlaceholder(_ msg: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(msg)
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
    }

    private func emptyPlaceholder(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.tertiaryText)
                .frame(width: 26, height: 26)
                .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
    }

    private func emptyTabBody(_ msg: String) -> some View {
        Text(msg)
            .font(.footnote)
            .foregroundStyle(Brand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    // MARK: Revenue breakdown (Revenue tab)

    private func breakdownTable(kpis k: ClubAnalyticsKPIs) -> some View {
        let code = k.currency
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Breakdown")
            VStack(spacing: 0) {
                breakdownRow(label: "Net revenue",
                             value: PulseFormatters.currency(k.currRevenueCents, code: code),
                             highlight: true)
                breakdownDivider
                breakdownRow(label: "Gross revenue",
                             value: PulseFormatters.currency(k.currGrossRevenueCents, code: code))
                breakdownDivider
                breakdownRow(label: "Platform fees",
                             value: "−" + PulseFormatters.currency(k.currPlatformFeeCents, code: code),
                             muted: true)
                if k.currManualRevenueCents > 0 {
                    breakdownDivider
                    breakdownRow(label: "Cash revenue",
                                 value: PulseFormatters.currency(k.currManualRevenueCents, code: code))
                }
                if k.currCreditsUsedCents > 0 {
                    breakdownDivider
                    breakdownRow(label: "Credits used",
                                 value: PulseFormatters.currency(k.currCreditsUsedCents, code: code),
                                 muted: true)
                }
                if k.currCreditsReturnedCents > 0 {
                    breakdownDivider
                    breakdownRow(label: "Credits returned",
                                 value: PulseFormatters.currency(k.currCreditsReturnedCents, code: code),
                                 muted: true)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.dividerColor, lineWidth: 1)
            )
        }
    }

    private func breakdownRow(label: String, value: String, highlight: Bool = false, muted: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(highlight ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(highlight ? Brand.primaryText : (muted ? Brand.secondaryText : Brand.primaryText))
            Spacer()
            Text(value)
                .font(highlight ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(highlight ? Brand.primaryText : (muted ? Brand.secondaryText : Brand.primaryText))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var breakdownDivider: some View {
        Rectangle()
            .fill(Brand.dividerColor)
            .frame(height: 0.5)
    }

    // MARK: Child-sheet routing

    @ViewBuilder
    private func childSheetContent(_ sheet: OwnerToolSheet) -> some View {
        switch sheet {
        case .editClub:
            // Reachable from the setup-issues banner — the only management
            // sheet Pulse opens directly.
            OwnerEditClubSheet(club: club).environmentObject(appState)
        case .dashboard, .analytics, .manageGames, .joinRequests,
             .createGame, .members, .roleHistory:
            // Defensive no-op. Pulse never re-presents itself or duplicates
            // Manage Club hub navigation.
            EmptyView()
        }
    }
}

// MARK: - PulseDelta + PulseKPICell value types

struct PulseDelta {
    let label: String
    let isPositive: Bool
}

struct PulseKPICell {
    let label: String
    let value: String
    let delta: PulseDelta?
    let isCurrency: Bool
}

// MARK: - Calm financial accent palette

/// Centralized desaturated palette for financial signaling. Used across the
/// Pulse view so revenue / positive deltas / chart accents speak in one
/// trustworthy voice — never the brand neon.
enum PulseColors {
    /// Calm forest green — positive revenue / growth signal.
    static let positiveAccent = Color(hex: "2F7A52")
    /// Muted oxide red — negative deltas, never alarmist.
    static let negativeAccent = Color(hex: "B83B3B")
}

// MARK: - Pulse insight model

enum PulseInsightTone {
    case positive
    case negative
    case attention
    case observation

    var symbol: String {
        switch self {
        case .positive:    return "arrow.up.right"
        case .negative:    return "arrow.down.right"
        case .attention:   return "exclamationmark"
        case .observation: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .positive:    return PulseColors.positiveAccent
        case .negative:    return PulseColors.negativeAccent
        case .attention:   return Brand.spicyOrange
        case .observation: return Brand.slateBlue
        }
    }
}

/// Category determines which tab an insight surfaces in. Overview shows
/// every category sorted by severity; the dedicated tabs filter to their
/// own category. `general` insights surface only in Overview (cross-cutting
/// operational signals that don't belong to a single domain).
enum PulseInsightCategory: Hashable {
    case revenue
    case members
    case operations
    case general
}

enum PulseDestination {
    case ownerSheet(OwnerToolSheet)
}

struct PulseInsight: Identifiable {
    let id = UUID()
    let tone: PulseInsightTone
    let category: PulseInsightCategory
    let headline: String
    let detail: String?
    let severity: Double
    let destination: PulseDestination?
}

// MARK: - Pulse insight builder

/// Produces ranked, category-tagged operational insights from already-fetched
/// analytics data. Never invents content — only emits a row when the
/// underlying signal is real. Rules of restraint:
///   - require a minimum sample where statistics drive the headline
///   - drop cells under thresholds (e.g. <5% movement) so nothing reads filler
///   - severity is a deterministic function of distance-from-baseline
enum PulseInsightBuilder {
    /// Total cap across all categories; per-tab views apply their own
    /// `prefix(...)` for what they surface.
    static let maxInsights = 16

    static func build(
        summary: ClubDashboardSummary?,
        kpis: ClubAnalyticsKPIs?,
        supplemental: ClubAnalyticsSupplemental?,
        topGames: [ClubTopGame],
        peakTimes: [ClubPeakTime],
        pendingRequestCount: Int,
        currencyCode: String?
    ) -> [PulseInsight] {
        var out: [PulseInsight] = []

        // GENERAL — operational signals that span domains
        if pendingRequestCount > 0 {
            out.append(PulseInsight(
                tone: .attention,
                category: .general,
                headline: "\(pendingRequestCount) join \(pendingRequestCount == 1 ? "request" : "requests") awaiting approval",
                detail: "Review from the club's Members area.",
                severity: 0.78,
                destination: nil
            ))
        }

        // REVENUE
        if let k = kpis, k.prevRevenueCents > 0 {
            let pct = Double(k.currRevenueCents - k.prevRevenueCents) / Double(k.prevRevenueCents) * 100
            let absPct = abs(pct)
            if absPct >= 5 {
                let tone: PulseInsightTone = pct >= 0 ? .positive : .negative
                let sign = pct >= 0 ? "+" : "−"
                let curr = PulseFormatters.currency(k.currRevenueCents, code: currencyCode)
                let prev = PulseFormatters.currency(k.prevRevenueCents, code: currencyCode)
                out.append(PulseInsight(
                    tone: tone,
                    category: .revenue,
                    headline: "Revenue \(sign)\(String(format: "%.0f", absPct))% vs previous period",
                    detail: "\(curr) this period · \(prev) prior",
                    severity: 0.9 * min(absPct / 25, 1.0) + 0.1,
                    destination: nil
                ))
            }
        }

        if let k = kpis, k.currCreditReturnCount > 0 {
            let amount = PulseFormatters.currency(k.currCreditsReturnedCents, code: currencyCode)
            let n = k.currCreditReturnCount
            out.append(PulseInsight(
                tone: .observation,
                category: .revenue,
                headline: "\(n) \(n == 1 ? "spot" : "spots") refilled by waitlist · \(amount) returned in credits",
                detail: "Replacements confirmed automatically.",
                severity: 0.35,
                destination: nil
            ))
        }

        if let k = kpis, k.currManualRevenueCents > 0, k.currRevenueCents > 0 {
            let cashShare = Double(k.currManualRevenueCents) / Double(k.currRevenueCents)
            if cashShare >= 0.4 {
                out.append(PulseInsight(
                    tone: .observation,
                    category: .revenue,
                    headline: "\(Int(round(cashShare * 100)))% of revenue is cash this period",
                    detail: "Stripe payouts cover the remainder.",
                    severity: 0.30,
                    destination: nil
                ))
            }
        }

        // MEMBERS
        if let s = summary {
            let curr = s.monthlyActivePlayers30d
            let prev = s.prevActivePlayers30d
            let diff = curr - prev
            let baseline = max(prev, 1)
            let ratio = abs(Double(diff)) / Double(baseline)
            if abs(diff) >= 3 || ratio >= 0.15, diff != 0 {
                let tone: PulseInsightTone = diff > 0 ? .positive : .attention
                let sign = diff > 0 ? "+" : "−"
                out.append(PulseInsight(
                    tone: tone,
                    category: .members,
                    headline: "\(sign)\(abs(diff)) active \(abs(diff) == 1 ? "player" : "players") this month",
                    detail: "\(curr) playing now · \(prev) prior month",
                    severity: diff > 0 ? 0.55 : 0.72,
                    destination: nil
                ))
            }
        }

        if let s = summary, s.memberGrowth30d >= 1 {
            let n = s.memberGrowth30d
            out.append(PulseInsight(
                tone: .positive,
                category: .members,
                headline: "\(n) new \(n == 1 ? "member" : "members") joined this month",
                detail: "\(s.totalMembers) members total",
                severity: 0.4 + min(Double(n) / 25.0, 0.25),
                destination: nil
            ))
        }

        if let s = supplemental, s.currNewPlayers >= 2 {
            let n = s.currNewPlayers
            out.append(PulseInsight(
                tone: .positive,
                category: .members,
                headline: "\(n) first-time \(n == 1 ? "player" : "players") booked at this club",
                detail: "Last \(periodLabelFromSupplemental(s)).",
                severity: 0.45,
                destination: nil
            ))
        }

        if let k = kpis, k.currBookingCount >= 10, k.repeatPlayerRate >= 0.6 {
            out.append(PulseInsight(
                tone: .positive,
                category: .members,
                headline: "\(String(format: "%.0f", k.repeatPlayerRate * 100))% of players returned this period",
                detail: "Most players came back at least once.",
                severity: 0.4,
                destination: nil
            ))
        }

        // OPERATIONS
        if let s = summary, let curr = s.fillRate30d, let prev = s.prevFillRate30d {
            let diffPP = (curr - prev) * 100
            if abs(diffPP) >= 5 {
                let tone: PulseInsightTone = diffPP >= 0 ? .positive : .attention
                let sign = diffPP >= 0 ? "+" : "−"
                out.append(PulseInsight(
                    tone: tone,
                    category: .operations,
                    headline: "Fill rate \(sign)\(String(format: "%.0f", abs(diffPP))) pts vs prior month",
                    detail: "\(String(format: "%.0f", curr * 100))% now · \(String(format: "%.0f", prev * 100))% prior",
                    severity: diffPP >= 0 ? 0.55 : 0.7,
                    destination: nil
                ))
            }
        }

        if let fastest = topGames
            .filter({ $0.avgTimeToFillMinutes != nil && $0.occurrenceCount >= 2 })
            .min(by: { ($0.avgTimeToFillMinutes ?? .infinity) < ($1.avgTimeToFillMinutes ?? .infinity) }),
           let mins = fastest.avgTimeToFillMinutes {
            let timeStr = PulseFormatters.duration(minutes: mins)
            out.append(PulseInsight(
                tone: .observation,
                category: .operations,
                headline: "\(fastest.dayLabel) \(fastest.hourLabel) \(fastest.title) fills in \(timeStr)",
                detail: "\(fastest.occurrenceCount) sessions · \(String(format: "%.0f", fastest.avgFillRate * 100))% avg fill",
                severity: 0.6,
                destination: nil
            ))
        }

        if let topWait = peakTimes
            .filter({ $0.avgWaitlist >= 2.5 && $0.gameCount >= 2 })
            .max(by: { $0.avgWaitlist < $1.avgWaitlist }) {
            out.append(PulseInsight(
                tone: .observation,
                category: .operations,
                headline: "\(topWait.dayLabel) \(topWait.hourLabel) averages \(String(format: "%.1f", topWait.avgWaitlist)) on waitlist",
                detail: "Demand exceeds supply — consider adding a session.",
                severity: 0.65,
                destination: nil
            ))
        }

        if let k = kpis, k.currBookingCount >= 10 {
            if k.cancellationRate >= 0.18 {
                out.append(PulseInsight(
                    tone: .attention,
                    category: .operations,
                    headline: "Cancellation rate \(String(format: "%.0f", k.cancellationRate * 100))% — above benchmark",
                    detail: "Above the 15% target — review session timing or fees.",
                    severity: 0.8,
                    destination: nil
                ))
            } else if k.cancellationRate <= 0.05 {
                out.append(PulseInsight(
                    tone: .positive,
                    category: .operations,
                    headline: "Cancellation rate just \(String(format: "%.0f", k.cancellationRate * 100))%",
                    detail: "Members are showing up consistently.",
                    severity: 0.4,
                    destination: nil
                ))
            }
        }

        if let s = supplemental, let rate = s.noShowRate, s.currCheckedCount >= 10, rate >= 0.15 {
            out.append(PulseInsight(
                tone: .attention,
                category: .operations,
                headline: "No-show rate \(String(format: "%.0f", rate * 100))% — above target",
                detail: "\(s.currNoShowCount) no-shows of \(s.currCheckedCount) checked-in.",
                severity: 0.7,
                destination: nil
            ))
        }

        out.sort { $0.severity > $1.severity }
        return Array(out.prefix(maxInsights))
    }

    /// Best-effort period label for "Last N days" in member detail copy.
    /// Supplemental currently spans the same window the user picked for
    /// advanced analytics; without a period field on the row, fall back to
    /// a generic label.
    private static func periodLabelFromSupplemental(_ s: ClubAnalyticsSupplemental) -> String {
        return "this period"
    }
}

// MARK: - Pulse row

private struct PulseRow: View {
    let insight: PulseInsight
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(insight.tone.tint.opacity(0.14))
                        .frame(width: 26, height: 26)
                    Image(systemName: insight.tone.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(insight.tone.tint)
                }
                .padding(.top, 1)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(insight.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                    if let detail = insight.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Brand.secondaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if insight.destination != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.softOutline)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(insight.destination == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(insight.destination != nil ? .isButton : [])
        .accessibilityHint(insight.destination != nil ? "Opens detail view" : "")
    }

    private var accessibilityLabelText: String {
        let toneTag: String
        switch insight.tone {
        case .positive:    toneTag = "Positive"
        case .negative:    toneTag = "Negative"
        case .attention:   toneTag = "Needs attention"
        case .observation: toneTag = "Insight"
        }
        if let detail = insight.detail {
            return "\(toneTag). \(insight.headline). \(detail)"
        }
        return "\(toneTag). \(insight.headline)"
    }
}

// MARK: - Compact revenue strip (Overview)

private struct PulseRevenueStripCompact: View {
    let kpis: ClubAnalyticsKPIs
    let trend: [ClubRevenueTrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PulseFormatters.currency(kpis.currRevenueCents, code: kpis.currency))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.primaryText)
                    .monospacedDigit()
                deltaInline
                Spacer(minLength: 8)
            }
            if !trend.isEmpty {
                PulseSparkline(points: trend, accent: PulseColors.positiveAccent)
                    .frame(height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.025), radius: 4, x: 0, y: 1)
    }

    @ViewBuilder
    private var deltaInline: some View {
        if kpis.prevRevenueCents > 0 {
            let diff = kpis.currRevenueCents - kpis.prevRevenueCents
            let pct = Double(diff) / Double(kpis.prevRevenueCents) * 100
            let isPos = diff >= 0
            let absPct = abs(pct)
            HStack(spacing: 2) {
                Image(systemName: isPos ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(String(format: "%.0f", absPct))%")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(isPos ? PulseColors.positiveAccent : PulseColors.negativeAccent)
        }
    }
}

// MARK: - Expanded revenue strip (Revenue tab)

/// Larger, more authoritative variant for the dedicated Revenue tab.
/// More breathing room around the hero number, bigger sparkline, the
/// "NET REVENUE" label restored as a financial-statement caption.
private struct PulseRevenueStripExpanded: View {
    let kpis: ClubAnalyticsKPIs
    let trend: [ClubRevenueTrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NET REVENUE")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(Brand.tertiaryText)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(PulseFormatters.currency(kpis.currRevenueCents, code: kpis.currency))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.primaryText)
                        .monospacedDigit()
                    deltaInline
                    Spacer(minLength: 0)
                }
            }
            if !trend.isEmpty {
                PulseSparkline(points: trend, accent: PulseColors.positiveAccent)
                    .frame(height: 88)
                    .accessibilityLabel("Revenue trend over the selected period")
                    .accessibilityValue(trendAccessibilityValue)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    private var trendAccessibilityValue: String {
        let totals = trend.map { $0.revenueCents }
        guard let lo = totals.min(), let hi = totals.max() else { return "" }
        return "Range \(PulseFormatters.currency(lo, code: kpis.currency)) to \(PulseFormatters.currency(hi, code: kpis.currency))"
    }

    @ViewBuilder
    private var deltaInline: some View {
        if kpis.prevRevenueCents > 0 {
            let diff = kpis.currRevenueCents - kpis.prevRevenueCents
            let pct = Double(diff) / Double(kpis.prevRevenueCents) * 100
            let isPos = diff >= 0
            let absPct = abs(pct)
            HStack(spacing: 2) {
                Image(systemName: isPos ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(String(format: "%.0f", absPct))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(isPos ? PulseColors.positiveAccent : PulseColors.negativeAccent)
        }
    }
}

// MARK: - Sparkline

/// Calm financial sparkline — desaturated accent, restrained line weight,
/// very subtle area fill. Height is configurable so Overview can render a
/// compact glance and Revenue tab can render an authoritative trend.
private struct PulseSparkline: View {
    let points: [ClubRevenueTrendPoint]
    var accent: Color = Brand.primaryText

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Date", point.bucketDate),
                y: .value("Revenue", point.revenueCents)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(
                    colors: [accent.opacity(0.10), accent.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Date", point.bucketDate),
                y: .value("Revenue", point.revenueCents)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(accent.opacity(0.85))
            .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
    }
}

// MARK: - Formatters

enum PulseFormatters {
    static func currency(_ cents: Int, code: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code ?? "AUD"
        formatter.maximumFractionDigits = 0
        let value = Double(cents) / 100.0
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    static func currencyShort(_ cents: Int, code: String?) -> String {
        currency(cents, code: code)
    }

    static func relative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    /// Friendly fill-time label. Sub-hour minutes; sub-day hours with one
    /// decimal; days otherwise.
    static func duration(minutes: Double) -> String {
        if minutes < 60 {
            return "\(Int(minutes.rounded())) min"
        }
        if minutes < 60 * 24 {
            let h = minutes / 60
            if abs(h - h.rounded()) < 0.05 {
                return "\(Int(h.rounded())) hr"
            }
            return String(format: "%.1f hr", h)
        }
        let d = minutes / (60 * 24)
        return String(format: "%.1f days", d)
    }
}
