import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var hasCompletedOnboarding: Bool = false

    private var isBootstrapping: Bool {
        appState.authState != .signedOut
            && !appState.isInitialBootstrapComplete
            && appState.profile == nil
    }

    private var onboardingKey: String {
        "bookadink.onboarding.complete.\(appState.authUserID?.uuidString ?? "unknown")"
    }

    var body: some View {
        ZStack {
            Brand.pageGradient
                .ignoresSafeArea()

            if isBootstrapping {
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
            }
        }
        .animation(.easeInOut(duration: 0.55), value: isBootstrapping)
        .animation(.easeInOut(duration: 0.55), value: appState.authState == .signedOut)
        .animation(.easeInOut(duration: 0.55), value: appState.profile == nil)
        .animation(.easeInOut(duration: 0.55), value: hasCompletedOnboarding)
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
