import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "figure.pickleball",
            iconColor: Brand.pineTeal,
            title: "Welcome to\nBook a Dink",
            body: "Find courts, join clubs, and book your next pickleball game — all in one place.",
            detail: nil
        ),
        OnboardingPage(
            icon: "mappin.and.ellipse",
            iconColor: Brand.emeraldAction,
            title: "Find Your Club",
            body: "Browse clubs near you, request membership, and connect with your local pickleball community.",
            detail: "Club admins approve members. Once approved you can book games, chat, and see the member directory."
        ),
        OnboardingPage(
            icon: "chart.line.uptrend.xyaxis",
            iconColor: Brand.softOrangeAccent,
            title: "Your DUPR Rating",
            body: "Some games require a DUPR rating to ensure fair matchups. Add yours to your profile — you can update it any time.",
            detail: "Don't have a DUPR yet? No problem — you can still join open games and add your rating later."
        )
    ]

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page indicator
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Brand.pineTeal : Brand.softOutline)
                            .frame(width: i == currentPage ? 20 : 6, height: 6)
                            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentPage)
                    }
                }
                .padding(.top, 60)

                // Pages
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // Buttons
                VStack(spacing: 12) {
                    if currentPage < pages.count - 1 {
                        Button {
                            withAnimation { currentPage += 1 }
                        } label: {
                            Text("Continue")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Skip") { onComplete() }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Brand.secondaryText)
                    } else {
                        Button {
                            onComplete()
                        } label: {
                            Text("Get Started")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(page.iconColor.opacity(0.12))
                    .frame(width: 110, height: 110)
                Circle()
                    .strokeBorder(page.iconColor.opacity(0.25), lineWidth: 1)
                    .frame(width: 110, height: 110)
                Image(systemName: page.icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(page.iconColor)
            }
            .padding(.bottom, 36)

            // Title
            Text(page.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.primaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            // Body
            Text(page.body)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)

            // Detail callout
            if let detail = page.detail {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.pineTeal.opacity(0.8))
                        .padding(.top, 1)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                        .lineSpacing(3)
                }
                .padding(14)
                .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Brand.softOutline, lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .padding(.top, 24)
            }

            Spacer()
            Spacer()
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let iconColor: Color
    let title: String
    let body: String
    let detail: String?
}

#Preview {
    OnboardingView(onComplete: {})
}

// MARK: - Onboarding UI Foundation (Phase 1.4)

/// Filled primary CTA used by onboarding-adjacent sheets (primers + DUPR recovery).
/// Drives loading + disabled state via simple props so call sites do not have to
/// re-implement the spinner/opacity dance.
struct OnboardingPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(_ title: String, isLoading: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Brand.Spacing.s8) {
                if isLoading {
                    ProgressView().tint(.white)
                }
                Text(isLoading ? "Saving…" : title)
                    .font(Brand.Typography.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Brand.Spacing.s16)
            .background(Brand.emeraldAction, in: RoundedRectangle(cornerRadius: Brand.Radius.r18, style: .continuous))
        }
        .disabled(isLoading || isDisabled)
        .opacity((isLoading || isDisabled) ? 0.55 : 1)
        .buttonStyle(.plain)
    }
}

/// Quiet secondary CTA used by onboarding-adjacent sheets (Skip / Not now / Cancel).
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.Typography.body.weight(.medium))
                .foregroundStyle(Brand.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Brand.Spacing.s12)
        }
        .buttonStyle(.plain)
    }
}

/// Sheet-level chrome for onboarding-adjacent presentations: warm off-white background,
/// 28pt rounded corners, no drag indicator. Detents stay at the call site so each sheet
/// controls its own height (large for primers, fixed for DUPR recovery).
struct OnboardingSheetShell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationBackground(Brand.appBackground)
            .presentationCornerRadius(Brand.Radius.r28)
            .presentationDragIndicator(.hidden)
    }
}

extension View {
    /// Applies consistent onboarding-sheet chrome. Detents must be set separately by the caller.
    func onboardingSheetShell() -> some View {
        modifier(OnboardingSheetShell())
    }
}

/// Content-level shell: consistent horizontal/vertical padding and a max readable width
/// on iPad so the form/card content does not stretch edge-to-edge on a 13" surface.
/// On iPhone the maxWidth is larger than the screen, so it is a no-op.
struct OnboardingContentShell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Brand.Spacing.s24)
            .padding(.vertical, Brand.Spacing.s24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func onboardingContentShell() -> some View {
        modifier(OnboardingContentShell())
    }
}

// MARK: - Push Permission Primer (Phase 1.2)

/// Soft-ask primer presented before the iOS system notification permission prompt.
/// Tapping "Enable notifications" calls `AppState.confirmPushPermissionFromPrimer()`
/// which fires the actual system prompt and registers for remote notifications.
/// Tapping "Not now" calls `AppState.skipPushPermissionPrimer()` and locks the primer
/// for the remainder of the session.
struct PushPermissionPrimerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Brand.Spacing.s24) {
                    ZStack {
                        Circle()
                            .fill(Brand.pineTeal.opacity(0.12))
                            .frame(width: 76, height: 76)
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(Brand.pineTeal)
                    }
                    .padding(.top, Brand.Spacing.s8)

