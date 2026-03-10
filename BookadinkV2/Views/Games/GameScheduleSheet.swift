import SwiftUI

// MARK: - Allocation Method

enum ScheduleAllocationMethod: String, CaseIterable, Identifiable {
    case random        = "Random"
    case duprBalanced  = "DUPR Balanced"
    case duprComp      = "DUPR Competitive"
    case kingOfCourt   = "King of the Court"
    case roundRobin    = "Round Robin"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .random:       return "Shuffle and assign randomly each round"
        case .duprBalanced: return "Balance teams by DUPR rating"
        case .duprComp:     return "Similar DUPR ratings on the same court"
        case .kingOfCourt:  return "Players cycle through the featured court each round"
        case .roundRobin:   return "Maximise variety of partners and opponents"
        }
    }

    var requiresDUPR: Bool { self == .duprBalanced || self == .duprComp }
}

// MARK: - Schedule Models

struct ScheduledCourt: Identifiable {
    let id = UUID()
    let number: Int
    let teamA: [GameAttendee]
    let teamB: [GameAttendee]
}

struct ScheduledRound: Identifiable {
    let id = UUID()
    let number: Int
    let courts: [ScheduledCourt]
    let sitOuts: [GameAttendee]
}

struct GeneratedSchedule {
    let rounds: [ScheduledRound]
    let method: ScheduleAllocationMethod
    let courtCount: Int
}

// MARK: - Schedule Engine

enum ScheduleEngine {

    static func generate(
        players: [GameAttendee],
        courtCount: Int,
        roundCount: Int,
        method: ScheduleAllocationMethod
    ) -> GeneratedSchedule {
        guard players.count >= 4, courtCount > 0, roundCount > 0 else {
            return GeneratedSchedule(rounds: [], method: method, courtCount: courtCount)
        }
        let sitOutsPerRound = max(0, players.count - courtCount * 4)
        // Sort players consistently so sit-out rotation is deterministic
        let sorted = players.sorted { $0.userName < $1.userName }

        switch method {
        case .random, .duprBalanced, .duprComp:
            return generateRandom(players: sorted, courtCount: courtCount, roundCount: roundCount, sitPerRound: sitOutsPerRound, method: method)
        case .roundRobin:
            return generateRoundRobin(players: sorted, courtCount: courtCount, roundCount: roundCount, sitPerRound: sitOutsPerRound)
        case .kingOfCourt:
            return generateKingOfCourt(players: sorted, courtCount: courtCount, roundCount: roundCount, sitPerRound: sitOutsPerRound)
        }
    }

    // MARK: Random / DUPR fallback

    private static func generateRandom(
        players: [GameAttendee],
        courtCount: Int,
        roundCount: Int,
        sitPerRound: Int,
        method: ScheduleAllocationMethod
    ) -> GeneratedSchedule {
        var rounds: [ScheduledRound] = []
        for r in 0..<roundCount {
            let (sitOuts, active) = rotatingSitOuts(players: players, round: r, sitPerRound: sitPerRound)
            var shuffled = active
            shuffled.shuffle()
            rounds.append(ScheduledRound(
                number: r + 1,
                courts: buildCourts(from: shuffled, courtCount: courtCount),
                sitOuts: sitOuts
            ))
        }
        return GeneratedSchedule(rounds: rounds, method: method, courtCount: courtCount)
    }

    // MARK: Round Robin — maximise partner/opponent variety

    private static func generateRoundRobin(
        players: [GameAttendee],
        courtCount: Int,
        roundCount: Int,
        sitPerRound: Int
    ) -> GeneratedSchedule {
        var pairCounts = [String: Int]()
        var rounds: [ScheduledRound] = []

        for r in 0..<roundCount {
            let (sitOuts, active) = rotatingSitOuts(players: players, round: r, sitPerRound: sitPerRound)

            // Rotate player order each round so groupings change
            let offset = (r * 2) % max(active.count, 1)
            var rotated = Array(active[offset...] + active[..<offset])

            // Within each group of 4, pick the pairing with fewest repeat partners
            for i in stride(from: 0, to: courtCount * 4, by: 4) {
                guard i + 3 < rotated.count else { break }
                let best = bestPairing(
                    rotated[i], rotated[i+1], rotated[i+2], rotated[i+3],
                    pairCounts: pairCounts
                )
                rotated[i] = best[0]; rotated[i+1] = best[1]
                rotated[i+2] = best[2]; rotated[i+3] = best[3]
            }

            let courts = buildCourts(from: rotated, courtCount: courtCount)
            for court in courts {
                recordPair(court.teamA[0], court.teamA[1], &pairCounts)
                recordPair(court.teamB[0], court.teamB[1], &pairCounts)
            }

            rounds.append(ScheduledRound(number: r + 1, courts: courts, sitOuts: sitOuts))
        }
        return GeneratedSchedule(rounds: rounds, method: .roundRobin, courtCount: courtCount)
    }

