import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    private var isBootstrapping: Bool {
        appState.authState != .signedOut
            && !appState.isInitialBootstrapComplete
            && appState.profile == nil
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
            } else {
                MainTabView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.55), value: isBootstrapping)
        .animation(.easeInOut(duration: 0.55), value: appState.authState == .signedOut)
        .animation(.easeInOut(duration: 0.55), value: appState.profile == nil)
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
