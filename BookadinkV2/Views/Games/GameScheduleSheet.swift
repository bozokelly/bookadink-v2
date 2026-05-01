import SwiftUI

// MARK: - Schedule Size Class

enum ScheduleSizeClass {
    case compact   // iPhone portrait (<500pt)
    case regular   // iPad portrait / iPhone landscape (500–900pt)
    case large     // iPad landscape (≥900pt)

    var roundTitleFont: Font {
        switch self {
        case .compact: return .subheadline.weight(.bold)
        case .regular: return .headline.weight(.bold)
        case .large:   return .title2.weight(.bold)
        }
    }

    var courtTitleFont: Font {
        switch self {
        case .compact: return .caption.weight(.bold)
        case .regular: return .subheadline.weight(.bold)
        case .large:   return .title3.weight(.semibold)
        }
    }

    var playerNameFont: Font {
        switch self {
        case .compact: return .caption.weight(.semibold)
        case .regular: return .subheadline.weight(.semibold)
        case .large:   return .title3
        }
    }

    var partnerSeparatorFont: Font {
        switch self {
        case .compact: return .caption2
        case .regular: return .caption
        case .large:   return .body
        }
    }

    var vsFont: Font {
        switch self {
        case .compact: return .caption2.weight(.bold)
        case .regular: return .caption.weight(.bold)
        case .large:   return .body.weight(.medium)
        }
    }

    var scoreFont: Font {
        switch self {
        case .compact: return .caption.weight(.bold)
        case .regular: return .subheadline.weight(.bold)
        case .large:   return .title3.weight(.bold)
        }
    }

    var recordScoreFont: Font {
        switch self {
        case .compact: return .caption.weight(.semibold)
        case .regular: return .caption.weight(.semibold)
        case .large:   return .subheadline.weight(.medium)
        }
    }

    var pillFont: Font {
        switch self {
        case .compact: return .caption.weight(.medium)
        case .regular: return .subheadline.weight(.medium)
        case .large:   return .subheadline.weight(.medium)
        }
    }

    var sitOutCountFont: Font {
        switch self {
        case .compact: return .caption
        case .regular: return .caption
        case .large:   return .subheadline
        }
    }

    var courtCardPadding: CGFloat {
        switch self {
        case .compact, .regular: return 10
        case .large:             return 16
        }
    }

    var courtCardHPadding: CGFloat {
        switch self {
        case .compact, .regular: return 10
        case .large:             return 20
        }
    }

    var courtCardSpacing: CGFloat {
        switch self {
        case .compact, .regular: return 8
        case .large:             return 12
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentY += lineHeight + spacing
                totalHeight = currentY
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Allocation Method

enum ScheduleAllocationMethod: String, CaseIterable, Identifiable, Codable {
    case random             = "Random"
    case duprKingOfCourt    = "DUPR King of the Court"
    case kingOfCourt        = "King of the Court"
    case roundRobin         = "Round Robin"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .random:           return "Shuffle and assign randomly each round"
        case .duprKingOfCourt:  return "DUPR-seeded courts · 3 matches per cycle · top scorer advances, bottom drops"
        case .kingOfCourt:      return "Winners stay, losers rotate — record results between rounds"
        case .roundRobin:       return "Maximise variety of partners and opponents"
        }
    }

    var requiresDUPR: Bool   { self == .duprKingOfCourt }
    var isKingOfCourt: Bool  { self == .kingOfCourt || self == .duprKingOfCourt }
    var isDUPRKotC: Bool     { self == .duprKingOfCourt }
}

// MARK: - Schedule Models

struct ScheduledCourt: Identifiable {
    let id: UUID
    let number: Int
    let teamA: [GameAttendee]
    let teamB: [GameAttendee]

    init(id: UUID = UUID(), number: Int, teamA: [GameAttendee], teamB: [GameAttendee]) {
        self.id = id; self.number = number; self.teamA = teamA; self.teamB = teamB
    }
}

struct ScheduledRound: Identifiable {
    let id: UUID
    let number: Int
    let courts: [ScheduledCourt]
    let sitOuts: [GameAttendee]

    init(id: UUID = UUID(), number: Int, courts: [ScheduledCourt], sitOuts: [GameAttendee]) {
        self.id = id; self.number = number; self.courts = courts; self.sitOuts = sitOuts
    }
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
        method: ScheduleAllocationMethod,
        duprRatings: [UUID: Double] = [:]
    ) -> GeneratedSchedule {
        guard players.count >= 2, courtCount > 0, roundCount > 0 else {
            return GeneratedSchedule(rounds: [], method: method, courtCount: courtCount)
        }
        let playersPerCourt = 4  // doubles only
        let sitOutsPerRound = max(0, players.count - courtCount * playersPerCourt)
        let sorted = players.sorted { $0.userName < $1.userName }

        switch method {
        case .random:
            return generateRandom(players: sorted, courtCount: courtCount, roundCount: roundCount, sitPerRound: sitOutsPerRound)
        case .roundRobin:
            return generateRoundRobin(players: sorted, courtCount: courtCount, roundCount: roundCount, sitPerRound: sitOutsPerRound)
        case .kingOfCourt, .duprKingOfCourt:
            // Both KotC variants only generate round 1 here; subsequent rounds/cycles
            // are produced via kotcNextRound() / DUPRKotCEngine.nextCycle() from the UI layer.
            // In practice handlePrimaryAction() bypasses generate() for these formats —
            // this case is a fallback so the switch is exhaustive.
            let round1 = kotcFirstRound(players: sorted, courtCount: courtCount, sitPerRound: sitOutsPerRound)
            return GeneratedSchedule(rounds: [round1], method: method, courtCount: courtCount)
        }
    }

    // MARK: Random

    private static func generateRandom(
        players: [GameAttendee],
        courtCount: Int,
        roundCount: Int,
        sitPerRound: Int
    ) -> GeneratedSchedule {
        var rounds: [ScheduledRound] = []
        for r in 0..<roundCount {
            let (sitOuts, active) = rotatingSitOuts(players: players, round: r, sitPerRound: sitPerRound)
            var shuffled = active
            shuffled.shuffle()
            rounds.append(ScheduledRound(number: r + 1, courts: buildCourts(from: shuffled, courtCount: courtCount), sitOuts: sitOuts))
        }
        return GeneratedSchedule(rounds: rounds, method: .random, courtCount: courtCount)
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

            let offset = (r * 2) % max(active.count, 1)
            var rotated = Array(active[offset...] + active[..<offset])

            for i in stride(from: 0, to: courtCount * 4, by: 4) {
                guard i + 3 < rotated.count else { break }
                let best = bestPairing(rotated[i], rotated[i+1], rotated[i+2], rotated[i+3], pairCounts: pairCounts)
                rotated[i] = best[0]; rotated[i+1] = best[1]
                rotated[i+2] = best[2]; rotated[i+3] = best[3]
            }

            let courts = buildCourts(from: rotated, courtCount: courtCount)
            for court in courts {
                guard court.teamA.count >= 2, court.teamB.count >= 2 else { continue }
                recordPair(court.teamA[0], court.teamA[1], &pairCounts)
                recordPair(court.teamB[0], court.teamB[1], &pairCounts)
            }

            rounds.append(ScheduledRound(number: r + 1, courts: courts, sitOuts: sitOuts))
        }
        return GeneratedSchedule(rounds: rounds, method: .roundRobin, courtCount: courtCount)
    }

    // MARK: King of the Court — round 1 only

    static func kotcFirstRound(
        players: [GameAttendee],
        courtCount: Int,
        sitPerRound: Int
    ) -> ScheduledRound {
        let (sitOuts, active) = rotatingSitOuts(players: players, round: 0, sitPerRound: sitPerRound)
        var shuffled = active
        shuffled.shuffle()
        return ScheduledRound(number: 1, courts: buildCourts(from: shuffled, courtCount: courtCount), sitOuts: sitOuts)
    }

    /// Generate the next KotC round given confirmed results of the previous round.
    /// Movement rules:
    ///   Court 1 winner → stays Court 1
    ///   Court 1 loser  → goes to Court N
    ///   Court K (K>1) winner → Court K-1
    ///   Court K (K>1) loser  → Court K+1 (or Court N if already at bottom)
    static func kotcNextRound(
        previousRound: ScheduledRound,
        results: [UUID: CourtResult],   // court.id → result
        previousSitOuts: [GameAttendee],
        roundNumber: Int
    ) -> ScheduledRound {
        let courts = previousRound.courts.sorted { $0.number < $1.number }
        let courtCount = courts.count
        let maxCourt = courtCount

        // Determine where each player lands
        var assignments: [Int: [GameAttendee]] = [:]  // courtNumber (1-based) → players assigned

        for court in courts {
            guard let result = results[court.id], result.isConfirmed, let winner = result.winner else {
                // No result — keep everyone where they are
                assignments[court.number, default: []].append(contentsOf: court.teamA + court.teamB)
                continue
            }
            let winners = winner == .teamA ? court.teamA : court.teamB
            let losers  = winner == .teamA ? court.teamB : court.teamA

            if court.number == 1 {
                // Winners stay Court 1, losers drop to Court 2
                assignments[1, default: []].append(contentsOf: winners)
                let loserDest = min(2, maxCourt)
                assignments[loserDest, default: []].append(contentsOf: losers)
            } else {
                // Winners move up, losers move down (capped at maxCourt)
                let winnerCourt = court.number - 1
                let loserCourt = min(court.number + 1, maxCourt)
                assignments[winnerCourt, default: []].append(contentsOf: winners)
                assignments[loserCourt, default: []].append(contentsOf: losers)
            }
        }

        // Rotate sit-outs in to fill any courts that don't have 4 players
        var sitOutPool = previousSitOuts
        var newSitOuts: [GameAttendee] = []

        var orderedCourts: [ScheduledCourt] = []
        for courtNum in 1...max(courtCount, 1) {
            var group = assignments[courtNum] ?? []
            while group.count < 4, !sitOutPool.isEmpty {
                group.append(sitOutPool.removeFirst())
            }
            if group.count >= 4 {
                let shuffled = group.shuffled()
                orderedCourts.append(ScheduledCourt(
                    number: courtNum,
                    teamA: Array(shuffled[0...1]),
                    teamB: Array(shuffled[2...3])
                ))
                newSitOuts.append(contentsOf: Array(group.dropFirst(4)))
            } else {
                newSitOuts.append(contentsOf: group)
            }
        }
        newSitOuts.append(contentsOf: sitOutPool)

        return ScheduledRound(number: roundNumber, courts: orderedCourts, sitOuts: newSitOuts)
    }

    // MARK: - Helpers

    static func rotatingSitOuts(
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
        if sitOuts.count < sitPerRound {
            for p in players where !sitOutIDs.contains(p.id) {
                sitOuts.append(p); sitOutIDs.insert(p.id)
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
            return ScheduledCourt(number: i + 1, teamA: [players[s], players[s+1]], teamB: [players[s+2], players[s+3]])
        }
    }

    private static func bestPairing(
        _ a: GameAttendee, _ b: GameAttendee,
        _ c: GameAttendee, _ d: GameAttendee,
        pairCounts: [String: Int]
    ) -> [GameAttendee] {
        let options: [[GameAttendee]] = [[a,b,c,d],[a,c,b,d],[a,d,b,c]]
        return options.min {
            pairScore($0[0],$0[1],pairCounts) + pairScore($0[2],$0[3],pairCounts) <
            pairScore($1[0],$1[1],pairCounts) + pairScore($1[2],$1[3],pairCounts)
        } ?? options[0]
    }

    private static func pairScore(_ a: GameAttendee, _ b: GameAttendee, _ c: [String: Int]) -> Int { c[pairKey(a,b)] ?? 0 }
    private static func recordPair(_ a: GameAttendee, _ b: GameAttendee, _ c: inout [String: Int]) { c[pairKey(a,b), default: 0] += 1 }
    private static func pairKey(_ a: GameAttendee, _ b: GameAttendee) -> String {
        let ids = [a.id.uuidString, b.id.uuidString].sorted(); return "\(ids[0])-\(ids[1])"
    }
}