    // MARK: King of the Court — Court 1 rotates challengers each round

    private static func generateKingOfCourt(
        players: [GameAttendee],
        courtCount: Int,
        roundCount: Int,
        sitPerRound: Int
    ) -> GeneratedSchedule {
        var rounds: [ScheduledRound] = []

        for r in 0..<roundCount {
            let (sitOuts, active) = rotatingSitOuts(players: players, round: r, sitPerRound: sitPerRound)

            // Rotate who gets Court 1 each round by stepping through player list
            let court1Start = (r * 4) % max(active.count, 1)
            var ordered: [GameAttendee] = []
            for i in 0..<active.count {
                ordered.append(active[(court1Start + i) % active.count])
            }
            // Court 1 = first 4 (the "featured" players this round)
            // Other courts = next players, shuffled
            var others = Array(ordered.dropFirst(4))
            others.shuffle()
            let allActive = Array(ordered.prefix(4)) + others

            rounds.append(ScheduledRound(
                number: r + 1,
                courts: buildCourts(from: allActive, courtCount: courtCount),
                sitOuts: sitOuts
            ))
        }
        return GeneratedSchedule(rounds: rounds, method: .kingOfCourt, courtCount: courtCount)
    }

    // MARK: - Helpers

    /// Rotates sit-outs fairly through the sorted player list each round.
    private static func rotatingSitOuts(
        players: [GameAttendee],
        round: Int,
        sitPerRound: Int
    ) -> (sitOuts: [GameAttendee], active: [GameAttendee]) {
        guard sitPerRound > 0 else { return ([], players) }
        let n = players.count
        var sitOuts: [GameAttendee] = []
        var sitOutIDs = Set<UUID>()
        for i in 0..<sitPerRound {
            let p = players[(round * sitPerRound + i) % n]
            if !sitOutIDs.contains(p.id) {
                sitOuts.append(p)
                sitOutIDs.insert(p.id)
            }
        }
        // Safety: if modular wrapping caused a duplicate, fill from non-sitting players
        if sitOuts.count < sitPerRound {
            for p in players where !sitOutIDs.contains(p.id) {
                sitOuts.append(p)
                sitOutIDs.insert(p.id)
                if sitOuts.count == sitPerRound { break }
            }
        }
        let active = players.filter { !sitOutIDs.contains($0.id) }
        return (sitOuts, active)
    }

    private static func buildCourts(from players: [GameAttendee], courtCount: Int) -> [ScheduledCourt] {
        (0..<courtCount).compactMap { i in
            let s = i * 4
            guard s + 3 < players.count else { return nil }
            return ScheduledCourt(
                number: i + 1,
                teamA: [players[s], players[s + 1]],
                teamB: [players[s + 2], players[s + 3]]
            )
        }
    }

    /// Of the 3 ways to pair 4 players into 2 teams, return the one with fewest repeat pairings.
    private static func bestPairing(
        _ a: GameAttendee, _ b: GameAttendee,
        _ c: GameAttendee, _ d: GameAttendee,
        pairCounts: [String: Int]
    ) -> [GameAttendee] {
        let options: [[GameAttendee]] = [
            [a, b, c, d],
            [a, c, b, d],
            [a, d, b, c],
        ]
        return options.min { x, y in
            pairScore(x[0], x[1], pairCounts) + pairScore(x[2], x[3], pairCounts) <
            pairScore(y[0], y[1], pairCounts) + pairScore(y[2], y[3], pairCounts)
        } ?? options[0]
    }

    private static func pairScore(_ a: GameAttendee, _ b: GameAttendee, _ c: [String: Int]) -> Int {
        c[pairKey(a, b)] ?? 0
    }

    private static func recordPair(_ a: GameAttendee, _ b: GameAttendee, _ c: inout [String: Int]) {
        c[pairKey(a, b), default: 0] += 1
    }

    private static func pairKey(_ a: GameAttendee, _ b: GameAttendee) -> String {
        let ids = [a.id.uuidString, b.id.uuidString].sorted()
        return "\(ids[0])-\(ids[1])"
    }
}

