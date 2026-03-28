import SwiftUI
import Charts

struct GamesPlayedCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var chartAppeared = false

    private struct MonthData: Identifiable {
        let id: Date
        var month: Date { id }
        let count: Int
        let isCurrent: Bool
        var label: String {
            month.formatted(.dateTime.month(.abbreviated))
        }
    }

    private var confirmedBookings: [BookingWithGame] {
        appState.bookings.filter {
            if case .confirmed = $0.booking.state { return true }
            return false
        }
    }

    private var totalGames: Int { confirmedBookings.count }

    private var gamesThisMonth: Int {
        let cal = Calendar.current
        let now = Date()
        return confirmedBookings.filter { item in
            guard let date = item.game?.dateTime else { return false }
            return cal.isDate(date, equalTo: now, toGranularity: .month)
        }.count
    }

    private var monthlyData: [MonthData] {
        let cal = Calendar.current
        let now = Date()
        return (0..<6).reversed().compactMap { offset -> MonthData? in
            guard let monthDate = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
            let comps = cal.dateComponents([.year, .month], from: monthDate)
            let start = cal.date(from: comps) ?? monthDate
            let count = confirmedBookings.filter { item in
                guard let date = item.game?.dateTime else { return false }
                let dc = cal.dateComponents([.year, .month], from: date)
                return dc.year == comps.year && dc.month == comps.month
            }.count
            return MonthData(id: start, count: count, isCurrent: cal.isDate(monthDate, equalTo: now, toGranularity: .month))
        }
    }

    private var peakMonth: MonthData? {
        monthlyData.max(by: { $0.count < $1.count })
    }

    private var insightText: String? {
        let cal = Calendar.current
        let games = confirmedBookings.compactMap(\.game)
        guard games.count >= 3 else { return nil }
        var dayCounts = [Int: Int]()
        for game in games {
            let weekday = cal.component(.weekday, from: game.dateTime)
            dayCounts[weekday, default: 0] += 1
        }
        guard let (topDay, _) = dayCounts.max(by: { $0.value < $1.value }) else { return nil }
        return "Most active on \(cal.weekdaySymbols[topDay - 1])s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Games Played")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                    Text("\(totalGames)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("This month")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Brand.mutedText)
                    Text("\(gamesThisMonth)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(gamesThisMonth > 0 ? Brand.pineTeal : Brand.mutedText)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if totalGames == 0 {
                emptyState
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                // Chart
                lineChart
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                // Footer insight
                if let insight = insightText {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.caption2)
                            .foregroundStyle(Brand.pineTeal)
                        Text(insight)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Brand.mutedText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                } else {
                    Spacer().frame(height: 14)
                }
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.15)) {
                chartAppeared = true
            }
        }
    }

    // MARK: - Line Chart

    private var lineChart: some View {
        let maxCount = max(monthlyData.map(\.count).max() ?? 1, 1)

        return Chart {
            ForEach(monthlyData) { item in
                // Area fill
                AreaMark(
                    x: .value("Month", item.month, unit: .month),
                    y: .value("Games", chartAppeared ? item.count : 0)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Brand.pineTeal.opacity(0.25), Brand.pineTeal.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                // Line
                LineMark(
                    x: .value("Month", item.month, unit: .month),
                    y: .value("Games", chartAppeared ? item.count : 0)
                )
                .foregroundStyle(Brand.pineTeal)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                // Dot on current month
                if item.isCurrent {
                    PointMark(
                        x: .value("Month", item.month, unit: .month),
                        y: .value("Games", chartAppeared ? item.count : 0)
                    )
                    .foregroundStyle(Brand.pineTeal)
                    .symbolSize(50)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Brand.mutedText)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Brand.mutedText)
            }
        }
        .chartYScale(domain: 0...(maxCount + 1))
        .frame(height: 130)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: chartAppeared)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.pickleball")
                .font(.title2)
                .foregroundStyle(Brand.pineTeal.opacity(0.45))
            Text("No games yet. Book your first session to start tracking.")
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }
}