// MARK: - DUPR King of the Court Engine

/// Rules engine for the DUPR King of the Court format.
/// Encapsulates: DUPR seeding, 3-match partner rotation, point accumulation,
/// tiebreak ranking, and court movement between cycles.
enum DUPRKotCEngine {

    // ─── Partner rotation ─────────────────────────────────────────────────────
    //
    // Given 4 players ordered [p0, p1, p2, p3] by seed (highest DUPR first),
    // the 3 matches of a cycle ensure every player partners every other player once:
    //
    //   Match 1: p0+p1  vs  p2+p3
    //   Match 2: p0+p2  vs  p1+p3
    //   Match 3: p0+p3  vs  p2+p1
    //
    // Verification:
    //   p0 partners: p1(M1), p2(M2), p3(M3) ✓
    //   p1 partners: p0(M1), p3(M2), p2(M3) ✓
    //   p2 partners: p3(M1), p0(M2), p1(M3) ✓
    //   p3 partners: p2(M1), p1(M2), p0(M3) ✓

    // ─── Public API ───────────────────────────────────────────────────────────

    /// Generate the 3 rounds of the first cycle using DUPR-seeded courts.
    /// Top 4 by DUPR → Court 1, next 4 → Court 2, etc.
    static func firstCycle(
        players: [GameAttendee],
        courtCount: Int,
        duprRatings: [UUID: Double]
    ) -> [ScheduledRound] {
        let (courtGroups, sitOuts) = seedCourts(players: players, courtCount: courtCount, duprRatings: duprRatings)
        return buildCycleRounds(courtGroups: courtGroups, sitOuts: sitOuts, roundNumberStart: 1)
    }

    /// Compute total points per player for one court number across 3 cycle rounds.
    /// Only confirmed results are counted.
    static func pointTotals(
        courtNumber: Int,
        cycleRounds: [ScheduledRound],
        results: [UUID: CourtResult]
    ) -> [UUID: Int] {
        var totals: [UUID: Int] = [:]
        for round in cycleRounds {
            guard let court = round.courts.first(where: { $0.number == courtNumber }),
                  let result = results[court.id],
                  result.isConfirmed else { continue }
            for player in result.teamA { totals[player.booking.userID, default: 0] += result.teamAScore }
            for player in result.teamB { totals[player.booking.userID, default: 0] += result.teamBScore }
        }
        return totals
    }

