import SwiftUI
import Charts

struct DUPRHistoryCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var chartAppeared = false
    @State private var navigateToHistory = false

    private var history: [DUPREntry] {
        appState.duprHistory.sorted { $0.recordedAt < $1.recordedAt }
    }

    private var currentRating: Double? {
        appState.duprDoublesRating ?? history.last?.rating
    }

    private var highestRating: Double? {
        history.map(\.rating).max()
    }

    private var recentChange: Double? {
        guard history.count >= 2 else { return nil }
        return history.last!.rating - history[history.count - 2].rating
    }

    private var insightText: String {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let recent = history.filter { $0.recordedAt >= cutoff }
        guard recent.count >= 2,
              let first = recent.first?.rating,
              let last = recent.last?.rating else {
            return "Keep updating your DUPR to see trends."
        }
        let delta = last - first
        if delta > 0.05 {
            return String(format: "Improving — up %.2f over the last 30 days", delta)
        } else if delta < -0.05 {
            return String(format: "Down %.2f over the last 30 days", abs(delta))
        } else {
            return "Steady — less than 0.05 change this month"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("DUPR Rating", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                NavigationLink(destination: DUPRHistoryDetailView()) {
                    Text("See All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                }
            }

            if history.count < 2 {
                emptyState
            } else {
                statPills
                sparkline
                Text(insightText)
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .onAppear { withAnimation(.easeIn(duration: 0.4).delay(0.1)) { chartAppeared = true } }
    }

    private var statPills: some View {
        HStack(spacing: 10) {
            statPill(
                label: "Current",
                value: currentRating.map { String(format: "%.3f", $0) } ?? "—",
                labelColor: Brand.mutedText,
                valueColor: Brand.ink,
                background: Color(.systemGray6)
            )
            statPill(
                label: "Highest",
                value: highestRating.map { String(format: "%.3f", $0) } ?? "—",
                labelColor: Color(red: 0.6, green: 0.5, blue: 0),
                valueColor: Color(red: 0.7, green: 0.55, blue: 0),
                background: Color(red: 1, green: 0.95, blue: 0.8)
            )
            if let change = recentChange {
                let isPositive = change >= 0
                statPill(
                    label: "Recent",
                    value: (isPositive ? "+" : "") + String(format: "%.3f", change),
                    labelColor: Brand.mutedText,
                    valueColor: isPositive ? Brand.emeraldAction : Brand.errorRed,
                    background: isPositive ? Brand.emeraldAction.opacity(0.1) : Brand.errorRed.opacity(0.1),
                    icon: isPositive ? "arrow.up" : "arrow.down"
                )
            }
        }
    }

    private func statPill(
        label: String,
        value: String,
        labelColor: Color,
        valueColor: Color,
        background: Color,
        icon: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(labelColor)
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(valueColor)
                }
                Text(value)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(valueColor)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sparkline: some View {
        let entries = Array(history.suffix(10))
        let yMin = (entries.map(\.rating).min() ?? 0) - 0.05
        let yMax = (entries.map(\.rating).max() ?? 1) + 0.05

        return Chart(entries) { entry in
            AreaMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Brand.pineTeal.opacity(0.18), Brand.pineTeal.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(Brand.pineTeal)
            .lineStyle(StrokeStyle(lineWidth: 2.5))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(Brand.pineTeal)
            .symbolSize(28)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYScale(domain: yMin...yMax)
        .frame(height: 90)
        .opacity(chartAppeared ? 1 : 0)
        .animation(.easeIn(duration: 0.5), value: chartAppeared)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(Brand.pineTeal.opacity(0.5))
            Text("Log your first DUPR update to start tracking your progress.")
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
        }
        .padding(.vertical, 8)
    }
}
