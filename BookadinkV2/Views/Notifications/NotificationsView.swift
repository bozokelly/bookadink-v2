import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Notifications")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)

                    if appState.isLoadingNotifications && appState.notifications.isEmpty {
                        ProgressView("Loading notifications…")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                    } else if appState.notifications.isEmpty {
                        emptyState
                    } else {
                        markAllRow
                        ForEach(appState.notifications) { notification in
                            NotificationRow(notification: notification)
                                .onTapGesture {
                                    Task { await appState.markNotificationRead(notification) }
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await appState.refreshNotifications()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if appState.notifications.isEmpty {
                await appState.refreshNotifications()
            }
        }
    }

    private var markAllRow: some View {
        HStack {
            let unread = appState.unreadNotificationCount
            if unread > 0 {
                Text("\(unread) unread")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            Spacer()
            if unread > 0 {
                Button("Mark all read") {
                    Task { await appState.markAllNotificationsRead() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.pineTeal)
            }
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 38))
                .foregroundStyle(.white.opacity(0.6))
            Text("No notifications yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("You'll see booking confirmations, club updates, and membership decisions here.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(cornerRadius: 22, tint: Color.white.opacity(0.1))
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            iconBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                Text(notification.body)
                    .font(.footnote)
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(3)
                if let date = notification.createdAt {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText.opacity(0.7))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !notification.read {
                Circle()
                    .fill(Brand.pineTeal)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(notification.read ? Color.white.opacity(0.55) : Color.white.opacity(0.78))
        }
        .overlay {
            if !notification.read {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accentColor(for: notification.type).opacity(0.35), lineWidth: 1.5)
            }
        }
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(accentColor(for: notification.type).opacity(0.15))
                .frame(width: 42, height: 42)
            Image(systemName: notification.type.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accentColor(for: notification.type))
        }
    }

    private func accentColor(for type: AppNotification.NotificationType) -> Color {
        switch type.accentColorName {
        case "pineTeal": return Brand.pineTeal
        case "errorRed": return Brand.errorRed
        case "slateBlue": return Brand.slateBlue
        case "spicyOrange": return Brand.spicyOrange
        case "emeraldAction": return Brand.emeraldAction
        default: return Brand.brandPrimary
        }
    }
}

#Preview {
    NavigationStack {
        NotificationsView()
            .environmentObject(AppState())
    }
}
