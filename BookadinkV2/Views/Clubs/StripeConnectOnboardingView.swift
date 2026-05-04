import SwiftUI

// MARK: - Full-screen Stripe Connect onboarding experience

/// Full-screen sheet guiding a club owner through Stripe Connect Express setup.
/// Handles all states: not started, in-progress, verifying, ready, blocked, and error.
/// Open this as a `.sheet` from any payments entry point.
struct StripeConnectOnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let club: Club

    @State private var stripeAccount: ClubStripeAccount?
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isLaunchingStripe = false
    @State private var errorMessage: String?
    @State private var linkExpired = false
    @State private var paywallFeature: LockedFeature? = nil

    private var entitlements: ClubEntitlements? { appState.entitlementsByClubID[club.id] }
    private var paymentsGate: GateResult {
        FeatureGateService.canAcceptPayments(entitlements)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Brand.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        heroHeader
                        contentBody
                            .padding(.horizontal, 20)
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Brand.primaryText)
                }
            }
        }
        .task { await loadStatus() }
        // When the app returns from Safari via the bookadink:// deep link,
        // AppState sets pendingConnectReturnClubID and calls refreshStripeAccountStatus.
        .onChange(of: appState.pendingConnectReturnClubID) { _, clubID in
            guard clubID == club.id else { return }
            linkExpired = appState.pendingConnectReturnStatus == "refresh"
            isRefreshing = !linkExpired
            appState.pendingConnectReturnClubID = nil
        }
        // refreshStripeAccountStatus updates stripeAccountByClubID; pick it up here.
        .onChange(of: appState.stripeAccountByClubID[club.id]) { _, cached in
            stripeAccount = cached
            isRefreshing = false
        }
        .sheet(item: $paywallFeature) { feature in
            ClubUpgradePaywallView(club: club, lockedFeature: feature)
                .environmentObject(appState)
        }
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.93, blue: 0.91), Brand.appBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 260)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Brand.primaryText)
                        .frame(width: 72, height: 72)
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
                .shadow(color: Brand.primaryText.opacity(0.18), radius: 12, y: 6)

                VStack(spacing: 6) {
                    Text(heroTitle)
                        .font(.system(size: 24, weight: .bold, design: .default))
                        .foregroundStyle(Brand.primaryText)
                        .multilineTextAlignment(.center)

                    statusBadge
                }
            }
            .padding(.bottom, 28)
        }
    }

    private var heroTitle: String {
        if isLoading { return "Payments" }
        if case .blocked = paymentsGate { return "Upgrade Required" }
        guard let account = stripeAccount else { return "Accept Payments" }
        if account.payoutsEnabled { return "You're All Set" }
        if account.onboardingComplete { return "Almost There" }
        return linkExpired ? "Link Expired" : "Finish Your Setup"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isLoading || isRefreshing {
            statusPill(label: "Checking status…", icon: "arrow.triangle.2.circlepath", color: Brand.secondaryText)
        } else if case .blocked = paymentsGate {
            statusPill(label: "Starter or Pro plan required", icon: "lock.fill", color: Brand.secondaryText)
        } else if let account = stripeAccount {
            if account.payoutsEnabled {
                statusPill(label: "Payments active", icon: "checkmark.circle.fill", color: Brand.emeraldAction)
            } else if account.onboardingComplete {
                statusPill(label: "Verification in progress", icon: "clock.fill", color: Brand.softOrangeAccent)
            } else {
                statusPill(
                    label: linkExpired ? "Setup link expired" : "Setup in progress",
                    icon: linkExpired ? "exclamationmark.circle.fill" : "circle.dotted",
                    color: linkExpired ? .orange : Brand.secondaryText
                )
            }
        } else {
            statusPill(label: "Not connected", icon: "circle.dashed", color: Brand.secondaryText)
        }
    }

    private func statusPill(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
    }

    // MARK: - Content body (state-driven)

    @ViewBuilder
    private var contentBody: some View {
        if isLoading {
            loadingContent
        } else if case .blocked(let reason) = paymentsGate {
            blockedContent(reason: reason)
        } else if let account = stripeAccount, account.payoutsEnabled {
            readyContent(account: account)
        } else if let account = stripeAccount, account.onboardingComplete {
            verifyingContent
        } else {
            let hasAccount = stripeAccount != nil
            setupContent(inProgress: hasAccount, linkExpired: linkExpired)
        }
    }

    // MARK: - Loading

    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Brand.primaryText)
            Text("Checking your payment status…")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Not started / In progress / Link expired

    private func setupContent(inProgress: Bool, linkExpired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if let err = errorMessage {
                errorBanner(err)
            }

            if linkExpired {
                infoCard(
                    icon: "exclamationmark.circle.fill",
                    iconColor: .orange,
                    title: "Your setup link expired",
                    body: "Stripe onboarding links expire after 24 hours. Tap below to generate a fresh link and pick up where you left off."
                )
            } else if inProgress {
                infoCard(
                    icon: "circle.dotted",
                    iconColor: Brand.secondaryText,
                    title: "Setup started but not finished",
                    body: "You've created a Stripe account but haven't completed all required steps. Finish the setup to start accepting payments."
                )
            } else {
                benefitsList
                requirementsList
                feeNote
            }

            primaryButton(
                title: inProgress ? "Continue Setup" : "Set Up Payments",
                icon: "arrow.right",
                isLoading: isLaunchingStripe
            ) {
                Task { await launchStripe() }
            }

            legalNote
        }
        .padding(.top, 8)
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("What you get")
            VStack(alignment: .leading, spacing: 12) {
                benefitRow(icon: "creditcard", label: "Card payments & Apple Pay")
                benefitRow(icon: "building.columns", label: "Direct payouts to your bank")
                benefitRow(icon: "lock.shield", label: "Secure — powered by Stripe")
                benefitRow(icon: "chart.bar", label: "Revenue tracked in your dashboard")
            }
            .padding(16)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
    }

    private var requirementsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("What you'll need")
            VStack(alignment: .leading, spacing: 10) {
                requirementRow("Business or personal details")
                requirementRow("Bank account for payouts")
                requirementRow("Government ID (if required by Stripe)")
                requirementRow("About 10–15 minutes")
            }
            .padding(16)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
    }

    private var feeNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
            Text("Book A Dink charges a **\(SupabaseConfig.defaultPlatformFeeBps / 100)% platform fee** per paid booking. The rest goes directly to your club.")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
        }
    }

    // MARK: - Verifying (submitted, payouts not yet enabled)

    private var verifyingContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            infoCard(
                icon: "clock.fill",
                iconColor: Brand.softOrangeAccent,
                title: "Verification in progress",
                body: "Stripe is reviewing your submitted information. This usually takes 1–2 business days. You'll receive an email from Stripe once your account is fully verified."
            )

            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("While you wait")
                VStack(alignment: .leading, spacing: 12) {
                    benefitRow(icon: "checkmark.circle", label: "Details submitted successfully")
                    benefitRow(icon: "envelope", label: "Watch for emails from Stripe")
                    benefitRow(icon: "arrow.triangle.2.circlepath", label: "Tap below to check the latest status")
                }
                .padding(16)
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.softOutline, lineWidth: 1)
                )
            }

            primaryButton(title: "Check Status", icon: "arrow.triangle.2.circlepath", isLoading: isRefreshing) {
                Task { await refreshStatus() }
            }

            legalNote
        }
        .padding(.top, 8)
    }

    // MARK: - Ready

    private func readyContent(account: ClubStripeAccount) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            infoCard(
                icon: "checkmark.seal.fill",
                iconColor: Brand.emeraldAction,
                title: "Payments are active",
                body: "Your Stripe account is connected and verified. Players can now pay by card or Apple Pay when booking your games."
            )

            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Account details")
                VStack(alignment: .leading, spacing: 12) {
                    detailRow(label: "Status", value: "Active")
                    Divider()
                    detailRow(label: "Platform fee", value: "\(SupabaseConfig.defaultPlatformFeeBps / 100)% per booking")
                    Divider()
                    detailRow(label: "Payouts", value: "Enabled")
                }
                .padding(16)
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.softOutline, lineWidth: 1)
                )
            }

            Button {
                Task { await refreshStatus() }
            } label: {
                Label(isRefreshing ? "Refreshing…" : "Refresh Status", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
            }
            .disabled(isRefreshing)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    // MARK: - Blocked (plan gate)

    private func blockedContent(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            infoCard(
                icon: "lock.fill",
                iconColor: Brand.secondaryText,
                title: "Payments require a paid plan",
                body: reason + " Upgrade to Starter or Pro to unlock Stripe Connect onboarding and start accepting paid bookings."
            )

            primaryButton(title: "View Plans", icon: "arrow.right", isLoading: false) {
                paywallFeature = .payments
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Sub-components

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.secondaryText)
            .padding(.bottom, 10)
    }

    private func infoCard(icon: String, iconColor: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    private func benefitRow(icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Brand.primaryText)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.primaryText)
        }
    }

    private func requirementRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            Text("•")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.primaryText)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.primaryText)
        }
    }

    private func primaryButton(title: String, icon: String, isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .disabled(isLoading)
        .buttonStyle(.plain)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.errorRed)
            Text(message)
                .font(.caption)
                .foregroundStyle(Brand.errorRed)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Brand.errorRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Brand.errorRed.opacity(0.2), lineWidth: 1)
        )
    }

    private var legalNote: some View {
        Text("Your setup happens directly on Stripe's secure platform. Book A Dink never stores your banking or identity information.")
            .font(.caption)
            .foregroundStyle(Brand.tertiaryText)
            .multilineTextAlignment(.leading)
    }

    // MARK: - Actions

    private func loadStatus() async {
        isLoading = true
        defer { isLoading = false }

        if let cached = appState.stripeAccountByClubID[club.id] {
            stripeAccount = cached
            return
        }
        // Only update local state — not the shared cache — to avoid triggering
        // StripeConnectStatusSection re-renders while this sheet is presenting.
        let account = try? await appState.fetchClubStripeAccount(for: club.id)
        await MainActor.run { stripeAccount = account }
    }

    private func refreshStatus() async {
        isRefreshing = true
        errorMessage = nil
        await appState.refreshStripeAccountStatus(for: club.id)
        await MainActor.run {
            stripeAccount = appState.stripeAccountByClubID[club.id] ?? stripeAccount
            isRefreshing = false
        }
    }

    private func launchStripe() async {
        isLaunchingStripe = true
        errorMessage = nil

        appState.connectOnboardingError = nil
        guard let urlString = await appState.createConnectOnboarding(for: club),
              let url = URL(string: urlString) else {
            await MainActor.run {
                errorMessage = appState.connectOnboardingError ?? "Could not open Stripe. Please try again."
                isLaunchingStripe = false
            }
            return
        }

        await MainActor.run {
            linkExpired = false
            isLaunchingStripe = false
            // Open Stripe in the system browser. Safari on iOS follows the
            // 302 → bookadink:// redirect and routes control back to the app
            // via onOpenURL, which calls AppState.handleDeepLink.
            openURL(url)
        }
    }
}

