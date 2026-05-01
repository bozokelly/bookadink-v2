// ClubDashboardView.swift
// Full-screen club admin control surface — tier, metrics, and section navigation.
// Owns its own child-sheet routing so back from any child returns here.
// No backend changes. Display-only metrics. No new features.

import SwiftUI
import UIKit

struct ClubDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club

    @Environment(\.scenePhase) private var scenePhase
    private let isOnIPad = UIDevice.current.userInterfaceIdiom == .pad

    // Child-sheet state owned here — NOT delegated to parent ClubDetailView.
    // This ensures: Club View → Dashboard → Child → back → Dashboard → back → Club View.
    @State private var childSheet: OwnerToolSheet?
    // Guards Setup & Issues against flashing stale cached stripe nil on open.
    @State private var stripeStatusLoaded = false
    // Prevents concurrent refreshAll() calls (task + scenePhase can both fire on appear).
    @State private var isRefreshingDashboard = false

    // MARK: - Derived state

    private var entitlements: ClubEntitlements? {
        appState.entitlementsByClubID[club.id]
    }
    private var planTier: String {
        entitlements?.planTier ?? "free"
    }
    private var members: [ClubDirectoryMember] {
        appState.clubDirectoryMembers(for: club)
    }
    private var pendingCount: Int {
        appState.ownerJoinRequests(for: club).count
    }
    private var kpis: ClubAnalyticsKPIs? {
        appState.analyticsKPIsByClubID[club.id]
    }
    private var summary: ClubDashboardSummary? {
        appState.dashboardSummaryByClubID[club.id]
    }
    private var analyticsLocked: Bool {
        if case .blocked = FeatureGateService.canAccessAnalytics(entitlements) { return true }
        return false
    }
    private var upcomingGamesCount: Int {
        appState.games(for: club)
            .filter { $0.status != "cancelled" && $0.dateTime >= Date() }
            .filter { isClubAdminUser || ($0.publishAt == nil || $0.publishAt! <= Date()) }
            .count
    }
    private var isClubAdminUser: Bool {
        appState.isClubAdmin(for: club)
    }

    // MARK: - Setup & Issues

    private var stripeAccount: ClubStripeAccount? {
        appState.stripeAccountByClubID[club.id]
    }

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
            case .planRequired:              return "Payment Processing Disabled"
            case .stripeNotConfigured:       return "Stripe Not Connected"
            case .stripeVerificationPending: return "Stripe Verification Pending"
            }
        }
        var detail: String {
            switch self {
            case .planRequired:              return "Upgrade to Starter or Pro to accept booking fees."
            case .stripeNotConfigured:       return "Connect Stripe in Club Settings → Payments to collect fees."
            case .stripeVerificationPending: return "Stripe is reviewing your account. Payments activate once verified."
            }
        }
        var isCritical: Bool {
            switch self {
            case .planRequired, .stripeNotConfigured: return true
            case .stripeVerificationPending:          return false
            }
        }
    }

    // Only non-nil when paid games exist AND a confirmed issue is detected.
    // Fails closed on entitlements (nil = don't show — avoid false positives during load).
    private var activeSetupIssue: SetupIssue? {
        guard paidUpcomingGamesCount > 0, let e = entitlements else { return nil }
        if !e.canAcceptPayments          { return .planRequired }
        if stripeAccount == nil          { return .stripeNotConfigured }
        if stripeAccount?.payoutsEnabled == false { return .stripeVerificationPending }
        return nil
    }

    // All three payment-readiness checks pass.
    private var paymentSetupComplete: Bool {
        guard let e = entitlements else { return false }
        return e.canAcceptPayments && (stripeAccount?.payoutsEnabled == true)
    }

    // The section is shown when there is a confirmed issue OR setup is incomplete (checklist needed).
    // stripeStatusLoaded prevents the section from flashing on open while cached stripe data is nil.
    private var shouldShowSetupSection: Bool {
        guard stripeStatusLoaded, entitlements != nil else { return false }
        return activeSetupIssue != nil || !paymentSetupComplete
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let sub = appState.subscriptionsByClubID[club.id], sub.isPastDue {
                        Label("Payment failed — update your billing details in Plan & Billing to restore access.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.horizontal)
                    }
                    setupAndIssuesSection
                    primaryActionsRow
                    metricsSection
                    navCardsSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .refreshable { await refreshAll() }
            .background(Brand.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(club.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                            .lineLimit(1)
                        Text("Admin Dashboard")
                            .font(.caption2)
                            .foregroundStyle(Brand.tertiaryText)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(Brand.secondarySurface, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only render when entitlements have loaded — avoids showing
                    // "Free Plan" as a false default while the fetch is in-flight.
                    if entitlements != nil { tierPill }
                }
            }
            // iPhone: sheet (swipe-to-dismiss). iPad: fullScreenCover (uses the full canvas).
            .sheet(item: Binding(
                get: { isOnIPad ? nil : childSheet },
                set: { childSheet = $0 }
            )) { sheet in childSheetContent(sheet) }
            .fullScreenCover(item: Binding(
                get: { isOnIPad ? childSheet : nil },
                set: { childSheet = $0 }
            )) { sheet in childSheetContent(sheet) }
        }
        .task { await refreshAll() }
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

    // MARK: - Data Refresh

    private func refreshAll() async {
        guard !isRefreshingDashboard else { return }
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        async let fetchEntitlements: Void = appState.fetchClubEntitlements(for: club.id)
        async let fetchMembers: Void = appState.refreshClubDirectoryMembers(for: club)
        async let fetchSummary: Void = appState.loadDashboardSummary(for: club.id)
        async let fetchStripe: Void = appState.refreshStripeAccountStatus(for: club.id)
        _ = await (fetchEntitlements, fetchMembers, fetchSummary, fetchStripe)

        stripeStatusLoaded = true

        if !paymentSetupComplete {
            await LocalNotificationManager.shared.scheduleSetupReminderIfNeeded(
                clubID: club.id, clubName: club.name
            )
        } else {
            LocalNotificationManager.shared.cancelSetupReminder(for: club.id)
        }

        // Always fetch analytics when unlocked — no nil guard so re-opens get fresh data.
        if !analyticsLocked {
            await appState.fetchClubAdvancedAnalytics(for: club.id, days: 30)
        }

        #if DEBUG
        let s = appState.dashboardSummaryByClubID[club.id]
        let e = appState.entitlementsByClubID[club.id]
        let sa = appState.stripeAccountByClubID[club.id]
        print("""
        [Dashboard] club=\(club.name) \
        members=\(s?.totalMembers ?? -1) \
        activePlayers=\(s?.monthlyActivePlayers30d ?? -1) \
        upcomingBookings=\(s?.upcomingBookingsCount ?? -1) \
        fillRate=\(s?.fillRate30d.map { String(format: "%.0f%%", $0 * 100) } ?? "nil") \
        plan=\(e?.planTier ?? "nil") \
        analyticsAccess=\(e?.analyticsAccess ?? false) \
        payoutsEnabled=\(sa?.payoutsEnabled ?? false) \
        refreshedAt=\(Date())
        """)
        #endif
    }

    // MARK: - Child Sheet Router

    @ViewBuilder
    private func childSheetContent(_ sheet: OwnerToolSheet) -> some View {
        switch sheet {
        case .dashboard:
            EmptyView() // should never be triggered from here
        case .manageGames:
            OwnerManageGamesView(club: club).environmentObject(appState)
        case .joinRequests:
            OwnerJoinRequestsSheet(club: club).environmentObject(appState)
        case .createGame:
            OwnerCreateGameSheet(club: club).environmentObject(appState)
        case .editClub:
            OwnerEditClubSheet(club: club).environmentObject(appState)
        case .members:
            OwnerMembersSheet(club: club).environmentObject(appState)
        case .analytics:
            AnalyticsSheet(club: club).environmentObject(appState)
        }
    }

    // MARK: - Setup & Issues Section

    @ViewBuilder
    private var setupAndIssuesSection: some View {
        if shouldShowSetupSection {
            VStack(alignment: .leading, spacing: 10) {
                Text("Setup & Issues")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.tertiaryText)
                    .textCase(.uppercase)
                    .tracking(0.5)

                // Critical / warning issue card
                if let issue = activeSetupIssue {
                    let n = paidUpcomingGamesCount
                    Button { childSheet = .editClub } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: issue.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(issue.isCritical ? Brand.errorRed : Brand.spicyOrange)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(issue.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Brand.primaryText)
                                    Text("\(n) game\(n == 1 ? "" : "s") affected")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            (issue.isCritical ? Brand.errorRed : Brand.spicyOrange).opacity(0.9),
                                            in: Capsule()
                                        )
                                }
                                Text(issue.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Brand.mutedText)
                        }
                        .padding(14)
                        .background(
                            (issue.isCritical ? Brand.errorRed : Brand.spicyOrange).opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    (issue.isCritical ? Brand.errorRed : Brand.spicyOrange).opacity(0.25),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Payment readiness checklist — shown until all items are complete
                if !paymentSetupComplete {
                    paymentChecklistCard
                }
            }
        }
    }

    private var paymentChecklistCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            checklistRow(
                label: "Plan supports paid bookings",
                done: entitlements?.canAcceptPayments == true,
                action: entitlements?.canAcceptPayments == true ? nil : { childSheet = .editClub }
            )
            Divider().padding(.leading, 44)
            checklistRow(
                label: "Stripe account connected",
                done: stripeAccount != nil,
                action: stripeAccount != nil ? nil : { childSheet = .editClub }
            )
            Divider().padding(.leading, 44)
            checklistRow(
                label: "Payouts enabled",
                done: stripeAccount?.payoutsEnabled == true,
                action: stripeAccount?.payoutsEnabled == true ? nil : { childSheet = .editClub }
            )
        }
        .background(Brand.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func checklistRow(label: String, done: Bool, action: (() -> Void)?) -> some View {
        let content = HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(done ? Brand.emeraldAction : Brand.tertiaryText)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(done ? Brand.primaryText : Brand.secondaryText)
            Spacer(minLength: 0)
            if !done {
                Text("Fix →")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.slateBlue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        if let action, !done {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: - Tier Pill

    private var tierPill: some View {
        let (label, icon, isPro): (String, String, Bool) = {
            switch planTier.lowercased() {
            case "pro":     return ("Pro Plan", "bolt.fill", true)
            case "starter": return ("Starter",  "star.fill", false)
            default:        return ("Free Plan", "",          false)
            }
        }()

        // Wrapped in a disabled Button with .plain style to suppress iOS 17's
        // automatic toolbar item background container, leaving our capsule as
        // the only visual layer. No stroke overlay — that was creating the
        // inner-border appearance that made it look like a pill within a pill.
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

    // MARK: - Primary Actions

    private var primaryActionsRow: some View {
        HStack(spacing: 12) {
            // Add Game — primary CTA
            Button { childSheet = .createGame } label: {
                Label("Add Game", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Brand.primaryText)
                    .background(Brand.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            // Requests — secondary CTA, urgent styling when count > 0
            Button { childSheet = .joinRequests } label: {
                HStack(spacing: 6) {
                    Text("Requests")
                        .font(.subheadline.weight(.semibold))
                    if pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.errorRed, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(pendingCount > 0 ? Brand.errorRed : Brand.primaryText)
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            pendingCount > 0 ? Brand.errorRed.opacity(0.5) : Brand.softOutline,
                            lineWidth: pendingCount > 0 ? 1.5 : 1
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.tertiaryText)
                .textCase(.uppercase)
                .tracking(0.5)

            heroMetricCard

            HStack(spacing: 10) {
                supportingMetric(
                    label: "Members",
                    value: membersValue,
                    subtext: membersSubtext,
                    delta: membersDelta
                )
                supportingMetric(
                    label: "Fill Rate",
                    value: fillRateDisplay,
                    subtext: fillRateSubtext,
                    delta: fillRateDelta
                )
                supportingMetric(
                    label: "Bookings",
                    value: bookingsDisplay,
                    subtext: bookingsSubtext,
                    delta: bookingsDelta
                )
            }
        }
    }

    // Hero active players card
    private var heroMetricCard: some View {
        // Prefer the ungated dashboard summary; fall back to Pro KPIs if available.
        let curr = summary?.monthlyActivePlayers30d ?? kpis?.currActivePlayers
        let prev = summary?.prevActivePlayers30d    ?? kpis?.prevActivePlayers
        let delta: String? = {
            guard let c = curr, let p = prev, p > 0 || c > 0 else { return nil }
            let diff = c - p
            if diff == 0 { return "Same as last month" }
            return diff > 0 ? "+\(diff) vs last month" : "\(diff) vs last month"
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Monthly Active Players")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                Spacer(minLength: 0)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.tertiaryText)
            }

            if let value = curr {
                Text("\(value)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.primaryText)
            } else {
                Text("No data yet")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Brand.tertiaryText)
            }

            if let d = delta {
                deltaLabel(d)
            } else if curr != nil {
                Text("last 30 days")
                    .font(.caption2)
                    .foregroundStyle(Brand.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Supporting metric helpers

    // Members
    private var membersValue: String {
        if let s = summary { return s.totalMembers > 0 ? "\(s.totalMembers)" : "—" }
        return members.count > 0 ? "\(members.count)" : "—"
    }
    private var membersDelta: String? {
        guard let s = summary, s.totalMembers > 0 else { return nil }
        if s.memberGrowth30d == 0 { return "No change" }
        return "+\(s.memberGrowth30d) this month"
    }
    private var membersSubtext: String? {
        guard let s = summary else {
            return members.count > 0 ? nil : "No members yet"
        }
        return s.totalMembers == 0 ? "No members yet" : nil
    }

    // Fill Rate — prefer summary (ungated), fall back to Pro KPIs
    private var fillRateDisplay: String {
        if let s = summary {
            // summary loaded: show rate if data exists, "—" if no qualifying games
            guard let r = s.fillRate30d else { return "—" }
            return String(format: "%.0f%%", r * 100)
        }
        guard let r = kpis?.currFillRate else { return "—" }
        return String(format: "%.0f%%", r * 100)
    }
    private var fillRateSubtext: String? {
        if let s = summary { return s.fillRate30d != nil ? "avg per game" : "No data yet" }
        return kpis != nil ? "avg per game" : nil
    }
    private var fillRateDelta: String? {
        if let s = summary {
            guard let c = s.fillRate30d, let p = s.prevFillRate30d else { return nil }
            let diff = (c - p) * 100
            if abs(diff) < 0.5 { return nil }
            return diff > 0 ? String(format: "+%.0f%%", diff) : String(format: "%.0f%%", diff)
        }
        guard let c = kpis?.currFillRate, let p = kpis?.prevFillRate else { return nil }
        let diff = (c - p) * 100
        if abs(diff) < 0.5 { return nil }
        return diff > 0 ? String(format: "+%.0f%%", diff) : String(format: "%.0f%%", diff)
    }

    // Bookings — summary shows upcoming confirmed; Pro KPIs show historical last-30d
    private var bookingsDisplay: String {
        if let b = summary?.upcomingBookingsCount { return "\(b)" }
        guard let b = kpis?.currBookingCount else { return "—" }
        return "\(b)"
    }
    private var bookingsSubtext: String? {
        if summary != nil { return "upcoming" }
        return kpis != nil ? "last 30 days" : nil
    }
    private var bookingsDelta: String? {
        // Upcoming bookings is a point-in-time count; no meaningful prior-period delta.
        guard summary == nil else { return nil }
        guard let c = kpis?.currBookingCount, let p = kpis?.prevBookingCount else { return nil }
        let diff = c - p
        if diff == 0 { return nil }
        return diff > 0 ? "+\(diff)" : "\(diff)"
    }

    private func supportingMetric(label: String, value: String, subtext: String?, delta: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Brand.tertiaryText)
                .lineLimit(1)

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(value == "—" ? Brand.tertiaryText : Brand.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let d = delta {
                deltaLabel(d)
            } else if let s = subtext {
                Text(s)
                    .font(.caption2)
                    .foregroundStyle(Brand.tertiaryText)
                    .lineLimit(1)
            } else if value == "—" {
                Text("No data yet")
                    .font(.caption2)
                    .foregroundStyle(Brand.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.dividerColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Arrow icon + grey label for metric deltas.
    /// Positive ("+" prefix) → green up arrow. Negative ("-" prefix) → red down arrow.
    /// Neutral (no prefix) → grey minus icon.
    /// The "+" or "-" sign is stripped from the display text; the icon carries the direction.
    @ViewBuilder
    private func deltaLabel(_ text: String) -> some View {
        let isPos = text.hasPrefix("+")
        let isNeg = text.hasPrefix("-")
        let icon  = isPos ? "arrow.up" : isNeg ? "arrow.down" : "minus"
        let tint: Color = isPos ? Brand.accentGreen : isNeg ? Brand.errorRed : Brand.tertiaryText
        let display = (isPos || isNeg) ? String(text.dropFirst()) : text
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
            Text(display)
                .font(.caption2)
                .foregroundStyle(Brand.tertiaryText)
                .lineLimit(1)
        }
    }

    // MARK: - Navigation Cards

    private var navCardsSection: some View {
        VStack(spacing: 8) {
            Text("Manage")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.tertiaryText)
                .textCase(.uppercase)
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            if UIDevice.current.userInterfaceIdiom == .pad {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    navCard(title: "Games", icon: "calendar",
                            bullets: ["Schedule, history & player attendance"],
                            locked: false) { childSheet = .manageGames }
                    navCard(title: "Members", icon: "person.2",
                            bullets: ["Roles, approvals & contact details"],
                            locked: false) { childSheet = .members }
                    navCard(title: "Analytics", icon: "chart.bar",
                            bullets: [analyticsLocked ? "Preview available · Pro plan unlocks live data" : "Revenue, fill rate & player trends"],
                            locked: false) { childSheet = .analytics }
                    navCard(title: "Club Settings", icon: "slider.horizontal.3",
                            bullets: ["Images, courts, rules & visibility"],
                            locked: false) { childSheet = .editClub }
                }
            } else {
                navCard(title: "Games", icon: "calendar",
                        bullets: ["Schedule, history & player attendance"],
                        locked: false) { childSheet = .manageGames }
                navCard(title: "Members", icon: "person.2",
                        bullets: ["Roles, approvals & contact details"],
                        locked: false) { childSheet = .members }
                navCard(title: "Analytics", icon: "chart.bar",
                        bullets: [analyticsLocked ? "Preview available · Pro plan unlocks live data" : "Revenue, fill rate & player trends"],
                        locked: false) { childSheet = .analytics }
                navCard(title: "Club Settings", icon: "slider.horizontal.3",
                        bullets: ["Images, courts, rules & visibility"],
                        locked: false) { childSheet = .editClub }
            }
        }
    }

    private func navCard(
        title: String,
        icon: String,
        bullets: [String],
        locked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: locked ? {} : action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(locked ? Brand.tertiaryText : Brand.primaryText)
                    .frame(width: 34, height: 34)
                    .background(Brand.secondarySurface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(locked ? Brand.secondaryText : Brand.primaryText)
                    ForEach(bullets, id: \.self) { bullet in
                        Text(bullet)
                            .font(.caption)
                            .foregroundStyle(Brand.tertiaryText)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(locked ? Brand.tertiaryText : Brand.softOutline)
            }
            .padding(14)
            .background(Brand.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Brand.dividerColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(locked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }
}
