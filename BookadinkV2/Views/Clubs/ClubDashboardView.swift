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
    private var pendingCount: Int {
        appState.ownerJoinRequests(for: club).count
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
                    navCardsSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 40)
                // iPad / large phone landscape: cap workspace reading width so
                // cards stay legible instead of stretching edge-to-edge.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
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
                        Text("Manage Club")
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
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await refreshAll() }
        }
    }

    // MARK: - Data Refresh

    /// Refreshes only what the Manage Club hub itself needs to render:
    /// entitlements (tier pill, analytics-locked bullet, payment readiness)
    /// and Stripe account state (setup banner). Member directory, dashboard
    /// summary, and advanced analytics moved to the dedicated Analytics
    /// destination — fetching them here is wasted work and slows hub open.
    private func refreshAll() async {
        guard !isRefreshingDashboard else { return }
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        async let fetchEntitlements: Void = appState.fetchClubEntitlements(for: club.id)
        async let fetchStripe: Void = appState.refreshStripeAccountStatus(for: club.id)
        _ = await (fetchEntitlements, fetchStripe)

        stripeStatusLoaded = true

        if !paymentSetupComplete {
            await LocalNotificationManager.shared.scheduleSetupReminderIfNeeded(
                clubID: club.id, clubName: club.name
            )
        } else {
            LocalNotificationManager.shared.cancelSetupReminder(for: club.id)
        }

        #if DEBUG
        let e = appState.entitlementsByClubID[club.id]
        let sa = appState.stripeAccountByClubID[club.id]
        print("[ManageClub] club=\(club.name) plan=\(e?.planTier ?? "nil") payoutsEnabled=\(sa?.payoutsEnabled ?? false) refreshedAt=\(Date())")
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
            // Analytics is now a true full-screen NavigationLink destination,
            // not a child sheet. This case stays as a defensive no-op so the
            // OwnerToolSheet switch remains exhaustive; nothing should set
            // childSheet = .analytics anymore.
            EmptyView()
        case .roleHistory:
            OwnerRoleHistorySheet(club: club).environmentObject(appState)
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
                    analyticsNavCard
                    navCard(title: "Club Settings", icon: "slider.horizontal.3",
                            bullets: ["Images, courts, rules & visibility"],
                            locked: false) { childSheet = .editClub }
                    if appState.isClubOwner(for: club) {
                        navCard(title: "Role History", icon: "clock.arrow.circlepath",
                                bullets: ["Audit trail of every role change in this club"],
                                locked: false) { childSheet = .roleHistory }
                    }
                }
            } else {
                navCard(title: "Games", icon: "calendar",
                        bullets: ["Schedule, history & player attendance"],
                        locked: false) { childSheet = .manageGames }
                navCard(title: "Members", icon: "person.2",
                        bullets: ["Roles, approvals & contact details"],
                        locked: false) { childSheet = .members }
                analyticsNavCard
                navCard(title: "Club Settings", icon: "slider.horizontal.3",
                        bullets: ["Images, courts, rules & visibility"],
                        locked: false) { childSheet = .editClub }
                if appState.isClubOwner(for: club) {
                    navCard(title: "Role History", icon: "clock.arrow.circlepath",
                            bullets: ["Audit trail of every role change in this club"],
                            locked: false) { childSheet = .roleHistory }
                }
            }
        }
    }

    /// Analytics card uses NavigationLink so the destination feels permanent
    /// (true full-screen push with back-button navigation) rather than a
    /// dismissible modal sheet. Visually identical to `navCard` so the
    /// Manage section stays a single coherent grid.
    private var analyticsNavCard: some View {
        NavigationLink {
            ClubPulseView(club: club).environmentObject(appState)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.primaryText)
                    .frame(width: 34, height: 34)
                    .background(Brand.secondarySurface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Analytics")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(analyticsLocked ? "Preview available · Pro plan unlocks live data" : "Revenue, members, operations & insights")
                        .font(.caption)
                        .foregroundStyle(Brand.tertiaryText)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.softOutline)
            }
            .padding(14)
            .background(Brand.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Brand.dividerColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Analytics")
        .accessibilityHint("Opens club analytics including revenue, members, and operations.")
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