// MARK: - Compact inline section for Form contexts

/// Compact payments status row for embedding inside a `Form` section.
/// Shows the current state and opens `StripeConnectOnboardingView` as a sheet on tap.
struct StripeConnectStatusSection: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    @State private var showOnboarding = false
    @State private var stripeAccount: ClubStripeAccount?
    @State private var isLoading = true

    private var paymentsGate: GateResult {
        FeatureGateService.canAcceptPayments(appState.entitlementsByClubID[club.id])
    }

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Checking payment status…")
                        .font(.subheadline)
                        .foregroundStyle(Brand.mutedText)
                }
            } else {
                statusRow
            }
        }
        .task { await load() }
        .onChange(of: appState.stripeAccountByClubID[club.id]) { _, cached in
            stripeAccount = cached
        }
        // Sheet anchored at the Group level so stripeAccount updates never recreate the binding
        .sheet(isPresented: $showOnboarding) {
            StripeConnectOnboardingView(club: club)
                .environmentObject(appState)
        }
        // Prevent List row from consuming the tap before the button gets it
        .listRowInsets(EdgeInsets())
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusRow: some View {
        if case .blocked = paymentsGate {
            statusRowButton(
                icon: "lock.fill",
                iconColor: Brand.mutedText,
                title: "Payments Unavailable",
                subtitle: "Starter or Pro plan required"
            )
        } else if let account = stripeAccount, account.payoutsEnabled {
            statusRowButton(
                icon: "checkmark.circle.fill",
                iconColor: Brand.emeraldAction,
                title: "Payments Active",
                subtitle: "Accepting card payments · \(SupabaseConfig.defaultPlatformFeeBps / 100)% platform fee"
            )
        } else if let account = stripeAccount, account.onboardingComplete {
            statusRowButton(
                icon: "clock.fill",
                iconColor: Brand.softOrangeAccent,
                title: "Verification in Progress",
                subtitle: "Stripe is reviewing your account"
            )
        } else {
            statusRowButton(
                icon: "creditcard",
                iconColor: Brand.primaryText,
                title: stripeAccount != nil ? "Finish Stripe Setup" : "Set Up Payments",
                subtitle: stripeAccount != nil ? "Continue connecting your Stripe account" : "Accept paid bookings via Stripe"
            )
        }
    }

    private func statusRowButton(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        Button { showOnboarding = true } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let cached = appState.stripeAccountByClubID[club.id] {
            stripeAccount = cached
            return
        }
        let account = try? await appState.fetchClubStripeAccount(for: club.id)
        await MainActor.run {
            stripeAccount = account
            if let account { appState.stripeAccountByClubID[club.id] = account }
        }
    }
}
