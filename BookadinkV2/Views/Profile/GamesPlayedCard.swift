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
            let isCurrent = cal.isDate(monthDate, equalTo: now, toGranularity: .month)
            return MonthData(id: start, count: count, isCurrent: isCurrent)
        }
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
        return "Most active: \(cal.weekdaySymbols[topDay - 1])s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Games Played", systemImage: "figure.pickleball")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
            }

            if totalGames == 0 {
                emptyState
            } else {
                statRow
                barChart
                if let insight = insightText {
                    Text(insight)
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .onAppear { withAnimation(.easeIn(duration: 0.4).delay(0.1)) { chartAppeared = true } }
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            statPill(label: "Total", value: "\(totalGames)", background: Color(.systemGray6), valueColor: Brand.ink)
            statPill(label: "This Month", value: "\(gamesThisMonth)", background: Brand.pineTeal.opacity(0.1), valueColor: Brand.pineTeal)
        }
    }

    private func statPill(label: String, value: String, background: Color, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Brand.mutedText)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var barChart: some View {
        Chart(monthlyData) { item in
            BarMark(
                x: .value("Month", item.month, unit: .month),
                y: .value("Games", item.count)
            )
            .foregroundStyle(item.isCurrent ? Brand.pineTeal : Brand.slateBlue.opacity(0.55))
            .cornerRadius(5)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.2))
            }
        }
        .frame(height: 90)
        .opacity(chartAppeared ? 1 : 0)
        .animation(.easeIn(duration: 0.5), value: chartAppeared)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.pickleball")
                .font(.title2)
                .foregroundStyle(Brand.pineTeal.opacity(0.5))
            Text("No games recorded yet. Book your first session to get started.")
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
        }
        .padding(.vertical, 8)
    }
}