                    VStack(spacing: Brand.Spacing.s12) {
                        Text("Stay in the loop")
                            .font(Brand.Typography.title)
                            .foregroundStyle(Brand.primaryText)
                        Text("We'll let you know about everything that affects your bookings — and nothing that doesn't.")
                            .font(Brand.Typography.body)
                            .foregroundStyle(Brand.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Brand.Spacing.s4)
                    }

                    VStack(alignment: .leading, spacing: Brand.Spacing.s12) {
                        primerBullet(icon: "checkmark.seal.fill", text: "Booking confirmations")
                        primerBullet(icon: "person.2.fill", text: "Waitlist promotions when a spot opens")
                        primerBullet(icon: "clock.fill", text: "Payment & hold reminders before they expire")
                        primerBullet(icon: "person.badge.shield.checkmark.fill", text: "Club approval updates")
                        primerBullet(icon: "calendar.badge.exclamationmark", text: "Game changes & cancellations")
                        primerBullet(icon: "bubble.left.and.bubble.right.fill", text: "Club messages where applicable")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Brand.Spacing.s16)
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: Brand.Radius.r18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.Radius.r18, style: .continuous)
                            .strokeBorder(Brand.softOutline, lineWidth: 1)
                    )

                    VStack(spacing: Brand.Spacing.s12) {
                        OnboardingPrimaryButton("Enable notifications") {
                            Task {
                                await appState.confirmPushPermissionFromPrimer()
                                appState.skipPushPermissionPrimer()
                            }
                        }
                        OnboardingSecondaryButton("Not now") {
                            appState.skipPushPermissionPrimer()
                        }
                    }
                    .padding(.top, Brand.Spacing.s4)
                }
                .onboardingContentShell()
            }
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .onboardingSheetShell()
    }

    private func primerBullet(icon: String, text: String) -> some View {
        HStack(spacing: Brand.Spacing.s12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Brand.pineTeal)
                .frame(width: 24, height: 24)
            Text(text)
                .font(Brand.Typography.body)
                .foregroundStyle(Brand.primaryText)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Location Permission Primer (Phase 1.3)

/// Soft-ask primer presented before the iOS system location permission prompt.
/// Tapping "Use my location" calls `LocationManager.confirmLocationPermissionFromPrimer()`
/// which fires the actual system prompt. Tapping "Not now" calls
/// `LocationManager.skipLocationPermissionPrimer()` and locks the primer for the
/// remainder of the session. Mirrors `PushPermissionPrimerView` in style + structure.
struct LocationPermissionPrimerView: View {
    @EnvironmentObject private var locationManager: LocationManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Brand.Spacing.s24) {
                    ZStack {
                        Circle()
                            .fill(Brand.pineTeal.opacity(0.12))
                            .frame(width: 76, height: 76)
                        Image(systemName: "location.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Brand.pineTeal)
                    }
                    .padding(.top, Brand.Spacing.s8)

                    VStack(spacing: Brand.Spacing.s12) {
                        Text("Find games near you")
                            .font(Brand.Typography.title)
                            .foregroundStyle(Brand.primaryText)
                        Text("We use your location to surface what's playable nearby — and nothing else.")
                            .font(Brand.Typography.body)
                            .foregroundStyle(Brand.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Brand.Spacing.s4)
                    }

                    VStack(alignment: .leading, spacing: Brand.Spacing.s12) {
                        primerBullet(icon: "figure.pickleball", text: "Show games near you")
                        primerBullet(icon: "building.2.fill", text: "Find nearby clubs to join")
                        primerBullet(icon: "arrow.up.arrow.down", text: "Improve distance sorting")
                        primerBullet(icon: "bolt.fill", text: "Discover playable sessions faster")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Brand.Spacing.s16)
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: Brand.Radius.r18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.Radius.r18, style: .continuous)
                            .strokeBorder(Brand.softOutline, lineWidth: 1)
                    )

                    VStack(spacing: Brand.Spacing.s12) {
                        OnboardingPrimaryButton("Use my location") {
                            locationManager.confirmLocationPermissionFromPrimer()
                            locationManager.skipLocationPermissionPrimer()
                        }
                        OnboardingSecondaryButton("Not now") {
                            locationManager.skipLocationPermissionPrimer()
                        }
                    }
                    .padding(.top, Brand.Spacing.s4)
                }
                .onboardingContentShell()
            }
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .onboardingSheetShell()
    }

    private func primerBullet(icon: String, text: String) -> some View {
        HStack(spacing: Brand.Spacing.s12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Brand.pineTeal)
                .frame(width: 24, height: 24)
            Text(text)
                .font(Brand.Typography.body)
                .foregroundStyle(Brand.primaryText)
            Spacer(minLength: 0)
        }
    }
}
