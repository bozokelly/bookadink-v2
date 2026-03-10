import SwiftUI

struct BadgesCard: View {
    @EnvironmentObject private var appState: AppState
    let profile: UserProfile
    @State private var selectedBadge: ProfileBadge?

    private var badges: [ProfileBadge] {
        BadgeEvaluator.evaluate(for: profile, appState: appState)
    }

    private var earnedCount: Int { badges.filter(\.isEarned).count }
    private let totalCount = 11

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Achievements", systemImage: "medal.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                Text("\(earnedCount) of \(totalCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.mutedText)
            }

            progressBar

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(badges) { badge in
                    BadgeTile(badge: badge)
                        .onTapGesture { selectedBadge = badge }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .sheet(item: $selectedBadge) { badge in
            BadgeDetailSheet(badge: badge)
                .presentationDetents([.height(260)])
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(.systemGray5))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Brand.pineTeal)
                        .frame(width: geo.size.width * CGFloat(earnedCount) / CGFloat(totalCount), height: 6)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: earnedCount)
                }
            }
            .frame(height: 6)
        }
    }
}

private struct BadgeTile: View {
    let badge: ProfileBadge
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(badge.isEarned ? badge.colour.opacity(0.15) : Color(.systemGray6))
                    .frame(width: 56, height: 56)

                Image(systemName: badge.systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(badge.isEarned ? badge.colour : Color(.systemGray3))
                    .saturation(badge.isEarned ? 1 : 0)

                if !badge.isEarned {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(.systemGray3))
                        .offset(x: 18, y: 18)
                }
            }
            .opacity(badge.isEarned ? 1 : 0.55)
            .scaleEffect(scale)

            Text(badge.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badge.isEarned ? Brand.ink : Brand.mutedText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .onChange(of: badge.isEarned) { _, newValue in
            if newValue {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { scale = 1.15 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scale = 1.0 }
                }
            }
        }
    }
}

private struct BadgeDetailSheet: View {
    let badge: ProfileBadge
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.pineTeal)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(badge.isEarned ? badge.colour.opacity(0.15) : Color(.systemGray6))
                    .frame(width: 80, height: 80)
                Image(systemName: badge.systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(badge.isEarned ? badge.colour : Color(.systemGray3))
                    .saturation(badge.isEarned ? 1 : 0)
            }
            .opacity(badge.isEarned ? 1 : 0.55)

            Text(badge.title)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(badge.isEarned ? .primary : .secondary)

            Text(badge.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if badge.isEarned, let date = badge.earnedAt {
                Text("Earned \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.emeraldAction)
            } else {
                Text("Keep playing to unlock this!")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.mutedText)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
