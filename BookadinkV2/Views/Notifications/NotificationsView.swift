import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedGame: Game? = nil
    @State private var selectedClub: Club? = nil
    @State private var pendingReview: PendingReview? = nil
    @State private var showClearConfirm = false

    /// Lightweight model used to open the review sheet without needing
    /// the full Game object to be in memory.
    private struct PendingReview: Identifiable {
        let id: UUID        // game ID
        let gameTitle: String
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.pageGradient.ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Notifications")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.primaryText)
                            .padding(.horizontal, 4)

                        if appState.isLoadingNotifications && appState.notifications.isEmpty {
                            ProgressView("Loading notifications…")
                                .tint(Brand.secondaryText)
                                .foregroundStyle(Brand.secondaryText)
                                .padding(.top, 8)
                        } else if appState.notifications.isEmpty {
                            emptyState
                        } else {
                            actionRow
                            ForEach(appState.notifications) { notification in
                                NotificationRow(
                                    notification: notification,
                                    hasDestination: destination(for: notification) != nil
                                )
                                .onTapGesture { handleTap(notification) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable { await appState.refreshNotifications() }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Game opens as a sheet so back returns here
            .sheet(item: $selectedGame) { game in
                NavigationStack {
                    GameDetailView(game: game)
                }
            }
            // Review prompt opens as a sheet
            .sheet(item: $pendingReview) { review in
                ReviewGameSheet(gameID: review.id, gameTitle: review.gameTitle) { club in
                    selectedClub = club
                }
            }
            // Club pushes inline — back arrow returns to Notifications
            .navigationDestination(item: $selectedClub) { club in
                ClubDetailView(club: club)
            }
        }
        .task {
            if appState.notifications.isEmpty {
                await appState.refreshNotifications()
            }
        }
        .confirmationDialog(
            "Clear all notifications?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await appState.clearAllNotifications() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack {
            let unread = appState.unreadNotificationCount
            if unread > 0 {
                Text("\(unread) unread")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer()
            HStack(spacing: 12) {
                if unread > 0 {
                    Button("Mark all read") {
                        Task { await appState.markAllNotificationsRead() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                }
                Button {
                    showClearConfirm = true
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 38))
                .foregroundStyle(Brand.secondaryText)
            Text("No notifications yet")
                .font(.headline)
                .foregroundStyle(Brand.primaryText)
            Text("You'll see booking confirmations, club updates, and membership decisions here.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(cornerRadius: 22, tint: Brand.secondarySurface)
    }

    // MARK: - Navigation

    /// Resolves the in-app destination for a notification, or nil if there is none.
    private enum NotificationDestination {
        case game(Game)
        case club(Club)
        case review(gameID: UUID, title: String)
    }

    private func destination(for notification: AppNotification) -> NotificationDestination? {
        guard let link = notification.deepLink else { return nil }
        switch link {
        case .game(let id):
            let game = appState.gamesByClubID.values
                .flatMap { $0 }
                .first { $0.id == id }
            return game.map { .game($0) }
        case .club(let id):
            let club = appState.clubs.first { $0.id == id }
            return club.map { .club($0) }
        case .review(let gameID):
            // Always tappable — game title is extracted from the notification itself.
            // Club lookup happens inside ReviewGameSheet via appState.clubForGame().
            return .review(gameID: gameID, title: extractGameTitle(from: notification.title))
        }
    }

    /// Strips the "How was …?" wrapper inserted by send-review-prompts to get the game title.
    private func extractGameTitle(from notifTitle: String) -> String {
        var t = notifTitle
        if t.hasPrefix("How was ") { t = String(t.dropFirst("How was ".count)) }
        if t.hasSuffix("?") { t = String(t.dropLast()) }
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? "Your Session" : t.trimmingCharacters(in: .whitespaces)
    }

    private func handleTap(_ notification: AppNotification) {
        Task { await appState.markNotificationRead(notification) }
        switch destination(for: notification) {
        case .game(let game):
            selectedGame = game
        case .club(let club):
            selectedClub = club
        case .review(let gameID, let title):
            pendingReview = PendingReview(id: gameID, gameTitle: title)
        case nil:
            break
        }
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let notification: AppNotification
    let hasDestination: Bool

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

            VStack(spacing: 6) {
                if !notification.read {
                    Circle()
                        .fill(Brand.pineTeal)
                        .frame(width: 8, height: 8)
                }
                if hasDestination {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.mutedText.opacity(0.5))
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    notification.read ? Brand.softOutline : accentColor(for: notification.type).opacity(0.35),
                    lineWidth: notification.read ? 1 : 1.5
                )
        }
        .contentShape(Rectangle())
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
        case "pineTeal":       return Brand.pineTeal
        case "errorRed":       return Brand.errorRed
        case "slateBlue":      return Brand.slateBlue
        case "spicyOrange":    return Brand.spicyOrange
        case "emeraldAction":  return Brand.emeraldAction
        default:               return Brand.brandPrimary
        }
    }
}

#Preview {
    NavigationStack {
        NotificationsView()
            .environmentObject(AppState())
    }
}