    /// Compute court movements from the previous 3-round cycle and produce the next 3 rounds.
    ///
    /// Movement rules:
    ///   rank 1 (top scorer)  → moves up one court  (Court 1 rank 1 stays on Court 1)
    ///   rank 4 (last scorer) → moves down one court (bottom court rank 4 stays)
    ///   ranks 2 + 3          → stay on the same court
    ///
    /// Tiebreak: player with lower DUPR wins (receives more favourable placement).
    static func nextCycle(
        previousCycleRounds: [ScheduledRound],
        results: [UUID: CourtResult],
        previousSitOuts: [GameAttendee],
        roundNumberStart: Int,
        duprRatings: [UUID: Double]
    ) -> [ScheduledRound] {
        guard let firstRound = previousCycleRounds.first else { return [] }
        let prevCourts = firstRound.courts.sorted { $0.number < $1.number }
        let courtCount = prevCourts.count
        guard courtCount > 0 else { return [] }

        // Compute player assignments for the next cycle
        var assignments: [Int: [GameAttendee]] = [:]

        for court in prevCourts {
            let players = court.teamA + court.teamB
            let pts = pointTotals(courtNumber: court.number, cycleRounds: previousCycleRounds, results: results)
            let ranked = rankPlayers(players, points: pts, duprRatings: duprRatings)

            guard ranked.count == 4 else {
                // Fallback: no results recorded — keep everyone on the same court
                assignments[court.number, default: []].append(contentsOf: players)
                continue
            }

            let top    = ranked[0]
            let mid1   = ranked[1]
            let mid2   = ranked[2]
            let bottom = ranked[3]

            // Middle two stay
            assignments[court.number, default: []].append(contentsOf: [mid1, mid2])
            // Top moves up; Court 1 winner stays
            let topDest = court.number == 1 ? 1 : court.number - 1
            assignments[topDest, default: []].append(top)
            // Bottom moves down; last court loser stays
            let bottomDest = court.number == courtCount ? courtCount : court.number + 1
            assignments[bottomDest, default: []].append(bottom)
        }

        // Fill courts from assignments, rotating sit-outs back in as needed
        var sitOutPool = previousSitOuts
        var newSitOuts: [GameAttendee] = []
        var courtGroups: [[GameAttendee]] = []

        for courtNum in 1...max(courtCount, 1) {
            var group = assignments[courtNum] ?? []
            while group.count < 4, !sitOutPool.isEmpty {
                group.append(sitOutPool.removeFirst())
            }
            if group.count >= 4 {
                courtGroups.append(Array(group.prefix(4)))
                newSitOuts.append(contentsOf: group.dropFirst(4))
            } else {
                newSitOuts.append(contentsOf: group)
            }
        }
        newSitOuts.append(contentsOf: sitOutPool)

        // Sort each court group by DUPR for the rotation pairing
        let sortedGroups = courtGroups.map { group in
            group.sorted {
                let ra = duprRatings[$0.booking.userID] ?? 0
                let rb = duprRatings[$1.booking.userID] ?? 0
                return ra > rb
            }
        }

        return buildCycleRounds(courtGroups: sortedGroups, sitOuts: newSitOuts, roundNumberStart: roundNumberStart)
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// Sort players by DUPR descending; unrated players sorted alphabetically at the end.
    /// Group adjacent blocks of 4: top 4 → index 0, next 4 → index 1, etc.
    private static func seedCourts(
        players: [GameAttendee],
        courtCount: Int,
        duprRatings: [UUID: Double]
    ) -> (courts: [[GameAttendee]], sitOuts: [GameAttendee]) {
        let sorted = players.sorted { a, b in
            let ra = duprRatings[a.booking.userID]
            let rb = duprRatings[b.booking.userID]
            if let ra, let rb { return ra > rb }
            if ra != nil { return true }
            if rb != nil { return false }
            return a.userName < b.userName
        }
        var courtGroups: [[GameAttendee]] = []
        for i in 0..<courtCount {
            let start = i * 4
            guard start + 3 < sorted.count else { break }
            courtGroups.append(Array(sorted[start...start + 3]))
        }
        let usedCount = courtGroups.count * 4
        let sitOuts = usedCount < sorted.count ? Array(sorted[usedCount...]) : []
        return (courtGroups, sitOuts)
    }

    /// Rank 4 players by total points descending.
    /// Tiebreak: lower DUPR rating → more favourable (higher) placement.
    private static func rankPlayers(
        _ players: [GameAttendee],
        points: [UUID: Int],
        duprRatings: [UUID: Double]
    ) -> [GameAttendee] {
        players.sorted { a, b in
            let pa = points[a.booking.userID] ?? 0
            let pb = points[b.booking.userID] ?? 0
            if pa != pb { return pa > pb }
            // Tied: lower DUPR wins (more favourable placement)
            let ra = duprRatings[a.booking.userID] ?? 0
            let rb = duprRatings[b.booking.userID] ?? 0
            return ra < rb
        }
    }

    /// Given pre-grouped court assignments (each group = exactly 4 players ordered by DUPR),
    /// produce the 3 rounds of a cycle using the fixed partner rotation.
    /// Sit-outs are on round 1 only (same 4 players play all 3 rounds of a cycle).
    private static func buildCycleRounds(
        courtGroups: [[GameAttendee]],
        sitOuts: [GameAttendee],
        roundNumberStart: Int
    ) -> [ScheduledRound] {
        var r1Courts: [ScheduledCourt] = []
        var r2Courts: [ScheduledCourt] = []
        var r3Courts: [ScheduledCourt] = []

        for (idx, group) in courtGroups.enumerated() {
            guard group.count == 4 else { continue }
            let n = idx + 1
            let p = group
            // Fixed rotation: everyone partners everyone else exactly once
            r1Courts.append(ScheduledCourt(number: n, teamA: [p[0], p[1]], teamB: [p[2], p[3]]))
            r2Courts.append(ScheduledCourt(number: n, teamA: [p[0], p[2]], teamB: [p[1], p[3]]))
            r3Courts.append(ScheduledCourt(number: n, teamA: [p[0], p[3]], teamB: [p[2], p[1]]))
        }

        return [
            ScheduledRound(number: roundNumberStart,     courts: r1Courts, sitOuts: sitOuts),
            ScheduledRound(number: roundNumberStart + 1, courts: r2Courts, sitOuts: []),
            ScheduledRound(number: roundNumberStart + 2, courts: r3Courts, sitOuts: [])
        ]
    }
}

// MARK: - Session Results Formatter

struct SessionResultsFormatter {
    static func format(
        game: Game,
        rounds: [ScheduledRound],
        results: [UUID: CourtResult],
        method: ScheduleAllocationMethod,
        winCondition: WinCondition
    ) -> String {
        let dateStr = game.dateTime.formatted(date: .abbreviated, time: .shortened)
        let formatStr = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
        let courtCount = rounds.first?.courts.count ?? game.courtCount
        var lines: [String] = [
            "🏓 Session Results — \(game.title)",
            "📅 \(dateStr) · \(formatStr) · \(courtCount) court\(courtCount == 1 ? "" : "s")",
            ""
        ]

        let maxRoundsToShow = 4
        let displayRounds = Array(rounds.prefix(maxRoundsToShow))

        for round in displayRounds {
            let roundResults  = round.courts.compactMap { results[$0.id] }
            let allConfirmed  = roundResults.count == round.courts.count && roundResults.allSatisfy(\.isConfirmed)
            let multiCourt    = round.courts.count > 1

            lines.append("Round \(round.number)\(allConfirmed ? "" : " (incomplete)")")
            for court in round.courts.sorted(by: { $0.number < $1.number }) {
                let courtPrefix = multiCourt ? "  Court \(court.number):  " : "  "
                if let result = results[court.id], result.isConfirmed {
                    // Winner row first; fall back to higher-score-first when no winner
                    let teamAWon = result.winner == .teamA
                    let teamBWon = result.winner == .teamB
                    let topIsA   = teamAWon || (!teamBWon && result.teamAScore >= result.teamBScore)
                    let winNames  = (topIsA ? result.teamA : result.teamB).map { shortName($0.userName) }.joined(separator: " & ")
                    let losNames  = (topIsA ? result.teamB : result.teamA).map { shortName($0.userName) }.joined(separator: " & ")
                    let winScore  = topIsA ? result.teamAScore : result.teamBScore
                    let losScore  = topIsA ? result.teamBScore : result.teamAScore
                    let hasWinner = teamAWon || teamBWon
                    let mark      = hasWinner ? " ✅" : ""
                    lines.append("\(courtPrefix)\(winNames)\(mark)  \(winScore) – \(losScore)  \(losNames)")
                } else {
                    let teamANames = court.teamA.map { shortName($0.userName) }.joined(separator: " & ")
                    let teamBNames = court.teamB.map { shortName($0.userName) }.joined(separator: " & ")
                    lines.append("\(courtPrefix)\(teamANames)  vs  \(teamBNames)")
                }
            }
            lines.append("")
        }

        if rounds.count > maxRoundsToShow {
            lines.append("[+ \(rounds.count - maxRoundsToShow) more rounds]")
            lines.append("")
        }

        // King of the Court champion: winner of the final confirmed round on court 1
        if method == .kingOfCourt {
            let lastConfirmedRound = rounds.last(where: { round in
                round.courts.allSatisfy { results[$0.id]?.isConfirmed == true }
            })
            if let finalRound = lastConfirmedRound,
               let court1 = finalRound.courts.first(where: { $0.number == 1 }),
               let result = results[court1.id],
               let winner = result.winner {
                let champions = (winner == .teamA ? result.teamA : result.teamB).map { shortName($0.userName) }.joined(separator: " & ")
                lines.append("🏆 King of the Court — Final Champion: \(champions)")
            }
        }

        // DUPR KotC champion: player with the highest total points on Court 1
        // across the last fully-confirmed 3-round cycle.
        if method == .duprKingOfCourt, rounds.count >= 3 {
            // Walk backwards to find the last complete cycle (groups of 3)
            let completeCycles = (rounds.count / 3)
            if completeCycles > 0 {
                let lastCycleStart = (completeCycles - 1) * 3
                let lastCycleRounds = Array(rounds[lastCycleStart ..< lastCycleStart + 3])
                let allConfirmed = lastCycleRounds.allSatisfy { r in
                    r.courts.allSatisfy { results[$0.id]?.isConfirmed == true }
                }
                if allConfirmed {
                    let pts = DUPRKotCEngine.pointTotals(courtNumber: 1, cycleRounds: lastCycleRounds, results: results)
                    let court1Players = (lastCycleRounds.first?.courts.first(where: { $0.number == 1 })).map { $0.teamA + $0.teamB } ?? []
                    if let champion = court1Players.max(by: { pts[$0.booking.userID] ?? 0 < pts[$1.booking.userID] ?? 0 }) {
                        let pts_val = pts[champion.booking.userID] ?? 0
                        lines.append("🏆 DUPR King of the Court — Champion: \(shortName(champion.userName)) (\(pts_val) pts)")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func shortName(_ fullName: String) -> String {
        let parts = fullName.components(separatedBy: " ")
        guard parts.count >= 2, let first = parts.first, let lastInitial = parts.last?.first else {
            return fullName
        }
        return "\(first) \(lastInitial)."
    }
}

// MARK: - Session Result Normalizer

/// Converts raw session data into a `SessionResultPayload` for JSON encoding
/// and storage as a structured club chat post.
private struct SessionResultNormalizer {

    static func normalize(
        game: Game,
        rounds: [ScheduledRound],
        results: [UUID: CourtResult],
        method: ScheduleAllocationMethod
    ) -> SessionResultPayload {
        let date    = game.dateTime.formatted(.dateTime.month(.abbreviated).day())
        let time    = game.dateTime.formatted(.dateTime.hour().minute())
        let fmt     = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
        let courts  = rounds.first?.courts.count ?? game.courtCount
        let subtitle = "\(date) · \(time) · \(fmt) · \(courts) court\(courts == 1 ? "" : "s")"

        let srRounds: [SessionResultPayload.SRRound] = rounds.map { round in
            let showLabel = round.courts.count > 1
            let srCourts: [SessionResultPayload.SRCourt] = round.courts
                .sorted(by: { $0.number < $1.number })
                .map { court in
                    guard let r = results[court.id], r.isConfirmed else {
                        return SessionResultPayload.SRCourt(courtNumber: court.number, showLabel: showLabel, result: nil)
                    }
                    let teamAWon = r.winner == .teamA
                    let teamBWon = r.winner == .teamB
                    let topIsA   = teamAWon || (!teamBWon && r.teamAScore >= r.teamBScore)
                    let match = SessionResultPayload.SRMatch(
                        topNames:       teamLabel(topIsA ? r.teamA : r.teamB),
                        topScore:       topIsA ? r.teamAScore : r.teamBScore,
                        topIsWinner:    topIsA ? teamAWon : teamBWon,
                        bottomNames:    teamLabel(topIsA ? r.teamB : r.teamA),
                        bottomScore:    topIsA ? r.teamBScore : r.teamAScore,
                        bottomIsWinner: topIsA ? teamBWon : teamAWon
                    )
                    return SessionResultPayload.SRCourt(courtNumber: court.number, showLabel: showLabel, result: match)
                }
            return SessionResultPayload.SRRound(number: round.number, courts: srCourts)
        }

        let (champion, championLabel) = resolveChampion(method: method, rounds: rounds, results: results)

        return SessionResultPayload(
            gameTitle: game.title,
            subtitle: subtitle,
            rounds: srRounds,
            champion: champion,
            championLabel: championLabel
        )
    }

    private static func teamLabel(_ attendees: [GameAttendee]) -> String {
        attendees.map { shortName($0.userName) }.joined(separator: " & ")
    }

    private static func shortName(_ full: String) -> String {
        let parts = full.components(separatedBy: " ")
        guard parts.count >= 2, let first = parts.first, let lastInitial = parts.last?.first else { return full }
        return "\(first) \(lastInitial)."
    }

    private static func resolveChampion(
        method: ScheduleAllocationMethod,
        rounds: [ScheduledRound],
        results: [UUID: CourtResult]
    ) -> (String?, String?) {
        if method == .kingOfCourt {
            let lastFull = rounds.last { $0.courts.allSatisfy { results[$0.id]?.isConfirmed == true } }
            guard let finalRound = lastFull,
                  let court1 = finalRound.courts.first(where: { $0.number == 1 }),
                  let r = results[court1.id],
                  let winner = r.winner else { return (nil, nil) }
            let name = (winner == .teamA ? r.teamA : r.teamB).map { shortName($0.userName) }.joined(separator: " & ")
            return (name, "King of the Court")
        }
        if method == .duprKingOfCourt, rounds.count >= 3 {
            let completeCycles = rounds.count / 3
            guard completeCycles > 0 else { return (nil, nil) }
            let cycleStart = (completeCycles - 1) * 3
            let cycleRounds = Array(rounds[cycleStart ..< cycleStart + 3])
            guard cycleRounds.allSatisfy({ r in r.courts.allSatisfy { results[$0.id]?.isConfirmed == true } }) else { return (nil, nil) }
            let pts = DUPRKotCEngine.pointTotals(courtNumber: 1, cycleRounds: cycleRounds, results: results)
            let court1Players = cycleRounds.first?.courts.first(where: { $0.number == 1 }).map { $0.teamA + $0.teamB } ?? []
            guard let champ = court1Players.max(by: { pts[$0.booking.userID] ?? 0 < pts[$1.booking.userID] ?? 0 }) else { return (nil, nil) }
            let ptsVal = pts[champ.booking.userID] ?? 0
            return ("\(shortName(champ.userName)) (\(ptsVal) pts)", "DUPR King of the Court")
        }
        return (nil, nil)
    }
}

// MARK: - Session Results Image Renderer

/// Renders a match-results card to a `UIImage` using SwiftUI's `ImageRenderer`.
/// Must be invoked on the main actor (ImageRenderer requirement, iOS 16+).
private struct SessionResultsImageRenderer {
    static let cardWidth: CGFloat = 360

    @MainActor
    static func render(
        game: Game,
        rounds: [ScheduledRound],
        results: [UUID: CourtResult],
        method: ScheduleAllocationMethod
    ) -> UIImage? {
        let view = ResultsCardView(game: game, rounds: rounds, results: results, method: method)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0   // @2x — crisp on all current iPhones
        return renderer.uiImage
    }
}

// MARK: - Results Card View V2 (image only, not presented in the app UI)

/// SwiftUI view rendered into a PNG via ImageRenderer.
/// Uses literal colours — always light-mode regardless of device setting.
private struct ResultsCardView: View {
    let game: Game
    let rounds: [ScheduledRound]
    let results: [UUID: CourtResult]
    let method: ScheduleAllocationMethod

    // ── Palette ──────────────────────────────────────────────────────
    // All literals so the card is immune to system theme changes.
    private static let bgColor       = Color(red: 0.953, green: 0.953, blue: 0.953) // #F3F3F3
    private static let inkColor      = Color(red: 0.067, green: 0.067, blue: 0.067) // #111111
    private static let subColor      = Color(red: 0.350, green: 0.350, blue: 0.350) // #595959 — loser names
    private static let mutedColor    = Color(red: 0.530, green: 0.530, blue: 0.530) // #878787 — labels / metadata
    private static let divColor      = Color(red: 0.820, green: 0.820, blue: 0.820) // #D1D1D1
    private static let champBg       = Color(red: 0.922, green: 0.922, blue: 0.922) // #EBEBEB — subtle tint

    // ── Helpers ───────────────────────────────────────────────────────

    private var headerSubtitle: String {
        let date   = game.dateTime.formatted(.dateTime.month(.abbreviated).day())
        let time   = game.dateTime.formatted(.dateTime.hour().minute())
        let fmt    = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
        let courts = rounds.first?.courts.count ?? game.courtCount
        return "\(date) · \(time) · \(fmt) · \(courts) court\(courts == 1 ? "" : "s")"
    }

    private func shortName(_ full: String) -> String {
        let parts = full.components(separatedBy: " ")
        guard parts.count >= 2,
              let first = parts.first,
              let lastInitial = parts.last?.first else { return full }
        return "\(first) \(lastInitial)."
    }

    private func teamLabel(_ attendees: [GameAttendee]) -> String {
        attendees.map { shortName($0.userName) }.joined(separator: " & ")
    }

    private var kotcChampion: String? {
        if method == .kingOfCourt {
            let lastFull = rounds.last {
                $0.courts.allSatisfy { results[$0.id]?.isConfirmed == true }
            }
            guard let finalRound = lastFull,
                  let court1 = finalRound.courts.first(where: { $0.number == 1 }),
                  let result = results[court1.id],
                  let winner = result.winner else { return nil }
            return (winner == .teamA ? result.teamA : result.teamB)
                .map { shortName($0.userName) }
                .joined(separator: " & ")
        } else if method == .duprKingOfCourt, rounds.count >= 3 {
            let completeCycles = rounds.count / 3
            guard completeCycles > 0 else { return nil }
            let cycleStart = (completeCycles - 1) * 3
            let cycleRounds = Array(rounds[cycleStart ..< cycleStart + 3])
            guard cycleRounds.allSatisfy({ r in
                r.courts.allSatisfy { results[$0.id]?.isConfirmed == true }
            }) else { return nil }
            // Find champion as player with highest total points on Court 1
            let pts = DUPRKotCEngine.pointTotals(courtNumber: 1, cycleRounds: cycleRounds, results: results)
            let court1Players = cycleRounds.first?.courts.first(where: { $0.number == 1 }).map { $0.teamA + $0.teamB } ?? []
            guard let champ = court1Players.max(by: { pts[$0.booking.userID] ?? 0 < pts[$1.booking.userID] ?? 0 }) else { return nil }
            let ptsVal = pts[champ.booking.userID] ?? 0
            return "\(shortName(champ.userName)) (\(ptsVal) pts)"
        }
        return nil
    }

    // ── Body ──────────────────────────────────────────────────────────

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider.padding(.bottom, 18)
            rounds_section
            if let champ = kotcChampion {
                champion(champ)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .frame(width: SessionResultsImageRenderer.cardWidth, alignment: .leading)
        .background(Self.bgColor)
        .preferredColorScheme(.light)
    }

    // ── Header ────────────────────────────────────────────────────────

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Eyebrow — light, small, recedes visually
            HStack(spacing: 5) {
                Text("🏓")
                    .font(.system(size: 13))
                Text("Session Results")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Self.mutedColor)
            }
            .padding(.bottom, 6)

            // Title — focal point of the header
            Text(game.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Self.inkColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            // Metadata — date · time · format · courts
            Text(headerSubtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Self.mutedColor)
        }
        .padding(.bottom, 18)
    }

    // ── Divider ───────────────────────────────────────────────────────

    private var divider: some View {
        Rectangle()
            .fill(Self.divColor)
            .frame(height: 1)
    }

    // ── Rounds ────────────────────────────────────────────────────────

    private var rounds_section: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(rounds)) { round in
                roundSection(round)
            }
        }
    }

