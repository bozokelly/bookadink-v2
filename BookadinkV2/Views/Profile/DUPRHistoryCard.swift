import SwiftUI
import Charts

struct DUPRHistoryCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var chartAppeared = false

    private static let shortDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM"
        return f
    }()

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
            return String(format: "↑ Up %.2f this month", delta)
        } else if delta < -0.05 {
            return String(format: "↓ Down %.2f this month", abs(delta))
        } else {
            return "Steady — less than 0.05 change this month"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("DUPR Rating", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                NavigationLink(destination: DUPRHistoryDetailView()) {
                    Text("See All")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Brand.secondarySurface, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            if history.count < 2 {
                emptyState
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                // Stats row — uniform style, no colored backgrounds
                statsRow
                    .padding(.horizontal, 16)

                Divider()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                // Chart — embedded in its own padded container
                sparkline
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Brand.secondarySurface)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // Insight — own clear zone below the chart container
                Text(insightText)
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .onAppear { withAnimation(.easeIn(duration: 0.45).delay(0.1)) { chartAppeared = true } }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                label: "Current",
                value: currentRating.map { String(format: "%.3f", $0) } ?? "—",
                valueColor: Brand.ink,
                deltaIcon: nil
            )

            Divider()
                .frame(height: 32)

            statCell(
                label: "Highest",
                value: highestRating.map { String(format: "%.3f", $0) } ?? "—",
                valueColor: Brand.ink,
                deltaIcon: nil
            )

            if let change = recentChange {
                Divider()
                    .frame(height: 32)

                let positive = change >= 0
                statCell(
                    label: "Last Change",
                    value: (positive ? "+" : "") + String(format: "%.3f", change),
                    valueColor: positive ? Brand.emeraldAction : Brand.errorRed,
                    deltaIcon: positive ? "arrow.up" : "arrow.down"
                )
            }
        }
        .padding(.bottom, 2)
    }

    private func statCell(
        label: String,
        value: String,
        valueColor: Color,
        deltaIcon: String?
    ) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Brand.mutedText)
                .textCase(.uppercase)
                .tracking(0.4)
            HStack(spacing: 3) {
                if let icon = deltaIcon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(valueColor)
                }
                Text(value)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(valueColor)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Chart

    private var sparkline: some View {
        let entries = Array(history.suffix(10))
        let ratings = entries.map(\.rating)
        let dataMin = ratings.min() ?? 2.0
        let dataMax = ratings.max() ?? 3.5
        // Padding above and below the data range so dots never sit on the axis edges
        let yMin = dataMin - 0.1
        let yMax = dataMax + 0.1

        return Chart(entries) { entry in
            LineMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(Brand.ink)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .interpolationMethod(.catmullRom)

            // Custom dot — black with white ring
            PointMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(.clear)
            .symbolSize(0)
            .annotation(position: .overlay) {
                Circle()
                    .fill(Brand.ink)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }

            // Date label anchored directly under each dot — never clipped by axis renderer
            PointMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(.clear)
            .symbolSize(0)
            .annotation(position: .bottom, spacing: 5) {
                Text(DUPRHistoryCard.shortDateFmt.string(from: entry.recordedAt))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Brand.mutedText)
                    .fixedSize()
            }
        }
        .chartPlotStyle { plot in
            // Extra bottom inset gives annotation labels room inside the plot canvas
            plot.padding(EdgeInsets(top: 12, leading: 4, bottom: 28, trailing: 20))
        }
        .chartXAxis(.hidden)
        // Y axis — DUPR values on the left
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Brand.softOutline.opacity(0.6))
                AxisTick()
                    .foregroundStyle(Brand.softOutline)
                AxisValueLabel {
                    if let rating = value.as(Double.self) {
                        Text(String(format: "%.2f", rating))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Brand.mutedText)
                    }
                }
            }
        }
        .chartYScale(domain: yMin...yMax)
        .frame(height: 190)
        .opacity(chartAppeared ? 1 : 0)
        .animation(.easeIn(duration: 0.5), value: chartAppeared)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(Brand.accentGreen)
            Text("Log your first DUPR update to start tracking your progress.")
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
        }
        .padding(.vertical, 8)
    }
}
