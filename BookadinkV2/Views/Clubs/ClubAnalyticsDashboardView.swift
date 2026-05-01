import SwiftUI
import Charts
import UIKit


// MARK: - Analytics Dashboard

struct ClubAnalyticsDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    let club: Club
    var isDemo: Bool = false

    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @State private var showUpgradePaywall = false
    @State private var period: AnalyticsPeriod = .last30
    @State private var activeTab: AnalyticsTab = .overview
    @State private var chartMetric: ChartMetric = .revenue
    @State private var useCustomRange = false
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

    // MARK: - Derived state

    private var isLoading: Bool  { appState.loadingAnalyticsClubIDs.contains(club.id) }
    private var kpis:      ClubAnalyticsKPIs?          { appState.analyticsKPIsByClubID[club.id] }
    private var supp:      ClubAnalyticsSupplemental?  { appState.analyticsSupplementalByClubID[club.id] }
    private var trend:     [ClubRevenueTrendPoint]     { appState.revenueTrendByClubID[club.id] ?? [] }
    private var topGames:  [ClubTopGame]               { appState.topGamesByClubID[club.id] ?? [] }
    private var peakTimes: [ClubPeakTime]              { appState.peakTimesByClubID[club.id] ?? [] }

    private var hasData: Bool        { kpis != nil }
    private var analyticsError: String? { appState.analyticsErrorByClubID[club.id] }

    /// Days to pass to the analytics RPC.
    /// For custom ranges, uses the span between the two selected dates.
    private var activeDays: Int {
        guard useCustomRange else { return period.rawValue }
        let end  = max(customEndDate, customStartDate)
        let diff = Calendar.current.dateComponents([.day], from: customStartDate, to: end).day ?? 30
        return max(1, diff)
    }

    private var activeStartDate: Date? {
        guard useCustomRange else { return nil }
        return Calendar.current.startOfDay(for: customStartDate)
    }

    private var activeEndDate: Date? {
        guard useCustomRange else { return nil }
        let cal = Calendar.current
        let endDay = max(customEndDate, customStartDate)
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDay))
    }

    private static let rangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private var customRangeLabel: String {
        let s = Self.rangeFmt.string(from: customStartDate)
        let e = Self.rangeFmt.string(from: customEndDate)
        return "\(s) – \(e)"
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                periodPicker
                    .padding(.horizontal, isIPad ? 24 : 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                if !isDemo && hasData {
                    tabPicker
                        .padding(.horizontal, isIPad ? 24 : 16)
                        .padding(.bottom, 16)
                }

                if isDemo {
                    demoAnalyticsContent
                } else if isLoading && !hasData {
                    loadingView
                } else if !hasData {
                    emptyView
                } else {
                    tabContent
                        .padding(.horizontal, isIPad ? 24 : 16)
                        .padding(.bottom, 32)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .task { if !isDemo { await load() } }
        .onChange(of: period) { _, _ in
            if !isDemo { Task { await load() } }
        }
        // Refresh after cancellation (credit issued → booking count/revenue changes)
        .onChange(of: appState.lastCancellationCredit) { _, _ in
            if !isDemo { Task { await load() } }
        }
        // Refresh after a new confirmed booking (booking counts, fill rate, revenue)
        .onChange(of: appState.lastConfirmedBookingClubID) { _, clubID in
            if clubID == club.id, !isDemo { Task { await load() } }
        }
        // Refresh after attendance change (no-show rate)
        .onChange(of: appState.lastAttendanceUpdateClubID) { _, clubID in
            if clubID == club.id, !isDemo { Task { await load() } }
        }
        // Refresh when returning to foreground (payment completion, off-app state changes)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isDemo { Task { await load() } }
        }
        .sheet(isPresented: $showUpgradePaywall) {
            ClubUpgradePaywallView(club: club, lockedFeature: .analytics)
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(AnalyticsTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                } label: {
                    Text(tab.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(activeTab == tab ? Color.white : Brand.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            activeTab == tab
                                ? Brand.primaryText
                                : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: activeTab)
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .overview:
            VStack(spacing: 16) {
                kpiGrid
                trendChartSection
                if let kpis { asOfFooter(kpis.asOf) }
            }
        case .members:
            VStack(spacing: 16) {
                memberActivitySection
                playerInsightsSection
                if let kpis { asOfFooter(kpis.asOf) }
            }
        case .operations:
            VStack(spacing: 16) {
                if kpis?.currRevenueCents ?? 0 > 0 { revenueBreakdownSection }
                operationsSection
                if !topGames.isEmpty  { topGamesCard }
                if !peakTimes.isEmpty { peakTimesCard }
                if let kpis { asOfFooter(kpis.asOf) }
            }
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AnalyticsPeriod.allCases) { p in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            period = p
                            useCustomRange = false
                        }
                    } label: {
                        Text(p.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(!useCustomRange && period == p ? Color.white : Brand.primaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                !useCustomRange && period == p
                                    ? Brand.primaryText
                                    : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: period)
                    .animation(.easeInOut(duration: 0.2), value: useCustomRange)
                }

                // Custom range button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { useCustomRange = true }
                } label: {
                    Text(useCustomRange ? customRangeLabel : "Custom")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(useCustomRange ? Color.white : Brand.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            useCustomRange
                                ? Brand.primaryText
                                : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: useCustomRange)
            }

            // Date range pickers — slide in when custom is active
            if useCustomRange {
                VStack(spacing: 0) {
                    // Start date
                    HStack {
                        Text("From")
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                            .frame(width: 36, alignment: .leading)
                        DatePicker(
                            "",
                            selection: $customStartDate,
                            in: ...customEndDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .onChange(of: customStartDate) { _, newVal in
                            // Keep end >= start
                            if customEndDate < newVal { customEndDate = newVal }
                            Task { await load() }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Divider().padding(.horizontal, 12)

                    // End date
                    HStack {
                        Text("To")
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                            .frame(width: 36, alignment: .leading)
                        DatePicker(
                            "",
                            selection: $customEndDate,
                            in: customStartDate...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .onChange(of: customEndDate) { _, _ in Task { await load() } }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - KPI Grid (Revenue · Bookings · Fill Rate · Active Players)

    private var kpiGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: isIPad ? 4 : 2),
            spacing: 12
        ) {
            if let k = kpis {
                KPICard(
                    label: "Revenue",
                    value: centsToString(k.currRevenueCents, currency: k.currency),
                    prev:  centsToString(k.prevRevenueCents, currency: k.currency),
                    direction: deltaDirection(k.currRevenueCents, k.prevRevenueCents),
                    compLabel: period.comparisonLabel,
                    icon: "dollarsign.circle.fill",
                    description: "Total income collected from game booking fees in this period."
                )
                KPICard(
                    label: "Bookings",
                    value: "\(k.currBookingCount)",
                    prev:  "\(k.prevBookingCount)",
                    direction: deltaDirection(k.currBookingCount, k.prevBookingCount),
                    compLabel: period.comparisonLabel,
                    icon: "ticket.fill",
                    description: "Number of confirmed player bookings across all games in this period."
                )
                KPICard(
                    label: "Fill Rate",
                    value: percentString(k.currFillRate),
                    prev:  percentString(k.prevFillRate),
                    direction: deltaDirection(k.currFillRate, k.prevFillRate),
                    compLabel: period.comparisonLabel,
                    icon: "chart.bar.fill",
                    description: "Average percentage of available spots filled per game. Higher is better."
                )
                KPICard(
                    label: "Active Players",
                    value: "\(k.currActivePlayers)",
                    prev:  "\(k.prevActivePlayers)",
                    direction: deltaDirection(k.currActivePlayers, k.prevActivePlayers),
                    compLabel: period.comparisonLabel,
                    icon: "person.2.fill",
                    description: "Unique players who booked at least one game in this period."
                )
            }
        }
    }

    // MARK: - Member Activity

    private var memberActivitySection: some View {
        sectionCard(title: "Membership", icon: "person.badge.plus") {
            HStack(spacing: 10) {
                statTile(
                    label: "Joined",
                    value: supp.map { "\($0.currMemberJoins)" } ?? "—",
                    sub: memberJoinDelta,
                    subColor: memberJoinDeltaColor
                )
                statTile(
                    label: "Total Members",
                    value: supp.map { "\($0.totalActiveMembers)" } ?? "—",
                    sub: "approved"
                )
                statTile(
                    label: "New Players",
                    value: supp.map { "\($0.currNewPlayers)" } ?? "—",
                    sub: "first booking"
                )
            }
        }
    }

    private var memberJoinDelta: String? {
        guard let s = supp else { return nil }
        let diff = s.currMemberJoins - s.prevMemberJoins
        if diff == 0 { return "same as prior" }
        return diff > 0 ? "+\(diff) vs prior" : "\(diff) vs prior"
    }

    private var memberJoinDeltaColor: Color {
        guard let s = supp else { return Brand.tertiaryText }
        let diff = s.currMemberJoins - s.prevMemberJoins
        if diff > 0 { return Brand.emeraldAction }
        if diff < 0 { return Brand.errorRed }
        return Brand.tertiaryText
    }

    // MARK: - Revenue Breakdown (only shown when revenue > 0)

    private var revenueBreakdownSection: some View {
        sectionCard(title: "Revenue Breakdown", icon: "creditcard.fill") {
            if let k = kpis, let s = supp {
                VStack(spacing: 10) {
                    // Row 1: Gross → Platform Fee → Club Net
                    HStack(spacing: 10) {
                        statTile(
                            label: "Gross Revenue",
                            value: centsToString(k.currGrossRevenueCents, currency: k.currency),
                            sub: "player-paid total"
                        )
                        statTile(
                            label: "Platform Fee",
                            value: k.currPlatformFeeCents > 0
                                ? centsToString(k.currPlatformFeeCents, currency: k.currency)
                                : "—",
                            sub: "app fee"
                        )
                        statTile(
                            label: "Club Payout",
                            value: centsToString(k.currRevenueCents, currency: k.currency),
                            sub: "net revenue"
                        )
                    }
                    // Row 2: Credits Used | Cancelled (refunded) | Avg per Player
                    HStack(spacing: 10) {
                        statTile(
                            label: "Credits Used",
                            value: k.currCreditsUsedCents > 0
                                ? centsToString(k.currCreditsUsedCents, currency: k.currency)
                                : "—",
                            sub: s.currCreditBookingCount > 0
                                ? "\(s.currCreditBookingCount) credit-only, \(s.currCompBookingCount) comp"
                                : "\(s.currCompBookingCount) comp, \(s.currTrulyFreeBookingCount) free"
                        )
                        statTile(
                            label: "Credits Returned",
                            value: k.currCreditsReturnedCents > 0
                                ? centsToString(k.currCreditsReturnedCents, currency: k.currency)
                                : "—",
                            sub: k.currCreditReturnCount > 0
                                ? "\(k.currCreditReturnCount) cancellation\(k.currCreditReturnCount == 1 ? "" : "s")"
                                : "no eligible cancels",
                            subColor: k.currCreditsReturnedCents > 0 ? Brand.errorRed : Brand.tertiaryText
                        )
                        statTile(
                            label: "Avg per Player",
                            value: s.avgRevPerPlayerCents > 0
                                ? centsToString(s.avgRevPerPlayerCents, currency: k.currency)
                                : "—",
                            sub: "paying players"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Operations

    private var operationsSection: some View {
        sectionCard(title: "Operations", icon: "gearshape.fill") {
            HStack(spacing: 10) {
                // No-show rate — only shown when attendance data exists
                if let rate = supp?.noShowRate {
                    statTile(
                        label: "No-show Rate",
                        value: percentString(rate),
                        sub: "of checked in",
                        subColor: rate > 0.15 ? Brand.errorRed : Brand.tertiaryText
                    )
                } else {
                    statTile(label: "No-shows", value: "—", sub: "not tracked")
                }

                statTile(
                    label: "Waitlist",
                    value: supp.map { "\($0.currWaitlistCount)" } ?? "—",
                    sub: "active demand"
                )

                statTile(
                    label: "Games Hosted",
                    value: supp.map { "\($0.currGameCount)" } ?? "—",
                    sub: "completed"
                )
            }
        }
    }

    // MARK: - Trend Chart

    private var trendChartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            analyticsHeader(title: "Trend", icon: "chart.line.uptrend.xyaxis")

            HStack(spacing: 6) {
                ForEach(ChartMetric.allCases) { m in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { chartMetric = m }
                    } label: {
                        Text(m.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(chartMetric == m ? Color.white : Brand.secondaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                chartMetric == m
                                    ? Brand.primaryText
                                    : Color(.secondarySystemGroupedBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: chartMetric)
                }
                Spacer()
            }

            if trend.isEmpty {
                chartEmptyState
            } else {
                trendChart
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var trendChart: some View {
        let values = trend.map { chartMetric.value(from: $0) }
        let dataMax = values.max() ?? 1
        let yMax = dataMax > 0 ? dataMax * 1.2 : 1

        return Chart(trend) { point in
            AreaMark(
                x: .value("Date", point.bucketDate),
                y: .value(chartMetric.label, chartMetric.value(from: point))
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Brand.ink.opacity(0.12), Brand.ink.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Date", point.bucketDate),
                y: .value(chartMetric.label, chartMetric.value(from: point))
            )
            .foregroundStyle(Brand.ink)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(period == .last7
                                         ? .dateTime.day().month(.abbreviated)
                                         : period == .last30
                                             ? .dateTime.day().month(.abbreviated)
                                             : .dateTime.month(.abbreviated).year(.twoDigits)))
                            .font(.caption2)
                            .foregroundStyle(Brand.mutedText)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Brand.dividerColor)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(chartMetric.formatAxisLabel(v))
                            .font(.caption2)
                            .foregroundStyle(Brand.mutedText)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Brand.dividerColor)
            }
        }
        .frame(height: isIPad ? 220 : 160)
    }

    private var chartEmptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24))
                    .foregroundStyle(Brand.mutedText)
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }
            Spacer()
        }
        .frame(height: isIPad ? 180 : 120)
    }

    // MARK: - Player Insights

    private var playerInsightsSection: some View {
        sectionCard(title: "Player Behaviour", icon: "person.fill.checkmark") {
            HStack(spacing: 10) {
                if let k = kpis {
                    statTile(
                        label: "Repeat Rate",
                        value: percentString(k.repeatPlayerRate),
                        sub: "played 2+ games",
                        subColor: k.repeatPlayerRate > 0.5 ? Brand.emeraldAction : Brand.tertiaryText
                    )
                    statTile(
                        label: "Cancellation",
                        value: percentString(k.cancellationRate),
                        sub: "of all bookings",
                        subColor: k.cancellationRate > 0.2 ? Brand.errorRed : Brand.tertiaryText
                    )
                    if supp != nil, k.currActivePlayers > 0 {
                        let avg = Double(k.currBookingCount) / Double(k.currActivePlayers)
                        statTile(
                            label: "Avg Games",
                            value: String(format: "%.1f", avg),
                            sub: "per player"
                        )
                    } else {
                        statTile(label: "Avg Games", value: "—", sub: "per player")
                    }
                }
            }
        }
    }

    // MARK: - Top Games

    private var topGamesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                analyticsHeader(title: "Top Games", icon: "trophy.fill")
                Spacer()
                Text("by attendance")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            ForEach(Array(topGames.enumerated()), id: \.element.id) { index, game in
                topGameRow(rank: index + 1, game: game)
                if index < topGames.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func topGameRow(rank: Int, game: ClubTopGame) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.weight(.bold))
                .foregroundStyle(rank == 1 ? Brand.emeraldAction : Brand.mutedText)
                .frame(width: 20, alignment: .center)
                .padding(6)
                .background(
                    rank == 1 ? Brand.primaryText : Color(.tertiarySystemGroupedBackground),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                // Pattern subtitle: day + time + session count + time-to-fill (when available)
                Text({
                    var s = "\(game.dayLabel) \(game.hourLabel) · \(game.occurrenceCount) session\(game.occurrenceCount == 1 ? "" : "s")"
                    if let ttf = game.avgTimeToFillMinutes, game.filledOccurrenceCount > 0 {
                        let label: String
                        if ttf < 60 { label = "<1h" }
                        else if ttf < 1440 { label = "\(Int((ttf / 60).rounded()))h" }
                        else { label = "\(Int((ttf / 1440).rounded()))d" }
                        s += " · fills ~\(label)"
                    }
                    return s
                }())
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("avg \(String(format: "%.0f", game.avgConfirmed))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                    if game.maxSpots > 0 {
                        Text("/ \(game.maxSpots)")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                    }
                }
                fillBar(rate: game.avgFillRate)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func fillBar(rate: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(rate >= 1.0 ? Brand.emeraldAction : Brand.primaryText.opacity(0.7))
                    .frame(width: geo.size.width * min(rate, 1.0))
            }
        }
        .frame(width: 56, height: 4)
    }

    // MARK: - Peak Times

    private var peakTimesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                analyticsHeader(title: "Peak Times", icon: "clock.fill")
                Spacer()
                Text("avg attendance")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            ForEach(Array(peakTimes.enumerated()), id: \.element.id) { index, slot in
                peakTimeRow(rank: index, slot: slot)
                if index < peakTimes.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func peakTimeRow(rank: Int, slot: ClubPeakTime) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.dayLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(slot.hourLabel)
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }

            Spacer()

            let maxAvg = peakTimes.map(\.avgConfirmed).max() ?? 1
            let ratio  = maxAvg > 0 ? slot.avgConfirmed / maxAvg : 0

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(rank == 0 ? Brand.primaryText : Brand.primaryText.opacity(0.4))
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(width: 80, height: 6)

            Text(String(format: "%.1f avg", slot.avgConfirmed))
                .font(.caption.weight(.medium))
                .foregroundStyle(Brand.mutedText)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Brand.primaryText)
            Text("Loading analytics…")
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: analyticsError != nil ? "exclamationmark.triangle" : "chart.bar.doc.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(analyticsError != nil ? Brand.errorRed : Brand.mutedText)
            VStack(spacing: 6) {
                Text(analyticsError != nil ? "Couldn't load analytics" : "No analytics yet")
                    .font(.headline)
                    .foregroundStyle(Brand.primaryText)
                if let err = analyticsError {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Analytics will appear once your club has completed games and bookings.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    // MARK: - Footer

    private func asOfFooter(_ date: Date) -> some View {
        Text("Updated \(date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))")
            .font(.caption2)
            .foregroundStyle(Brand.mutedText)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Shared layout helpers

    /// Section container with a title row.
    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            analyticsHeader(title: title, icon: icon)
            content()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func analyticsHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.primaryText)
    }

    /// Single stat tile used inside sectionCard HStacks.
    private func statTile(
        label: String,
        value: String,
        sub: String? = nil,
        subColor: Color = Brand.tertiaryText
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Brand.tertiaryText)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(value == "—" ? Brand.tertiaryText : Brand.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let s = sub {
                Text(s)
                    .font(.caption2)
                    .foregroundStyle(subColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Fetch

    // MARK: - Demo Mode

    private var demoAnalyticsContent: some View {
        VStack(spacing: 16) {
            // Upgrade banner
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview Analytics")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                    Text("Upgrade to Pro to unlock live data for your club.")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer(minLength: 0)
                Button("Upgrade") { showUpgradePaywall = true }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Brand.primaryText, in: Capsule())
                    .buttonStyle(.plain)
            }
            .padding(14)
            .background(Brand.accentGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Brand.accentGreen.opacity(0.3), lineWidth: 1)
            )

            // Sample KPI grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isIPad ? 4 : 2), spacing: 12) {
                KPICard(label: "Revenue",        value: "$1,284",  prev: "$1,042",
                        direction: .up,   compLabel: "vs prev period", icon: "dollarsign.circle.fill",
                        description: "Total income collected from game booking fees in this period.")
                KPICard(label: "Bookings",       value: "48",      prev: "39",
                        direction: .up,   compLabel: "vs prev period", icon: "ticket.fill",
                        description: "Number of confirmed player bookings across all games in this period.")
                KPICard(label: "Fill Rate",      value: "76%",     prev: "68%",
                        direction: .up,   compLabel: "vs prev period", icon: "chart.bar.fill",
                        description: "Average percentage of available spots filled per game. Higher is better.")
                KPICard(label: "Active Players", value: "31",      prev: "27",
                        direction: .up,   compLabel: "vs prev period", icon: "person.2.fill",
                        description: "Unique players who booked at least one game in this period.")
            }

            // Sample data watermark footer
            Text("Sample data only · Numbers are illustrative, not real")
                .font(.caption2)
                .foregroundStyle(Brand.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(.horizontal, isIPad ? 24 : 16)
        .padding(.bottom, 32)
    }

    private func load() async {
        await appState.fetchClubAdvancedAnalytics(for: club.id, days: activeDays, startDate: activeStartDate, endDate: activeEndDate)
    }

    // MARK: - Formatters

    private func centsToString(_ cents: Int, currency: String) -> String {
        let amount = Double(cents) / 100.0
        let code = currency.isEmpty || currency.uppercased() == "USD" ? "AUD" : currency.uppercased()
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = code
        fmt.maximumFractionDigits = 0
        fmt.minimumFractionDigits = 0
        return fmt.string(from: NSNumber(value: amount)) ?? "A$\(Int(amount))"
    }

    private func percentString(_ rate: Double) -> String {
        let pct = rate * 100
        return String(format: pct.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f%%" : "%.1f%%", pct)
    }

    private func deltaDirection<T: Comparable & Numeric>(_ curr: T, _ prev: T) -> DeltaDirection {
        if prev == 0 && curr == 0 { return .none }
        if curr > prev { return .up }
        if curr < prev { return .down }
        return .flat
    }
}

// MARK: - KPI Card

private struct KPICard: View {
    let label:       String
    let value:       String
    let prev:        String
    let direction:   DeltaDirection
    let compLabel:   String
    let icon:        String
    let description: String

    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.mutedText)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                Spacer(minLength: 0)
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 4) {
                if direction != .none {
                    Image(systemName: direction == .up ? "arrow.up" : direction == .down ? "arrow.down" : "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(direction.color)
                }
                Text(compLabel)
                    .font(.caption2)
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                    Text(label)
                        .font(.headline)
                        .foregroundStyle(Brand.primaryText)
                    Spacer()
                    Button { showInfo = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Brand.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(24)
            .presentationDetents([.height(UIDevice.current.userInterfaceIdiom == .pad ? 240 : 180)])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Supporting types

private enum AnalyticsTab: String, CaseIterable, Identifiable {
    case overview    = "overview"
    case members     = "members"
    case operations  = "operations"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:   return "Overview"
        case .members:    return "Members"
        case .operations: return "Operations"
        }
    }
}

private enum DeltaDirection: Equatable {
    case up, down, flat, none

    var color: Color {
        switch self {
        case .up:         return Color(hex: "22C55E")
        case .down:       return Brand.errorRed
        case .flat, .none: return Brand.mutedText
        }
    }
}

private enum ChartMetric: String, CaseIterable, Identifiable {
    case revenue  = "revenue"
    case bookings = "bookings"
    case fillRate = "fillRate"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .revenue:  return "Revenue"
        case .bookings: return "Bookings"
        case .fillRate: return "Fill Rate"
        }
    }

    func value(from point: ClubRevenueTrendPoint) -> Double {
        switch self {
        case .revenue:  return Double(point.revenueCents) / 100.0
        case .bookings: return Double(point.bookingCount)
        case .fillRate: return point.fillRate * 100.0
        }
    }

    func formatAxisLabel(_ v: Double) -> String {
        switch self {
        case .revenue:
            if v >= 1000 { return "$\(Int(v / 1000))k" }
            return v == 0 ? "$0" : "$\(Int(v))"
        case .bookings:
            return "\(Int(v))"
        case .fillRate:
            return "\(Int(v))%"
        }
    }
}