    @ViewBuilder
    private func roundSection(_ round: ScheduledRound) -> some View {
        // Court label is useful only when multiple courts run concurrently.
        let showCourtLabel = round.courts.count > 1
        VStack(alignment: .leading, spacing: 10) {
            // Round header — slightly more presence than court labels
            Text("Round \(round.number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Self.mutedColor)
                .tracking(0.3)

            // Courts — tighter grouping within each court, more gap between courts
            VStack(alignment: .leading, spacing: 12) {
                ForEach(round.courts.sorted(by: { $0.number < $1.number })) { court in
                    courtBlock(court: court, showCourtLabel: showCourtLabel)
                }
            }
        }
    }

    // ── Court block ───────────────────────────────────────────────────

    @ViewBuilder
    private func courtBlock(court: ScheduledCourt, showCourtLabel: Bool) -> some View {
        let result    = results[court.id]
        let confirmed = result?.isConfirmed == true

        VStack(alignment: .leading, spacing: 0) {
            // Court label — only when multiple courts run concurrently
            if showCourtLabel {
                Text("COURT \(court.number)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Self.mutedColor)
                    .tracking(0.8)
                    .padding(.bottom, 4)
            }

            if let r = result, confirmed {
                confirmedMatchRows(r)
            } else {
                pendingMatchRows(court: court)
            }
        }
    }

    // Winner row always on top. When there is no winner (tie/incomplete),
    // the higher-score team sits on top; both rows render in neutral style.
    @ViewBuilder
    private func confirmedMatchRows(_ r: CourtResult) -> some View {
        let teamAWon = r.winner == .teamA
        let teamBWon = r.winner == .teamB
        let topIsA   = teamAWon || (!teamBWon && r.teamAScore >= r.teamBScore)
        matchRow(
            names:    teamLabel(topIsA ? r.teamA : r.teamB),
            score:    topIsA ? r.teamAScore : r.teamBScore,
            isWinner: topIsA ? teamAWon : teamBWon
        )
        .padding(.bottom, 2)
        matchRow(
            names:    teamLabel(topIsA ? r.teamB : r.teamA),
            score:    topIsA ? r.teamBScore : r.teamAScore,
            isWinner: topIsA ? teamBWon : teamAWon
        )
    }

    @ViewBuilder
    private func pendingMatchRows(court: ScheduledCourt) -> some View {
        // Teams assigned but score not yet entered — both neutral
        Text(teamLabel(court.teamA))
            .font(.system(size: 13))
            .foregroundColor(Self.mutedColor)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
        Text(teamLabel(court.teamB))
            .font(.system(size: 13))
            .foregroundColor(Self.mutedColor)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // ── Match row ─────────────────────────────────────────────────────
    // Name fills available width; score + ✅ occupy a fixed 60 pt column
    // so numbers always right-align on the same vertical axis.

    private func matchRow(names: String, score: Int, isWinner: Bool) -> some View {
        HStack(spacing: 0) {
            // Name — semibold/ink for winner, regular/subColor for loser
            Text(names)
                .font(.system(size: 14, weight: isWinner ? .semibold : .regular))
                .foregroundColor(isWinner ? Self.inkColor : Self.subColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Score column: [number 28pt] [✅ slot 24pt] = 52pt total
            // The empty ✅ slot is a zero-width spacer so losers still align.
            HStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 14, weight: isWinner ? .bold : .regular))
                    .foregroundColor(isWinner ? Self.inkColor : Self.subColor)
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
                // Reserve identical width for both winner mark and empty slot
                if isWinner {
                    Text("✅")
                        .font(.system(size: 12))
                        .frame(width: 26, alignment: .center)
                } else {
                    Spacer().frame(width: 26)
                }
            }
            .frame(width: 54, alignment: .trailing)
        }
    }

    // ── Champion section ──────────────────────────────────────────────

    private func champion(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            divider
                .padding(.top, 22)
                .padding(.bottom, 16)

            // Slightly elevated block — subtle background tint, generous inset
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("🏆")
                        .font(.system(size: 15))
                    Text("King of the Court")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Self.mutedColor)
                        .tracking(0.2)
                }
                Text(name)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(Self.inkColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.champBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - Session Persistence

enum SessionStatus: String, Codable { case active, completed }

struct PersistedPlayerRef: Codable {
    let bookingID: UUID
    let userID: UUID
    let userName: String
}

struct PersistedCourt: Codable {
    let id: UUID
    let number: Int
    let teamA: [PersistedPlayerRef]
    let teamB: [PersistedPlayerRef]
}

struct PersistedRound: Codable {
    let id: UUID
    let number: Int
    let courts: [PersistedCourt]
    let sitOuts: [PersistedPlayerRef]
}

struct PersistedCourtResult: Codable {
    let id: UUID
    let roundNumber: Int
    let courtNumber: Int
    let courtID: UUID
    let teamA: [PersistedPlayerRef]
    let teamB: [PersistedPlayerRef]
    let teamAScore: Int
    let teamBScore: Int
    let winner: TeamSide?
    let isConfirmed: Bool
}

struct LiveGameSession: Codable {
    let gameID: UUID
    let method: ScheduleAllocationMethod
    let courts: Int
    let roundCount: Int
    let status: SessionStatus
    let isKotC: Bool
    let persistedRounds: [PersistedRound]
    let courtResults: [String: PersistedCourtResult]
    let savedAt: Date
}

enum ScheduleSessionManager {
    private static let key = "bookadink.live.sessions"

    static func save(_ session: LiveGameSession) {
        var all = loadAll()
        all[session.gameID.uuidString] = session
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load(gameID: UUID) -> LiveGameSession? {
        loadAll()[gameID.uuidString]
    }

    static func clear(gameID: UUID) {
        var all = loadAll()
        all.removeValue(forKey: gameID.uuidString)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadAll() -> [String: LiveGameSession] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: LiveGameSession].self, from: data)
        else { return [:] }
        return decoded
    }
}

// MARK: - Sheet View

struct GameScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let game: Game
    let confirmedPlayers: [GameAttendee]

