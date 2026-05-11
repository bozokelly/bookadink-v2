import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager
    @State private var hasCompletedOnboarding: Bool = false
    @State private var splashComplete: Bool = false

    private var isBootstrapping: Bool {
        appState.authState != .signedOut
            && appState.profile == nil
            && (!appState.isInitialBootstrapComplete || appState.isPerformingPostSignInBootstrap)
    }

    private var onboardingKey: String {
        "bookadink.onboarding.complete.\(appState.authUserID?.uuidString ?? "unknown")"
    }

    var body: some View {
        ZStack {
            Brand.pageGradient
                .ignoresSafeArea()

            if appState.isVerifyingAuthCallback {
                AuthVerifyingStage()
                    .transition(.opacity)
                    .zIndex(3)
            } else if isBootstrapping {
                LoadingScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            } else if appState.authState == .signedOut {
                AuthWelcomeView()
                    .transition(.opacity)
                    .zIndex(1)
            } else if appState.profile == nil {
                ProfileSetupView()
                    .transition(.opacity)
                    .zIndex(1)
            } else if !hasCompletedOnboarding {
                OnboardingView {
                    UserDefaults.standard.set(true, forKey: onboardingKey)
                    withAnimation(.easeInOut(duration: 0.55)) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            } else {
                MainTabView()
                    .transition(.opacity)
                    .zIndex(1)
                    .sheet(isPresented: Binding(
                        get: { appState.shouldShowPushPrimer },
                        set: { newValue in
                            // Any dismissal — gesture, programmatic, or via CTA — locks the
                            // primer for the rest of this session so it cannot re-fire from
                            // other entry points (opening club chat, un-muting a club).
                            if !newValue { appState.skipPushPermissionPrimer() }
                        }
                    )) {
                        PushPermissionPrimerView()
                            .environmentObject(appState)
                    }
                    .sheet(isPresented: Binding(
                        get: { locationManager.shouldShowLocationPrimer },
                        set: { newValue in
                            // Any dismissal — gesture, programmatic, or via CTA — locks the
                            // primer for the rest of this session so it cannot re-fire when
                            // HomeView re-appears (e.g. after a sheet dismiss).
                            if !newValue { locationManager.skipLocationPermissionPrimer() }
                        }
                    )) {
                        LocationPermissionPrimerView()
                            .environmentObject(locationManager)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.55), value: appState.isVerifyingAuthCallback)
        .animation(.easeInOut(duration: 0.55), value: isBootstrapping)
        .animation(.easeInOut(duration: 0.55), value: appState.authState == .signedOut)
        .animation(.easeInOut(duration: 0.55), value: appState.profile == nil)
        .animation(.easeInOut(duration: 0.55), value: hasCompletedOnboarding)
        .overlay {
            if !splashComplete {
                SplashView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        splashComplete = true
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .onChange(of: appState.authUserID) { _, newID in
            guard let id = newID else { return }
            let key = "bookadink.onboarding.complete.\(id.uuidString)"
            hasCompletedOnboarding = UserDefaults.standard.bool(forKey: key)
        }
        .onAppear {
            if let id = appState.authUserID {
                let key = "bookadink.onboarding.complete.\(id.uuidString)"
                hasCompletedOnboarding = UserDefaults.standard.bool(forKey: key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookADinkDidRegisterForRemoteNotifications)) { notification in
            guard let token = notification.object as? String else { return }
            appState.handleRemotePushDeviceToken(token)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookADinkDidFailRemoteNotificationsRegistration)) { notification in
            guard let message = notification.object as? String else { return }
            appState.handleRemotePushRegistrationFailure(message)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppState())
}

// MARK: - Auth Verifying Stage (Phase 2A.1)

/// Transient stage shown while a Supabase email-verification deep link is being
/// consumed. Auto-dismisses when `AppState.isVerifyingAuthCallback` flips back
/// to false (either bootstrap completes → routes naturally, or callback fails
/// → AuthWelcomeView with the error message).
private struct AuthVerifyingStage: View {
    var body: some View {
        VStack(spacing: Brand.Spacing.s20) {
            ZStack {
                Circle()
                    .fill(Brand.emeraldAction.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Brand.emeraldAction)
            }
            VStack(spacing: Brand.Spacing.s8) {
                Text("Verified")
                    .font(Brand.Typography.title)
                    .foregroundStyle(Brand.primaryText)
                Text("Setting up your account…")
                    .font(Brand.Typography.body)
                    .foregroundStyle(Brand.secondaryText)
            }
            ProgressView()
                .tint(Brand.secondaryText)
                .padding(.top, Brand.Spacing.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.appBackground.ignoresSafeArea())
    }
}
