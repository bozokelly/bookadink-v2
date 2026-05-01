import SwiftUI
import Charts

struct DUPRHistoryCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var chartAppeared = false
    /// nil = idle → latest point is shown. Set while user drags.
    @State private var selectedEntry: DUPREntry? = nil

    private static let labelFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    // MARK: - Data pipeline

    /// Raw history, sorted ascending by date. Source of truth for all stats.
    private var history: [DUPREntry] {
        appState.duprHistory.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Chart-ready entries:
    /// 1. Capped at last 20 raw entries
    /// 2. Deduped by calendar day — latest value per day wins
    /// 3. Sorted strictly ascending
    ///
    /// One entry per day guarantees no two points share an x position,
    /// which is the only way to prevent interpolation artifacts with a
    /// linear method on a continuous time axis.
    private var chartEntries: [DUPREntry] {
        let raw = Array(history.suffix(20))
        let cal = Calendar.current
        var dayBuckets: [DateComponents: DUPREntry] = [:]
        for entry in raw {
            // raw is ascending → last write wins (latest value per day)
            let key = cal.dateComponents([.year, .month, .day], from: entry.recordedAt)
            dayBuckets[key] = entry
        }
        return dayBuckets.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    // MARK: - Stats

    private var highestRating: Double? { history.map(\.rating).max() }

    private var thisMonthChange: Double? {
        let cutoff = Calendar.current.date(byAdding: Calendar.Component.day, value: -30, to: Date()) ?? Date()
        let recent = history.filter { $0.recordedAt >= cutoff }
        guard recent.count >= 2,
              let firstRating = recent.first?.rating,
              let lastRating  = recent.last?.rating else { return nil }
        return lastRating - firstRating
    }

    private var threeMonthAverage: Double? {
        let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        let recent = history.filter { $0.recordedAt >= cutoff }
        guard !recent.isEmpty else { return nil }
        return recent.map(\.rating).reduce(0, +) / Double(recent.count)
    }

    // MARK: - Body

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

            let entries = chartEntries
            if entries.count < 2 {
                emptyState
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                statsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                sparkline(for: entries)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .onAppear {
            withAnimation(.easeIn(duration: 0.45).delay(0.1)) { chartAppeared = true }
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                label: "Highest",
                value: highestRating.map { String(format: "%.3f", $0) } ?? "—",
                valueColor: Brand.ink,
                deltaIcon: nil
            )
            statCell(
                label: "This Month",
                value: thisMonthChange.map { ($0 >= 0 ? "+" : "") + String(format: "%.3f", $0) } ?? "—",
                valueColor: thisMonthChange.map { $0 >= 0 ? Brand.emeraldAction : Brand.errorRed } ?? Brand.ink,
                deltaIcon: thisMonthChange.map { $0 >= 0 ? "arrow.up" : "arrow.down" }
            )
            statCell(
                label: "3 Month Avg",
                value: threeMonthAverage.map { String(format: "%.3f", $0) } ?? "—",
                valueColor: Brand.ink,
                deltaIcon: nil
            )
        }
    }

    private func statCell(label: String, value: String,
                          valueColor: Color, deltaIcon: String?) -> some View {
        VStack(alignment: .center, spacing: 4) {
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

    private func sparkline(for entries: [DUPREntry]) -> some View {
        // Y scale
        let ratings = entries.map(\.rating)
        let dataMin = ratings.min() ?? 2.0
        let dataMax = ratings.max() ?? 3.5
        let yMin    = dataMin - 0.15
        let yMax    = dataMax + 0.15

        // Whole-number y-axis anchors (e.g. 3.0, 4.0, 5.0)
        var yAnchors: [Double] = []
        var yv = floor(yMin)
        while yv <= ceil(yMax) { yAnchors.append(yv); yv += 1.0 }

        let axisWeeks   = weeklyAxisDates(from: entries)
        let lastEntry   = entries.last
        // Idle → show latest. Dragging → show touched point.
        let activeEntry = selectedEntry ?? lastEntry

        return Chart(entries) { entry in
            // ── Line ────────────────────────────────────────────────────────
            // linear only — reflects exact point-to-point changes
            LineMark(
                x: .value("Date", entry.recordedAt),
                y: .value("Rating", entry.rating)
            )
            .foregroundStyle(Brand.ink.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.linear)

            // ── Active point: vertical guide ─────────────────────────────
            if entry.id == activeEntry?.id {
                RuleMark(x: .value("Date", entry.recordedAt))
                    .foregroundStyle(Brand.ink.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }

            // ── Active point: accent dot ─────────────────────────────────
            if entry.id == activeEntry?.id {
                PointMark(
                    x: .value("Date", entry.recordedAt),
                    y: .value("Rating", entry.rating)
                )
                .foregroundStyle(.clear)
                .symbolSize(0)
                .annotation(position: .overlay) {
                    Circle()
                        .fill(Brand.accentGreen)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                }

                // ── Active point: label (value + date) ───────────────────
                PointMark(
                    x: .value("Date", entry.recordedAt),
                    y: .value("Rating", entry.rating)
                )
                .foregroundStyle(.clear)
                .symbolSize(0)
                .annotation(position: .top, spacing: 14) {
                    VStack(spacing: 1) {
                        Text(String(format: "%.3f", entry.rating))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text(DUPRHistoryCard.labelFmt.string(from: entry.recordedAt))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Brand.mutedText)
                    }
                    .fixedSize()
                }
            }
        }
        // Top inset = room for annotation above highest point.
        // Bottom inset = room for x-axis labels below the plot canvas.
        .chartPlotStyle { plot in
            plot.padding(EdgeInsets(top: 40, leading: 4, bottom: 28, trailing: 24))
        }
        // ── Gesture overlay ──────────────────────────────────────────────────
        // DragGesture(minimumDistance: 0) makes taps register instantly.
        // No animation on onChange — instant snap matches Apple Health / Stocks.
        // On lift, clear immediately; the idle state restores the latest dot.
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let plotOriginX = geo[proxy.plotAreaFrame].origin.x
                                let xInPlot = drag.location.x - plotOriginX
                                guard let touchDate: Date = proxy.value(atX: xInPlot) else { return }
                                let nearest = entries.min(by: {
                                    abs($0.recordedAt.timeIntervalSince(touchDate)) <
                                    abs($1.recordedAt.timeIntervalSince(touchDate))
                                })
                                // No animation — instant like Apple Stocks
                                if nearest?.id != selectedEntry?.id {
                                    selectedEntry = nearest
                                }
                            }
                            .onEnded { _ in
                                // Clear immediately on lift; active dot returns to latest
                                selectedEntry = nil
                            }
                    )
            }
        }
        // ── X-Axis ───────────────────────────────────────────────────────────
        .chartXAxis {
            AxisMarks(values: axisWeeks) { value in
                AxisGridLine()
                    .foregroundStyle(Brand.softOutline.opacity(0.08))
                AxisTick()
                    .foregroundStyle(Brand.softOutline.opacity(0.18))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(DUPRHistoryCard.labelFmt.string(from: date))
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Brand.mutedText.opacity(0.55))
                            .fixedSize()
                            .lineLimit(1)
                    }
                }
            }
        }
        // ── Y-Axis ───────────────────────────────────────────────────────────
        .chartYAxis {
            AxisMarks(position: .leading, values: yAnchors) { value in
                AxisGridLine()
                    .foregroundStyle(Brand.softOutline.opacity(0.10))
                AxisValueLabel {
                    if let r = value.as(Double.self) {
                        Text(String(format: "%.1f", r))
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(Brand.mutedText.opacity(0.5))
                    }
                }
            }
        }
        .chartYScale(domain: yMin...yMax)
        .frame(height: 190)
        // Fade-in on first render — chart is hidden until onAppear fires
        .opacity(chartAppeared ? 1 : 0)
        .animation(.easeIn(duration: 0.5), value: chartAppeared)
    }

    // MARK: - Weekly axis dates

    /// Generates ISO week-start dates across the data range at a density
    /// that keeps label count between 4 and 6.
    private func weeklyAxisDates(from entries: [DUPREntry]) -> [Date] {
        guard let first = entries.first?.recordedAt,
              let last  = entries.last?.recordedAt else { return [] }

        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current

        let daySpan    = cal.dateComponents([.day], from: first, to: last).day ?? 0
        let weekSpan   = max(1, (daySpan + 6) / 7)
        let stride: Int
        switch weekSpan {
        case ..<5:  stride = 1
        case 5..<9: stride = 2
        default:    stride = 4
        }

        var dates: [Date] = []
        var cursor = cal.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        while cursor <= last {
            dates.append(cursor)
            guard let next = cal.date(byAdding: .weekOfYear, value: stride, to: cursor) else { break }
            cursor = next
        }
        // Always include the week containing the final point
        if let lastWeek = cal.dateInterval(of: .weekOfYear, for: last)?.start,
           dates.last.map({ $0 < lastWeek }) ?? true {
            dates.append(lastWeek)
        }
        return dates
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