    @State private var courts: Int
    @State private var rounds: Int = 3
    @State private var method: ScheduleAllocationMethod = .random
    @State private var schedule: GeneratedSchedule? = nil
    @State private var expandedRounds = Set<UUID>()

    // Score tracking: court.id → CourtResult
    @State private var courtResults: [UUID: CourtResult] = [:]
    // KotC: accumulate all rounds as they're generated
    @State private var kotcRounds: [ScheduledRound] = []
    // Score entry sheet
    @State private var scoringCourt: (round: ScheduledRound, court: ScheduledCourt)? = nil
    // Post results
    @State private var isShowingPostConfirm = false
    @State private var postAsAnnouncement = false
    @State private var isPosting = false
    @State private var postSucceeded = false
    @State private var resultShareImage: UIImage? = nil
    @State private var settingsExpanded = true
    @State private var scrollTarget: UUID? = nil
    @State private var pendingResumeSession: LiveGameSession? = nil
    @State private var showResumePrompt = false

    private var hasActiveSession: Bool { !activeRounds.isEmpty }

    init(game: Game, confirmedPlayers: [GameAttendee]) {
        self.game = game
        self.confirmedPlayers = confirmedPlayers
        _courts = State(initialValue: max(1, game.courtCount))
    }

    private var sizeClass: ScheduleSizeClass {
        let width = UIScreen.main.bounds.width
        if width >= 900 { return .large }
        if width >= 500 { return .regular }
        return .compact
    }

    private func makeShareTaskID() -> String {
        "\(game.id):\(activeRounds.count):\(courtResults.values.filter(\.isConfirmed).count)"
    }

    private var winCondition: WinCondition {
        appState.clubs.first(where: { $0.id == game.clubID })?.winCondition ?? .firstTo11By2
    }

    private var clubForGame: Club? {
        appState.clubs.first(where: { $0.id == game.clubID })
    }

    private var maxCourts: Int { max(1, confirmedPlayers.count / 4) }
    private var sitOutsPerRound: Int { max(0, confirmedPlayers.count - courts * 4) }

    private var duprRatings: [UUID: Double] {
        var map: [UUID: Double] = [:]
        for player in confirmedPlayers {
            // Prefer the rating embedded in the attendee record (fetched from DB),
            // fall back to the AppState in-memory cache (covers the current user
            // and any admin-updated ratings not yet re-fetched as attendees).
            if let rating = player.duprRating ?? appState.duprDoublesRating(for: player.booking.userID) {
                map[player.booking.userID] = rating
            }
        }
        return map
    }

    private var hasDUPRData: Bool { !duprRatings.isEmpty }

    // Active rounds to display (both KotC variants use kotcRounds, others use schedule.rounds)
    private var activeRounds: [ScheduledRound] {
        if method.isKingOfCourt { return kotcRounds }
        return schedule?.rounds ?? []
    }

    // Standard KotC: can generate next round when all courts in the last round have confirmed results
    private var kotcCanGenerateNextRound: Bool {
        guard method == .kingOfCourt, let lastRound = kotcRounds.last else { return false }
        return lastRound.courts.allSatisfy { courtResults[$0.id]?.isConfirmed == true }
    }

    // DUPR KotC: can generate next cycle when all 3 rounds of the current cycle are fully confirmed
    private var duprKotcCanGenerateNextCycle: Bool {
        guard method == .duprKingOfCourt, !kotcRounds.isEmpty, kotcRounds.count % 3 == 0 else { return false }
        return kotcRounds.suffix(3).allSatisfy { round in
            round.courts.allSatisfy { courtResults[$0.id]?.isConfirmed == true }
        }
    }

    private var allResults: [CourtResult] { Array(courtResults.values) }

    /// The ID of the round that should be expanded and scrolled to.
    /// For KotC: the latest round. For fixed schedules: the first round
    /// that still has incomplete results, falling back to the last round.
    private var currentRoundID: UUID? {
        if method.isKingOfCourt { return kotcRounds.last?.id }
        guard let rounds = schedule?.rounds, !rounds.isEmpty else { return nil }
        return rounds.first(where: { round in
            !round.courts.allSatisfy { courtResults[$0.id]?.isConfirmed == true }
        })?.id ?? rounds.last?.id
    }

    // MARK: - Session Persistence Helpers

    private func persistPlayer(_ a: GameAttendee) -> PersistedPlayerRef {
        PersistedPlayerRef(bookingID: a.booking.id, userID: a.booking.userID, userName: a.userName)
    }

    private func persistCourt(_ c: ScheduledCourt) -> PersistedCourt {
        PersistedCourt(id: c.id, number: c.number, teamA: c.teamA.map(persistPlayer), teamB: c.teamB.map(persistPlayer))
    }

    private func persistRound(_ r: ScheduledRound) -> PersistedRound {
        PersistedRound(id: r.id, number: r.number, courts: r.courts.map(persistCourt), sitOuts: r.sitOuts.map(persistPlayer))
    }

    private func restorePlayer(_ ref: PersistedPlayerRef) -> GameAttendee? {
        confirmedPlayers.first(where: { $0.booking.id == ref.bookingID })
            ?? confirmedPlayers.first(where: { $0.booking.userID == ref.userID })
    }

    private func restoreCourt(_ c: PersistedCourt) -> ScheduledCourt? {
        let teamA = c.teamA.compactMap(restorePlayer)
        let teamB = c.teamB.compactMap(restorePlayer)
        guard teamA.count == c.teamA.count, teamB.count == c.teamB.count else { return nil }
        return ScheduledCourt(id: c.id, number: c.number, teamA: teamA, teamB: teamB)
    }

    private func restoreRound(_ r: PersistedRound) -> ScheduledRound? {
        let courts = r.courts.compactMap(restoreCourt)
        let sitOuts = r.sitOuts.compactMap(restorePlayer)
        guard courts.count == r.courts.count else { return nil }
        return ScheduledRound(id: r.id, number: r.number, courts: courts, sitOuts: sitOuts)
    }

    private func restoreResult(_ pr: PersistedCourtResult) -> CourtResult? {
        let teamA = pr.teamA.compactMap(restorePlayer)
        let teamB = pr.teamB.compactMap(restorePlayer)
        return CourtResult(
            id: pr.id, roundNumber: pr.roundNumber, courtNumber: pr.courtNumber, courtID: pr.courtID,
            teamA: teamA, teamB: teamB,
            teamAScore: pr.teamAScore, teamBScore: pr.teamBScore,
            winner: pr.winner, isConfirmed: pr.isConfirmed
        )
    }

