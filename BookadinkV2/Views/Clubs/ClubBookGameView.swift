import SwiftUI

// MARK: - Game Availability

enum GameAvailability {
    case available   // spots open
    case limited     // ≤3 spots left
    case full        // 0 spots
}

// MARK: - Club Book Game View

struct ClubBookGameView: View {
    let club: Club
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var displayedMonth: Date = {
        var comps = Calendar.current.dateComponents([.year, .month], from: Date())
        comps.day = 1
        return Calendar.current.date(from: comps) ?? Date()
    }()

    private var allGames: [Game] {
        let now = Date()
        return appState.games(for: club)
            .filter { $0.dateTime >= now }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var gamesForSelectedDate: [Game] {
        allGames.filter { Calendar.current.isDate($0.dateTime, inSameDayAs: selectedDate) }
    }

    private var otherUpcomingGames: [Game] {
        allGames.filter { !Calendar.current.isDate($0.dateTime, inSameDayAs: selectedDate) }
    }

    private var availability: [Date: GameAvailability] {
        var map: [Date: GameAvailability] = [:]
        for game in allGames {
            let day = Calendar.current.startOfDay(for: game.dateTime)
            let current = map[day]
            let next: GameAvailability
            guard let spots = game.spotsLeft else {
                // confirmedCount not yet loaded — treat as available so we never show a false red
                if current == nil { map[day] = .available }
                continue
            }
            let threshold = max(1, game.maxSpots / 2)
            if spots == 0 {
                next = .full
            } else if spots <= threshold {
                next = .limited
            } else {
                next = .available
            }
            // Merge: prefer available > limited > full
            switch current {
            case nil: map[day] = next
            case .available: break
            case .limited: if next == .available { map[day] = next }
            case .full: if next != .full { map[day] = next }
            }
        }
        return map
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Nav bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 38, height: 38)
                                .background(Brand.secondarySurface, in: Circle())
                        }
                        .buttonStyle(.plain)
                        Text("Book a Game")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Brand.ink)
                        Spacer()
                    }
                    Text(club.name)
                        .font(.subheadline)
                        .foregroundStyle(Brand.mutedText)
                        .padding(.leading, 52)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .background(Color(.systemBackground))

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        MonthlyCalendarView(
                            selectedDate: $selectedDate,
                            displayedMonth: $displayedMonth,
                            availability: availability
                        )

                        Divider()

                        gamesListSection
                            .padding(.horizontal, 16)
                            .padding(.top, 20)
                            .padding(.bottom, 36)
                    }
                }
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Game.self) { game in
                GameDetailView(game: game)
            }
            .onAppear {
                Task { await appState.refreshGames(for: club) }
            }
        }
    }

    // MARK: - Games List Section

    @ViewBuilder
    private var gamesListSection: some View {
        if appState.isLoadingGames(for: club) && allGames.isEmpty {
            ProgressView("Loading games...")
                .tint(Brand.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if allGames.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(Brand.mutedText)
                Text("No upcoming games")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Text("Check back soon or contact the club.")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                let hasSelectedGames = !gamesForSelectedDate.isEmpty

                if hasSelectedGames {
                    // Selected date header
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 2)

                    ForEach(gamesForSelectedDate) { game in
                        gameCard(game)
                    }

                    if !otherUpcomingGames.isEmpty {
                        sectionDivider("All Upcoming Games")
                        ForEach(otherUpcomingGames) { game in
                            gameCard(game)
                        }
                    }
                } else {
                    // No games on selected date — show helpful note then all upcoming
                    if !Calendar.current.isDateInToday(selectedDate) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.caption)
                                .foregroundStyle(Brand.mutedText)
                            Text("No games on this date")
                                .font(.caption)
                                .foregroundStyle(Brand.mutedText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    }

                    sectionDivider("Upcoming Games")

                    ForEach(allGames) { game in
                        gameCard(game)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gameCard(_ game: Game) -> some View {
        let venues = appState.clubVenuesByClubID[game.clubID] ?? []
        let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
        NavigationLink(value: game) {
            UnifiedGameCard(
                game: game,
                clubName: club.name,
                isBooked: appState.bookingState(for: game) == .confirmed,
                isWaitlisted: {
                    if case .waitlisted = appState.bookingState(for: game) { return true }
                    return false
                }(),
                resolvedVenue: resolvedVenue
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionDivider(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Brand.mutedText)
            .textCase(.uppercase)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: - Monthly Calendar View

struct MonthlyCalendarView: View {
    @Binding var selectedDate: Date
    @Binding var displayedMonth: Date
    let availability: [Date: GameAvailability]

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdaySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var monthTitle: String {
        displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    private var daysInGrid: [Date?] {
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth)),
              let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }

        let firstWeekday = cal.component(.weekday, from: monthStart) - 1 // 0 = Sunday
        let leadingEmpties = firstWeekday
        var days: [Date?] = Array(repeating: nil, count: leadingEmpties)

        for day in range {
            if let date = cal.date(byAdding: .day, value: day - 1, to: monthStart) {
                days.append(cal.startOfDay(for: date))
            }
        }

        // Pad trailing to complete last row
        let remainder = days.count % 7
        if remainder != 0 {
            days.append(contentsOf: Array(repeating: nil, count: 7 - remainder))
        }
        return days
    }

    var body: some View {
        VStack(spacing: 12) {
            // Month navigation header
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 36, height: 36)
                        .background(Brand.secondarySurface, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(monthTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Brand.ink)
                    .animation(.none, value: displayedMonth)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 36, height: 36)
                        .background(Brand.secondarySurface, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)

            // Day grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(daysInGrid.enumerated()), id: \.offset) { _, date in
                    if let date {
                        CalendarDayCell(
                            date: date,
                            isSelected: cal.isDate(date, inSameDayAs: selectedDate),
                            isToday: cal.isDateInToday(date),
                            availability: availability[date]
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedDate = date
                            }
                        }
                    } else {
                        Color.clear
                            .frame(height: 46)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 16)
        .background(Color(.systemBackground))
    }
}

// MARK: - Calendar Day Cell

private struct CalendarDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let availability: GameAvailability?

    var body: some View {
        VStack(spacing: 3) {
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 15, weight: isSelected || isToday ? .bold : .regular))
                .foregroundStyle(cellTextColor)
                .frame(width: 34, height: 34)
                .background(cellBackground)

            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .opacity(availability != nil ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var cellBackground: some View {
        if isSelected {
            Circle().fill(Brand.primaryText)
        } else if isToday {
            Circle().stroke(Brand.primaryText, lineWidth: 1.5)
        } else {
            Color.clear
        }
    }

    private var cellTextColor: Color {
        if isSelected { return .white }
        if isToday { return Brand.primaryText }
        return Brand.ink
    }

    private var dotColor: Color {
        switch availability {
        case .available: return Brand.emeraldAction
        case .limited:   return Brand.spicyOrange
        case .full:      return Brand.errorRed
        case nil:        return .clear
        }
    }
}