// MARK: - Sheet View

struct GameScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss

    let game: Game
    let confirmedPlayers: [GameAttendee]

    @State private var courts: Int = 2
    @State private var rounds: Int = 3
    @State private var method: ScheduleAllocationMethod = .random
    @State private var schedule: GeneratedSchedule? = nil
    @State private var expandedRounds = Set<UUID>()

    private var maxCourts: Int { max(1, confirmedPlayers.count / 4) }
    private var sitOutsPerRound: Int { max(0, confirmedPlayers.count - courts * 4) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsCard
                    if let schedule {
                        scheduleResults(schedule)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Schedule Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Settings Card

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.headline)
                .foregroundStyle(Brand.ink)

            // Courts + Rounds steppers
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Courts").font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink)
                    PillStepperRow(label: "\(courts)", value: $courts, range: 1...maxCourts, step: 1)
                    Text("Max \(maxCourts) courts")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Rounds").font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink)
                    PillStepperRow(label: "\(rounds)", value: $rounds, range: 1...10, step: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Allocation method chips
            VStack(alignment: .leading, spacing: 8) {
                Text("Allocation Method")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.ink)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScheduleAllocationMethod.allCases) { m in
                            methodChip(m)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text(method.subtitle)
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)

                if method.requiresDUPR {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("DUPR ratings aren't stored per-player yet — will use random allocation.")
                    }
                    .font(.caption)
                    .foregroundStyle(Brand.spicyOrange)
                    .padding(10)
                    .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            // Sit-out info
            if sitOutsPerRound > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.clock")
                        .foregroundStyle(Brand.spicyOrange)
                    Text("\(sitOutsPerRound) player\(sitOutsPerRound == 1 ? "" : "s") will sit out each round, rotating fairly.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.ink)
                }
                .padding(12)
                .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            // Generate button
            Button {
                schedule = ScheduleEngine.generate(
                    players: confirmedPlayers,
                    courtCount: courts,
                    roundCount: rounds,
                    method: method
                )
                expandedRounds = Set(schedule?.rounds.map(\.id) ?? [])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shuffle")
                        .font(.body.weight(.semibold))
                    Text("Generate Schedule")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func methodChip(_ m: ScheduleAllocationMethod) -> some View {
        Button { method = m } label: {
            Text(m.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(method == m ? .white : Brand.slateBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    method == m ? Brand.slateBlue : Brand.slateBlue.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Results

    @ViewBuilder
    private func scheduleResults(_ schedule: GeneratedSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Schedule")
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
                Spacer()
                Text("\(confirmedPlayers.count) players · \(schedule.courtCount) courts · \(schedule.rounds.count) rounds")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }

            ForEach(schedule.rounds) { round in
                roundCard(round)
            }
        }
    }

    private func roundCard(_ round: ScheduledRound) -> some View {
        let isExpanded = expandedRounds.contains(round.id)

        return VStack(alignment: .leading, spacing: 0) {
            // Round header (tap to expand/collapse)
            Button {
                if isExpanded { expandedRounds.remove(round.id) }
                else { expandedRounds.insert(round.id) }
            } label: {
                HStack {
                    Text("Round \(round.number)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    if !round.sitOuts.isEmpty {
                        Text("\(round.sitOuts.count) sitting out")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(round.courts) { court in
                        courtRow(court)
                    }

                    if !round.sitOuts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sitting Out")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.mutedText)
                            HStack(spacing: 8) {
                                ForEach(round.sitOuts) { player in
                                    Text(firstNameOrFull(player.userName))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Brand.spicyOrange)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Brand.spicyOrange.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.slateBlue.opacity(0.12), lineWidth: 1)
        )
    }

    private func courtRow(_ court: ScheduledCourt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Court \(court.number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.pineTeal)
                if court.number == 1 && method == .kingOfCourt {
                    Text("★ Featured")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.spicyOrange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Brand.spicyOrange.opacity(0.1), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                teamPill(court.teamA, color: Brand.slateBlue)
                Text("vs")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.mutedText)
                teamPill(court.teamB, color: Brand.pineTeal)
            }
        }
        .padding(10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func teamPill(_ team: [GameAttendee], color: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(team.enumerated()), id: \.offset) { idx, player in
                if idx > 0 {
                    Text("&").font(.caption2).foregroundStyle(Brand.mutedText)
                }
                Text(firstNameOrFull(player.userName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func firstNameOrFull(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }
}