    private func saveSession() {
        guard hasActiveSession else { return }
        let pRounds = activeRounds.map(persistRound)
        let pResults = courtResults.reduce(into: [String: PersistedCourtResult]()) { acc, kv in
            let r = kv.value
            acc[kv.key.uuidString] = PersistedCourtResult(
                id: r.id, roundNumber: r.roundNumber, courtNumber: r.courtNumber, courtID: r.courtID,
                teamA: r.teamA.map(persistPlayer), teamB: r.teamB.map(persistPlayer),
                teamAScore: r.teamAScore, teamBScore: r.teamBScore,
                winner: r.winner, isConfirmed: r.isConfirmed
            )
        }
        let session = LiveGameSession(
            gameID: game.id, method: method, courts: courts, roundCount: rounds,
            status: .active, isKotC: method.isKingOfCourt,
            persistedRounds: pRounds, courtResults: pResults, savedAt: Date()
        )
        ScheduleSessionManager.save(session)
    }

    private func applyRestoredSession(_ session: LiveGameSession) {
        method = session.method
        courts = session.courts
        let restoredRounds = session.persistedRounds.compactMap(restoreRound)
        let restoredResults = session.courtResults.reduce(into: [UUID: CourtResult]()) { acc, kv in
            guard let uuid = UUID(uuidString: kv.key), let result = restoreResult(kv.value) else { return }
            acc[uuid] = result
        }
        if session.isKotC {
            kotcRounds = restoredRounds
        } else {
            schedule = GeneratedSchedule(rounds: restoredRounds, method: session.method, courtCount: session.courts)
        }
        courtResults = restoredResults
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { settingsExpanded = false }
        // Expand and scroll to the current (first incomplete) round
        if let id = currentRoundID {
            expandedRounds = [id]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scrollTarget = id }
        }
    }

    // MARK: - Primary Action (navbar button)

    private var showPrimaryAction: Bool {
        settingsExpanded || method.isKingOfCourt
    }

    private var primaryActionLabel: String {
        if settingsExpanded { return "Start Session" }
        return method.isDUPRKotC ? "Next Cycle" : "Next Round"
    }

    private var primaryActionEnabled: Bool {
        settingsExpanded || kotcCanGenerateNextRound || duprKotcCanGenerateNextCycle
    }

    private func handlePrimaryAction() {
        if settingsExpanded {
            // ── Generate / Start ────────────────────────────────────────────
            if method == .kingOfCourt {
                kotcRounds = []
                courtResults = [:]
                let round1 = ScheduleEngine.kotcFirstRound(
                    players: confirmedPlayers.sorted { $0.userName < $1.userName },
                    courtCount: courts,
                    sitPerRound: sitOutsPerRound
                )
                kotcRounds = [round1]
                expandedRounds = [round1.id]
            } else if method == .duprKingOfCourt {
                kotcRounds = []
                courtResults = [:]
                let firstCycle = DUPRKotCEngine.firstCycle(
                    players: confirmedPlayers.sorted { $0.userName < $1.userName },
                    courtCount: courts,
                    duprRatings: duprRatings
                )
                kotcRounds = firstCycle
                expandedRounds = firstCycle.first.map { [$0.id] } ?? []
            } else {
                schedule = ScheduleEngine.generate(
                    players: confirmedPlayers,
                    courtCount: courts,
                    roundCount: rounds,
                    method: method,
                    duprRatings: duprRatings
                )
                if let firstRound = schedule?.rounds.first {
                    expandedRounds = [firstRound.id]
                }
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                settingsExpanded = false
            }
            saveSession()
        } else if method == .kingOfCourt {
            // ── KotC: Generate Next Round ────────────────────────────────────
            guard let lastRound = kotcRounds.last else { return }
            let lastRoundID = lastRound.id
            withAnimation(.easeInOut(duration: 0.25)) {
                expandedRounds.remove(lastRoundID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let nextRound = ScheduleEngine.kotcNextRound(
                    previousRound: lastRound,
                    results: courtResults,
                    previousSitOuts: lastRound.sitOuts,
                    roundNumber: lastRound.number + 1
                )
                kotcRounds.append(nextRound)
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedRounds.insert(nextRound.id)
                }
                scrollTarget = nextRound.id
                saveSession()
            }
        } else if method == .duprKingOfCourt {
            // ── DUPR KotC: Generate Next Cycle (3 rounds) ───────────────────
            guard duprKotcCanGenerateNextCycle else { return }
            let lastCycleRounds = Array(kotcRounds.suffix(3))
            let sitOuts = lastCycleRounds.first?.sitOuts ?? []
            let roundStart = kotcRounds.count + 1
            // Collapse the completed cycle rounds
            withAnimation(.easeInOut(duration: 0.25)) {
                for r in lastCycleRounds { expandedRounds.remove(r.id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let nextCycle = DUPRKotCEngine.nextCycle(
                    previousCycleRounds: lastCycleRounds,
                    results: courtResults,
                    previousSitOuts: sitOuts,
                    roundNumberStart: roundStart,
                    duprRatings: duprRatings
                )
                kotcRounds.append(contentsOf: nextCycle)
                if let firstNew = nextCycle.first {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        expandedRounds.insert(firstNew.id)
                    }
                    scrollTarget = firstNew.id
                }
                saveSession()
            }
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    // Settings page — full width, slides off-screen left when schedule shown
                    ScrollView {
                        settingsCard.padding(16)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: settingsExpanded ? 0 : -geo.size.width)

                    // Schedule page — full width, slides in from right
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                scheduleContent
                            }
                            .padding(16)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: scrollTarget) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.35)) {
                                proxy.scrollTo("round-\(id)", anchor: .top)
                            }
                            scrollTarget = nil
                        }
                    }
                    .offset(x: settingsExpanded ? geo.size.width : 0)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: settingsExpanded)
            }
            .background(Brand.appBackground)
            .navigationTitle(settingsExpanded ? "Generate Play" : (method.isKingOfCourt ? method.rawValue : "Schedule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if settingsExpanded {
                        // Settings page: X dismisses the whole sheet
                        Button {
                            saveSession()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Schedule page: go back to settings to adjust format / courts / rounds
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                settingsExpanded = true
                            }
                        } label: {
                            Label("Settings", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline.weight(.semibold))
                        }
                        .tint(Brand.primaryText)
                    }
                }
                if !settingsExpanded {
                    // Schedule page: dedicated exit button to leave the generator entirely
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            saveSession()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showPrimaryAction {
                    HStack {
                        Spacer()
                        Button { handlePrimaryAction() } label: {
                            Text(primaryActionLabel)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.black)
                                .lineLimit(1)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(Color(hex: "80FF00"), in: Capsule())
                                .opacity(primaryActionEnabled ? 1.0 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .disabled(!primaryActionEnabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Brand.appBackground)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { scoringCourt.map { ScoringTarget(round: $0.round, court: $0.court) } },
            set: { if $0 == nil { scoringCourt = nil } }
        )) { target in
            CourtScoreEntryView(
                round: target.round,
                court: target.court,
                winCondition: winCondition,
                existing: courtResults[target.court.id]
            ) { result in
                courtResults[result.courtID] = result
                scoringCourt = nil
                saveSession()
            }
        }
        .alert("Post Results to Chat?", isPresented: $isShowingPostConfirm) {
            Toggle("Post as Announcement", isOn: $postAsAnnouncement)
            Button("Post") { Task { await postResults() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Results will be posted to \(clubForGame?.name ?? "club") chat and visible to all members.")
        }
        .presentationDetents([.large])
        .task {
            if let saved = ScheduleSessionManager.load(gameID: game.id) {
                pendingResumeSession = saved
                showResumePrompt = true
            }
        }
        .task(id: makeShareTaskID()) {
            guard hasActiveSession else { resultShareImage = nil; return }
            resultShareImage = SessionResultsImageRenderer.render(
                game: game, rounds: activeRounds, results: courtResults, method: method
            )
        }
        .alert("Resume Session?", isPresented: $showResumePrompt, presenting: pendingResumeSession) { session in
            Button("Resume") { applyRestoredSession(session); pendingResumeSession = nil }
            Button("Start Fresh", role: .destructive) {
                ScheduleSessionManager.clear(gameID: game.id)
                pendingResumeSession = nil
            }
        } message: { session in
            Text("A live session was saved on \(session.savedAt.formatted(date: .abbreviated, time: .shortened)). Resume where you left off?")
        }
        .overlay {
            if postSucceeded {
                PostSuccessOverlay {
                    postSucceeded = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: postSucceeded)
    }

    // MARK: Schedule Content (shared between iPhone single-column and iPad right panel)

    @ViewBuilder
    private var scheduleContent: some View {
        // Session state banner
        if hasActiveSession {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: "FF3B30"))
                        .frame(width: 7, height: 7)
                    Text("Live Session")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(hex: "FF3B30"))
                }
                Spacer()
                let shareLabel = Label("Share", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Brand.secondarySurface, in: Capsule())
                    .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
                if let img = resultShareImage {
                    let shareImage = Image(uiImage: img)
                    ShareLink(
                        item: shareImage,
                        preview: SharePreview(game.title, image: shareImage)
                    ) { shareLabel }
                } else {
                    let shareText = SessionResultsFormatter.format(
                        game: game, rounds: activeRounds, results: courtResults,
                        method: method, winCondition: winCondition
                    )
                    ShareLink(item: shareText) { shareLabel }
                }
            }
            .padding(.horizontal, 4)
        }

        if method.isKingOfCourt {
            kotcSection
        } else if let schedule {
            scheduleResults(schedule)
        }
        if !allResults.filter(\.isConfirmed).isEmpty {
            postResultsButton
        }
    }

    // MARK: Settings Card

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            HStack(spacing: 20) {
                // Courts stepper
                VStack(alignment: .center, spacing: 6) {
                    Text("Courts")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.ink)
                    HStack(spacing: 0) {
                        Button { courts = max(1, courts - 1) } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(courts > 1 ? Brand.primaryText : Brand.mutedText)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Brand.softOutline).frame(width: 1, height: 22)
                        Text("\(courts)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                            .frame(minWidth: 36)
                        Rectangle().fill(Brand.softOutline).frame(width: 1, height: 22)
                        Button { courts = min(maxCourts, courts + 1) } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(courts < maxCourts ? Brand.primaryText : Brand.mutedText)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Brand.secondarySurface, in: Capsule())
                    .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 0.5))
                    Text("Max \(maxCourts)")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                }
                .frame(maxWidth: .infinity)

                // Rounds stepper (hidden for both KotC variants)
                if !method.isKingOfCourt {
                    VStack(alignment: .center, spacing: 6) {
                        Text("Rounds")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Brand.ink)
                        HStack(spacing: 0) {
                            Button { rounds = max(1, rounds - 1) } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(rounds > 1 ? Brand.primaryText : Brand.mutedText)
                                    .frame(width: 38, height: 38)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(Brand.softOutline).frame(width: 1, height: 22)
                            Text("\(rounds)")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Brand.primaryText)
                                .frame(minWidth: 36)
                            Rectangle().fill(Brand.softOutline).frame(width: 1, height: 22)
                            Button { rounds = min(10, rounds + 1) } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(rounds < 10 ? Brand.primaryText : Brand.mutedText)
                                    .frame(width: 38, height: 38)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Brand.secondarySurface, in: Capsule())
                        .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 0.5))
                        Text(" ").font(.caption) // height spacer to match Courts
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Allocation Method").font(.subheadline.weight(.medium)).foregroundStyle(Brand.ink)
                VStack(spacing: 4) {
                    ForEach(ScheduleAllocationMethod.allCases) { m in methodChip(m) }
                }

                if method.requiresDUPR && !hasDUPRData {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("No DUPR ratings on file for these players — will sort alphabetically.")
                    }
                    .font(.caption)
                    .foregroundStyle(Brand.spicyOrange)
                    .padding(10)
                    .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                if method == .kingOfCourt {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                        Text("Record each round's results before generating the next. Court 1 winners defend; losers drop to the lowest court.")
                    }
                    .font(.caption)
                    .foregroundStyle(Brand.spicyOrange)
                    .padding(10)
                    .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                if method == .duprKingOfCourt {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                        Text("3 matches per cycle · same 4 players partner with each other once · enter all 3 results then tap Next Cycle to move top scorer up and bottom scorer down.")
                    }
                    .font(.caption)
                    .foregroundStyle(Brand.spicyOrange)
                    .padding(10)
                    .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            if sitOutsPerRound > courts * 4 {
                let recommendedCourts = Int(ceil(Double(confirmedPlayers.count) / 4.0))
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.errorRed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sitOutsPerRound) players sitting out each round")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.errorRed)
                        Text("Consider adding more courts — \(recommendedCourts) recommended for \(confirmedPlayers.count) players.")
                            .font(.caption).foregroundStyle(Brand.errorRed.opacity(0.8))
                    }
                }
                .padding(12)
                .background(Brand.errorRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else if sitOutsPerRound > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.clock").foregroundStyle(Brand.spicyOrange)
                    Text("\(sitOutsPerRound) player\(sitOutsPerRound == 1 ? "" : "s") will sit out each round, rotating fairly.")
                        .font(.subheadline).foregroundStyle(Brand.ink)
                }
                .padding(12)
                .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            // Generate button lives in the navigation bar (toolbar trailing item)

            // Landscape tip
            HStack(spacing: 8) {
                Image(systemName: "rotate.right")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
                Text("Tip: Rotate to landscape for a better court view.")
                    .font(.caption)
                    .foregroundStyle(Brand.mutedText)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func methodChip(_ m: ScheduleAllocationMethod) -> some View {
        Button { method = m } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: method == m ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(method == m ? Brand.primaryText : Brand.mutedText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(method == m ? Brand.primaryText : Brand.secondaryText)
                    Text(m.subtitle)
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                method == m ? Brand.secondarySurface : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(method == m ? Brand.softOutline : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: King of the Court Section

    @ViewBuilder
    private var kotcSection: some View {
        if kotcRounds.isEmpty { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(method.rawValue, systemImage: "crown.fill")
                        .font(.headline).foregroundStyle(Brand.ink)
                    Spacer()
                    Text("\(confirmedPlayers.count) players · \(courts) courts")
                        .font(.caption).foregroundStyle(Brand.mutedText)
                }

                // Ascending order: Round 1 at top, newest at bottom
                ForEach(kotcRounds) { round in
                    roundCard(round, showScoreEntry: true)
                        .id("round-\(round.id)")
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: kotcRounds.count)

                // Waiting-for-results hint (button is in the navbar)
                let canGenerateNext = kotcCanGenerateNextRound || duprKotcCanGenerateNextCycle
                if !canGenerateNext && !kotcRounds.isEmpty {
                    let hintText = method.isDUPRKotC
                        ? "Record all 3 round results to unlock the next cycle."
                        : "Record all court results to unlock the next round."
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                        Text(hintText).font(.subheadline)
                    }
                    .foregroundStyle(Brand.mutedText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: Non-KotC Results

    @ViewBuilder
    private func scheduleResults(_ schedule: GeneratedSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Schedule").font(.headline).foregroundStyle(Brand.ink)
                Spacer()
                Text("\(confirmedPlayers.count) players · \(schedule.courtCount) courts · \(schedule.rounds.count) rounds")
                    .font(.caption).foregroundStyle(Brand.mutedText)
            }
            // Ascending order: Round 1 at top, newest at bottom
            ForEach(schedule.rounds) { round in
                roundCard(round, showScoreEntry: game.requiresDUPR)
                    .id("round-\(round.id)")
            }
        }
    }

    // MARK: Round Card

    private func roundCard(_ round: ScheduledRound, showScoreEntry: Bool) -> some View {
        let isExpanded = expandedRounds.contains(round.id)
        let confirmedCount = round.courts.filter { courtResults[$0.id]?.isConfirmed == true }.count
        let totalCount = round.courts.count
        let allConfirmed = confirmedCount == totalCount

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if isExpanded {
                        expandedRounds.remove(round.id)
                    } else {
                        expandedRounds = [round.id]   // collapse all others
                    }
                }
            } label: {
                HStack {
                    HStack(spacing: 6) {
                        Text("Round \(round.number)").font(sizeClass.roundTitleFont).foregroundStyle(Brand.ink)
                        if allConfirmed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(hex: "80FF00"))
                                .font(.caption)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if !isExpanded && confirmedCount > 0 {
                            Text(allConfirmed ? "Round complete" : "\(confirmedCount) of \(totalCount) complete")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.mutedText)
                        }
                        if !round.sitOuts.isEmpty {
                            Text("\(round.sitOuts.count) sitting out")
                                .font(sizeClass.sitOutCountFont)
                                .foregroundStyle(Brand.mutedText)
                        }
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                        .padding(.leading, 4)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(round.courts.enumerated()), id: \.element.id) { index, court in
                        if index > 0 {
                            Divider().padding(.horizontal, 4).padding(.vertical, sizeClass == .large ? 4 : 2)
                        }
                        courtCard(court, round: round, showScoreEntry: showScoreEntry)
                    }

                    if !round.sitOuts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sitting Out").font(.caption.weight(.semibold)).foregroundStyle(Brand.mutedText)
                            FlowLayout(spacing: 6) {
                                ForEach(round.sitOuts) { player in
                                    Text(firstNameOrFull(player.userName))
                                        .font(sizeClass.pillFont)
                                        .foregroundStyle(Brand.spicyOrange)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Brand.spicyOrange.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private func courtCard(_ court: ScheduledCourt, round: ScheduledRound, showScoreEntry: Bool) -> some View {
        let result = courtResults[court.id]
        let confirmed = result?.isConfirmed == true
        let teamAWins = confirmed && result?.winner == .teamA
        let teamBWins = confirmed && result?.winner == .teamB

        return VStack(spacing: 0) {
            // Court header bar
            HStack {
                HStack(spacing: 6) {
                    Text("Court \(court.number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.secondaryText)
                    if court.number == 1 && method.isKingOfCourt {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color(hex: "D4AF37"))
                    }
                }
                Spacer()
                if confirmed, let r = result {
                    HStack(spacing: 4) {
                        Text("\(r.teamAScore)–\(r.teamBScore)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Brand.emeraldAction)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Player matchup row
            HStack(spacing: 0) {
                // Team A players
                HStack(spacing: 8) {
                    ForEach(court.teamA) { player in
                        playerAvatarCell(player, isWinner: teamAWins)
                    }
                }
                .frame(maxWidth: .infinity)

                // Center: Vs + Record Score
                VStack(spacing: 8) {
                    Text("Vs")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(Brand.primaryText)
                    if showScoreEntry {
                        Button {
                            scoringCourt = (round: round, court: court)
                        } label: {
                            Text(confirmed ? "Edit Score" : "Enter Score")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.primaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Brand.secondarySurface, in: Capsule())
                                .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 96)

                // Team B players
                HStack(spacing: 8) {
                    ForEach(court.teamB) { player in
                        playerAvatarCell(player, isWinner: teamBWins)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 4)
        .background(
            confirmed ? Brand.emeraldAction.opacity(0.04) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func playerAvatarCell(_ player: GameAttendee, isWinner: Bool) -> some View {
        let initials: String = {
            let parts = player.userName.split(separator: " ").prefix(2)
            return parts.compactMap(\.first).map(String.init).joined()
        }()
        let firstName = player.userName.components(separatedBy: " ").first ?? player.userName
        let dupr = duprRatings[player.booking.userID]

        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Brand.secondarySurface)
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle().stroke(isWinner ? Color(hex: "80FF00") : Brand.softOutline.opacity(0.6), lineWidth: isWinner ? 2 : 0.5)
                    )
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.ink)
            }
            Text(firstName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
            if let dupr {
                Text(String(format: "%.3f", dupr))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.mutedText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Brand.secondarySurface, in: Capsule())
                    .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 0.5))
            }
        }
    }

    private func scheduleAvatarColor(for name: String) -> Color {
        let palette: [Color] = [Brand.pineTeal, Brand.slateBlue, Brand.spicyOrange, Brand.emeraldAction, Brand.brandPrimary]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    // MARK: Post Results Button

    private var postResultsButton: some View {
        Button {
            isShowingPostConfirm = true
        } label: {
            Label(isPosting ? "Posting..." : "Post Results to Club Chat", systemImage: "paperplane.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isPosting)
    }

    private func postResults() async {
        guard let club = clubForGame else { return }
        isPosting = true
        defer { isPosting = false }

        // Build a structured result payload — the primary in-app artifact.
        let payload = SessionResultNormalizer.normalize(
            game: game,
            rounds: activeRounds,
            results: courtResults,
            method: method
        )

        let content: String
        if let jsonData = try? JSONEncoder().encode(payload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            content = sessionResultSentinel + jsonString
        } else {
            // Encoding should never fail; fall back to plain text if it does.
            content = SessionResultsFormatter.format(
                game: game, rounds: activeRounds, results: courtResults,
                method: method, winCondition: winCondition
            )
        }

        let success = await appState.createClubNewsPost(
            for: club,
            content: content,
            images: [],
            isAnnouncement: postAsAnnouncement
        )
        if success { postSucceeded = true }
    }

    private func firstNameOrFull(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }
}

// MARK: - Scoring Target (Identifiable wrapper for sheet)

private struct ScoringTarget: Identifiable {
    let id: UUID
    let round: ScheduledRound
    let court: ScheduledCourt

    init(round: ScheduledRound, court: ScheduledCourt) {
        self.id = court.id
        self.round = round
        self.court = court
    }
}

// MARK: - Score Input Field

/// Single tappable score field — shows numeric keyboard, allows empty while editing,
/// clamps to 0–99 on blur/submit, and writes back through the Int binding.
private struct ScoreInputView: View {
    @Binding var score: Int
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(score: Binding<Int>) {
        self._score = score
        // 0 → empty so placeholder "0" is visible; non-zero → prefilled
        self._text = State(initialValue: score.wrappedValue == 0 ? "" : "\(score.wrappedValue)")
    }

    var body: some View {
        TextField("0", text: $text)
            .keyboardType(.numberPad)
            .font(.system(size: 52, weight: .bold, design: .rounded))
            .foregroundStyle(Brand.primaryText)
            .multilineTextAlignment(.center)
            .frame(minWidth: 80)
            .focused($isFocused)
            .onChange(of: text) { _, newVal in
                // Strip non-numeric characters immediately
                let filtered = newVal.filter { $0.isNumber }
                if filtered != newVal { text = filtered }
                // Keep binding live as user types
                if let n = Int(filtered) {
                    score = min(n, 99)
                }
            }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
    }

    private func commit() {
        if let n = Int(text) {
            score = min(max(n, 0), 99)
            text = "\(score)"
        } else {
            // empty field → treat as 0
            score = 0
            text = ""
        }
    }
}

// MARK: - Court Score Entry View

struct CourtScoreEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let round: ScheduledRound
    let court: ScheduledCourt
    let winCondition: WinCondition
    let existing: CourtResult?
    let onConfirm: (CourtResult) -> Void

    @State private var teamAScore: Int
    @State private var teamBScore: Int
    @State private var winner: TeamSide?

    init(round: ScheduledRound, court: ScheduledCourt, winCondition: WinCondition, existing: CourtResult?, onConfirm: @escaping (CourtResult) -> Void) {
        self.round = round
        self.court = court
        self.winCondition = winCondition
        self.existing = existing
        self.onConfirm = onConfirm
        _teamAScore = State(initialValue: existing?.teamAScore ?? 0)
        _teamBScore = State(initialValue: existing?.teamBScore ?? 0)
        _winner = State(initialValue: existing?.winner)
    }

    private var draftResult: CourtResult {
        CourtResult(
            id: existing?.id ?? UUID(),
            roundNumber: round.number,
            courtNumber: court.number,
            courtID: court.id,
            teamA: court.teamA,
            teamB: court.teamB,
            teamAScore: teamAScore,
            teamBScore: teamBScore,
            winner: winner,
            isConfirmed: false
        )
    }

    private var autoWinner: TeamSide? { draftResult.autoWinner(for: winCondition) }
    private var scoresMatchCondition: Bool { draftResult.scoreMatchesCondition(winCondition) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Court header
                    VStack(spacing: 4) {
                        Text("Court \(court.number) — Round \(round.number)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                        Text(winCondition.displayName)
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .padding(.top, 8)

                    // Teams side by side
                    HStack(alignment: .top, spacing: 0) {
                        teamColumn("Team A", players: court.teamA, score: $teamAScore, isWinner: winner == .teamA)
                        Rectangle()
                            .fill(Brand.dividerColor)
                            .frame(width: 1)
                            .padding(.vertical, 24)
                        teamColumn("Team B", players: court.teamB, score: $teamBScore, isWinner: winner == .teamB)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 20)
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Brand.softOutline, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)

                    // Score validation hint
                    if !scoresMatchCondition && (teamAScore > 0 || teamBScore > 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Score doesn't match \(winCondition.displayName) — you can still confirm manually.")
                        }
                        .font(.caption)
                        .foregroundStyle(Brand.spicyOrange)
                        .padding(12)
                        .background(Brand.spicyOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    // Winner picker
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Winner")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                        HStack(spacing: 12) {
                            winnerButton("Team A", side: .teamA)
                            winnerButton("Team B", side: .teamB)
                        }
                    }

                    // Confirm button
                    Button {
                        guard let w = winner else { return }
                        let result = CourtResult(
                            id: existing?.id ?? UUID(),
                            roundNumber: round.number,
                            courtNumber: court.number,
                            courtID: court.id,
                            teamA: court.teamA,
                            teamB: court.teamB,
                            teamAScore: teamAScore,
                            teamBScore: teamBScore,
                            winner: w,
                            isConfirmed: true
                        )
                        onConfirm(result)
                    } label: {
                        Text("Confirm Result")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                winner != nil ? Brand.primaryText : Brand.mutedText,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(winner == nil)
                }
                .padding(16)
            }
            .background(Brand.appBackground)
            .navigationTitle("Enter Score")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: teamAScore) { _, _ in autoSelectWinner() }
            .onChange(of: teamBScore) { _, _ in autoSelectWinner() }
        }
    }

    private func teamColumn(_ label: String, players: [GameAttendee], score: Binding<Int>, isWinner: Bool) -> some View {
        VStack(spacing: 20) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.mutedText)
                .textCase(.uppercase)
                .tracking(0.5)

            // Player avatars side by side
            HStack(spacing: 12) {
                ForEach(players) { player in
                    scoreEntryAvatar(player, isWinner: isWinner)
                }
            }

            ScoreInputView(score: score)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func scoreEntryAvatar(_ player: GameAttendee, isWinner: Bool) -> some View {
        let initials: String = {
            let parts = player.userName.split(separator: " ").prefix(2)
            return parts.compactMap(\.first).map(String.init).joined()
        }()
        let firstName = player.userName.components(separatedBy: " ").first ?? player.userName

        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Brand.secondarySurface)
                    .frame(width: 54, height: 54)
                    .overlay(
                        Circle().stroke(isWinner ? Color(hex: "80FF00") : Brand.softOutline, lineWidth: isWinner ? 2.5 : 1)
                    )
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Brand.ink)
            }
            Text(firstName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
        }
    }

    private func scheduleAvatarColor(for name: String) -> Color {
        let palette: [Color] = [Brand.pineTeal, Brand.slateBlue, Brand.spicyOrange, Brand.emeraldAction, Brand.brandPrimary]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    private func winnerButton(_ label: String, side: TeamSide) -> some View {
        Button { winner = side } label: {
            HStack(spacing: 6) {
                Image(systemName: winner == side ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(winner == side ? Brand.primaryText : Brand.mutedText)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.primaryText)
                if winner == side {
                    Image(systemName: "crown.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.spicyOrange)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                winner == side ? Brand.secondarySurface : Color(.systemGray6),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(winner == side ? Brand.softOutline : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func autoSelectWinner() {
        if let auto = autoWinner { winner = auto }
    }
}

// MARK: - Post Success Overlay

private struct PostSuccessOverlay: View {
    let onDismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Animated checkmark
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 148, height: 148)
                    Circle()
                        .stroke(Color.green.opacity(0.35), lineWidth: 2)
                        .frame(width: 148, height: 148)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 88))
                        .foregroundStyle(Color.green)
                }
                .scaleEffect(appeared ? 1.0 : 0.4)
                .opacity(appeared ? 1.0 : 0)

                VStack(spacing: 10) {
                    Text("Results Posted!")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Shared to club chat")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 32)
                .opacity(appeared ? 1.0 : 0)
                .offset(y: appeared ? 0 : 8)

                Spacer()

                Button(action: onDismiss) {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
                .opacity(appeared ? 1.0 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.52, dampingFraction: 0.62)) {
                appeared = true
            }
        }
    }
}

