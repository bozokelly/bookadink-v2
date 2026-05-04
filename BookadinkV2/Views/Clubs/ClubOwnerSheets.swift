import SwiftUI
import os
import PhotosUI

enum OwnerToolSheet: String, Identifiable {
    case dashboard    // Club Dashboard — tier + metrics + quick-nav
    case manageGames
    case joinRequests
    case createGame
    case editClub
    case members
    case analytics
    case roleHistory  // Audit trail of every role change in this club

    var id: String { rawValue }
}

struct OwnerJoinRequestsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club

    var body: some View {
        NavigationStack {
            Group {
                if appState.isLoadingOwnerJoinRequests(for: club) && appState.ownerJoinRequests(for: club).isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading join requests...")
                            .foregroundStyle(Brand.mutedText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.ownerJoinRequests(for: club).isEmpty {
                    ContentUnavailableView(
                        "No Pending Requests",
                        systemImage: "person.badge.plus",
                        description: Text("New membership requests will appear here.")
                    )
                } else {
                    List {
                        ForEach(appState.ownerJoinRequests(for: club)) { request in
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(request.memberName)
                                        .font(.headline)
                                    if let email = request.memberEmail, !email.isEmpty {
                                        Text(email)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let requestedAt = request.requestedAt {
                                        Text("Requested \(requestedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        Task { await appState.decideOwnerJoinRequest(request, in: club, approve: false) }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if appState.isUpdatingOwnerJoinRequest(request) {
                                                ProgressView().tint(Brand.pineTeal)
                                            } else {
                                                Image(systemName: "xmark.circle")
                                            }
                                            Text("Reject")
                                                .fontWeight(.semibold)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 42)
                                        .foregroundStyle(Brand.pineTeal)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(appState.isUpdatingOwnerJoinRequest(request))
                                    .actionBorder(cornerRadius: 12, color: Brand.softOutline)

                                    Button {
                                        Task { await appState.decideOwnerJoinRequest(request, in: club, approve: true) }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if appState.isUpdatingOwnerJoinRequest(request) {
                                                ProgressView().tint(.white)
                                            } else {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                            Text("Approve")
                                                .fontWeight(.semibold)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 42)
                                        .foregroundStyle(.white)
                                        .background(Brand.emeraldAction, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(appState.isUpdatingOwnerJoinRequest(request))
                                    .actionBorder(cornerRadius: 12, color: Brand.softOutline)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Brand.cardBackground)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Brand.pageGradient.opacity(0.2))
                }
            }
            .navigationTitle("Join Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshOwnerJoinRequests(for: club) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                await appState.refreshOwnerJoinRequests(for: club)
            }
        }
    }
}

struct OwnerCreateGameSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    @State private var draft: ClubOwnerGameDraft
    @State private var savedVenues: [ClubVenue] = []
    /// Drives the upgrade paywall sheet. Set to the relevant feature before presenting.
    @State private var paywallFeature: LockedFeature? = nil

    // MARK: - Gate checks

    /// Active game limit — mirrors AppState.createGameForClub logic.
    private var gameLimitGateResult: GateResult {
        let now = Date()
        let repeatCount = draft.repeatWeekly ? max(draft.repeatCount, 1) : 1
        let currentActiveCount = (appState.gamesByClubID[club.id] ?? [])
            .filter { $0.status != "cancelled" && $0.dateTime > now }
            .count
        return FeatureGateService.canCreateGame(
            appState.entitlementsByClubID[club.id],
            currentActiveGameCount: currentActiveCount + repeatCount - 1
        )
    }

    private var recurringGamesGate: GateResult {
        FeatureGateService.canUseRecurringGames(appState.entitlementsByClubID[club.id])
    }

    private var delayedPublishingGate: GateResult {
        FeatureGateService.canUseDelayedPublishing(appState.entitlementsByClubID[club.id])
    }

    private var paymentsGate: GateResult {
        FeatureGateService.canAcceptPayments(appState.entitlementsByClubID[club.id])
    }

    init(club: Club) {
        self.club = club
        // Pre-populate court count from club's default
        var d = ClubOwnerGameDraft()
        d.courtCount = max(1, club.defaultCourtCount)
        _draft = State(initialValue: d)
    }

    init(club: Club, initialDraft: ClubOwnerGameDraft) {
        self.club = club
        _draft = State(initialValue: initialDraft)
    }

    private let gameTypeOptions: [(value: String, label: String)] = [
        ("doubles", "Doubles"),
        ("singles", "Singles")
    ]

    private let skillOptions: [(value: String, label: String)] = [
        ("all", "All Levels"),
        ("beginner", "Beginner (2.0 – <3.0)"),
        ("intermediate", "Intermediate (3.0 – <4.0)"),
        ("advanced", "Advanced (4.0+)")
    ]

    private let formatOptions: [(value: String, label: String)] = [
        ("open_play", "Open Play"),
        ("random", "Random"),
        ("round_robin", "Round Robin"),
        ("king_of_court", "King of the Court"),
        ("dupr_king_of_court", "DUPR King of the Court")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Game title", text: $draft.title)
                    TextField("Information (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(2...4)
                    DatePicker("Start", selection: $draft.startDate)
                }

                Section("Game Details") {
                    Picker("Game Type", selection: $draft.gameTypeRaw) {
                        ForEach(gameTypeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Picker("Skill Level", selection: $draft.skillLevelRaw) {
                        ForEach(skillOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Picker("Format", selection: $draft.gameFormatRaw) {
                        ForEach(formatOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Toggle("Requires DUPR", isOn: $draft.requiresDUPR)
                }

                Section("Schedule") {
                    if case .blocked = recurringGamesGate {
                        ProLockedRow(label: "Repeat Weekly") {
                            paywallFeature = .recurringGames
                        }
                    } else {
                        Toggle("Repeat Weekly", isOn: $draft.repeatWeekly)
                        if draft.repeatWeekly {
                            PillStepperRow(label: "Occurrences: \(draft.repeatCount)", value: $draft.repeatCount, range: 2...12, step: 1)
                            Text("Creates a weekly series starting from the selected date.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if case .blocked = delayedPublishingGate {
                        ProLockedRow(label: "Delay Publishing") {
                            paywallFeature = .scheduledPublishing
                        }
                    } else {
                        Toggle("Delay Publishing", isOn: Binding(
                            get: { draft.publishAt != nil },
                            set: { enabled in
                                if enabled {
                                    draft.publishAt = draft.startDate.addingTimeInterval(-48 * 3600)
                                } else {
                                    draft.publishAt = nil
                                }
                            }
                        ))
                        if let publishAt = draft.publishAt {
                            DatePicker(
                                "Publish At",
                                selection: Binding(
                                    get: { draft.publishAt ?? draft.startDate.addingTimeInterval(-48 * 3600) },
                                    set: { draft.publishAt = $0 }
                                ),
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            Text(publishOffsetLabel(publishAt: publishAt, gameStart: draft.startDate))
                                .font(.caption)
                                .foregroundStyle(publishAt <= Date() ? Brand.errorRed : .secondary)
                        }
                    }
                } header: {
                    Text("Publishing")
                } footer: {
                    if draft.publishAt != nil, draft.repeatWeekly {
                        Text("Each recurring game will publish at the same interval before its own start time.")
                            .font(.caption)
                    }
                }

                Section("Capacity & Fee") {
                    PillStepperRow(label: "Duration: \(draft.durationMinutes) mins", value: $draft.durationMinutes, range: 30...240, step: 15)
                    PillStepperRow(label: "Max Spots: \(draft.maxSpots)", value: $draft.maxSpots, range: 2...64, step: 1)
                    PillStepperRow(label: "Courts: \(draft.courtCount)", value: $draft.courtCount, range: 1...20, step: 1)
                    if case .blocked = paymentsGate {
                        ProLockedRow(label: "Game Fee") {
                            paywallFeature = .payments
                        }
                    } else {
                        TextField("Fee (optional, $)", text: $draft.feeAmountText)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    if !savedVenues.isEmpty {
                        venuePicker(venues: savedVenues)
                    }
                    if draft.selectedVenueID == nil {
                        TextField("Venue name", text: $draft.venueName)
                        TextField("Location notes (optional)", text: $draft.location)
                    }
                } header: {
                    Text("Location & Rules")
                } footer: {
                    if !draft.hasVenue {
                        Text("A venue is required. Select a saved venue or enter a venue name.")
                            .foregroundStyle(Brand.errorRed)
                    }
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.errorRed)
                    }
                }
            }
            .navigationTitle("Create Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Show upgrade paywall if the game limit is reached.
                        if case .blocked = gameLimitGateResult {
                            appState.ownerToolsErrorMessage = nil
                            paywallFeature = .gameLimit
                            return
                        }
                        Task {
                            let saved = await appState.createGameForClub(club, draft: draft)
                            if saved { dismiss() }
                        }
                    } label: {
                        if appState.isCreatingOwnerGame {
                            ProgressView()
                        } else {
                            Text("Create")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(appState.isCreatingOwnerGame || !draft.hasVenue)
                }
            }
            .task {
                // Refresh entitlements first so feature gates (delayed publishing,
                // recurring games, payments) reflect a recent upgrade even if the
                // Stripe webhook landed after the paywall's polling window closed.
                await appState.fetchClubEntitlements(for: club.id)
                savedVenues = appState.venues(for: club)
                if savedVenues.isEmpty {
                    await appState.refreshVenues(for: club)
                    savedVenues = appState.venues(for: club)
                }
                // If already at the game limit when the sheet opens, show paywall immediately.
                if case .blocked = gameLimitGateResult {
                    appState.ownerToolsErrorMessage = nil
                    paywallFeature = .gameLimit
                }
            }
            .sheet(item: $paywallFeature) { feature in
                ClubUpgradePaywallView(club: club, lockedFeature: feature)
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func venuePicker(venues: [ClubVenue]) -> some View {
        Picker("Venue", selection: Binding(
            get: { draft.selectedVenueID },
            set: { newID in
                if let newID, let venue = venues.first(where: { $0.id == newID }) {
                    draft.applyVenue(venue)
                } else {
                    draft.clearVenue()
                }
            }
        )) {
            Text("Custom address").tag(Optional<UUID>.none)
            ForEach(venues) { venue in
                Text(venue.pickerLabel).tag(Optional(venue.id))
            }
        }
    }

    private func publishOffsetLabel(publishAt: Date, gameStart: Date) -> String {
        if publishAt <= Date() { return "Publish time must be in the future." }
        let diff = gameStart.timeIntervalSince(publishAt)
        guard diff > 0 else { return "Publish time is after game start — game will go live immediately." }
        return "Game will go live \(offsetString(diff)) before its start time."
    }

    private func offsetString(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let days  = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let mins  = totalMinutes % 60
        var parts: [String] = []
        if days > 0  { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0  { parts.append("\(mins)m") }
        return parts.joined(separator: " ")
    }
}

struct OwnerEditGameSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    let game: Game
    @State private var draft: ClubOwnerGameDraft
    @State private var recurringEditScope: RecurringGameScope = .singleEvent
    @State private var savedVenues: [ClubVenue] = []
    @State private var paywallFeature: LockedFeature? = nil

    private var paymentsGate: GateResult {
        FeatureGateService.canAcceptPayments(appState.entitlementsByClubID[club.id])
    }

    private var delayedPublishingGate: GateResult {
        FeatureGateService.canUseDelayedPublishing(appState.entitlementsByClubID[club.id])
    }

    private let gameTypeOptions: [(value: String, label: String)] = [
        ("doubles", "Doubles"),
        ("singles", "Singles")
    ]

    private let skillOptions: [(value: String, label: String)] = [
        ("all", "All Levels"),
        ("beginner", "Beginner (2.0 – <3.0)"),
        ("intermediate", "Intermediate (3.0 – <4.0)"),
        ("advanced", "Advanced (4.0+)")
    ]

    private let formatOptions: [(value: String, label: String)] = [
        ("open_play", "Open Play"),
        ("random", "Random"),
        ("round_robin", "Round Robin"),
        ("king_of_court", "King of the Court"),
        ("dupr_king_of_court", "DUPR King of the Court")
    ]

    init(club: Club, game: Game, initialVenues: [ClubVenue] = []) {
        self.club = club
        self.game = game
        var d = ClubOwnerGameDraft(game: game)
        // Pre-select venue synchronously so the picker opens on the correct venue
        // with no flicker.
        // Resolution order: venue_id FK first (exact match), then venue_name fallback
        // for games that predate the venue_id migration.
        if let venueId = game.venueId,
           let match = initialVenues.first(where: { $0.id == venueId }) {
            d.applyVenue(match)
        } else {
            let trimmedGameVenueName = d.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGameVenueName.isEmpty,
               let match = initialVenues.first(where: {
                   $0.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
                       .caseInsensitiveCompare(trimmedGameVenueName) == .orderedSame
               }) {
                d.applyVenue(match)
            }
        }
        _draft = State(initialValue: d)
        _savedVenues = State(initialValue: initialVenues)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Game title", text: $draft.title)
                    TextField("Information (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(2...4)
                    DatePicker("Start", selection: $draft.startDate)
                }

                if game.recurrenceGroupID != nil {
                    Section("Update Scope") {
                        Picker("Apply To", selection: $recurringEditScope) {
                            Text(RecurringGameScope.singleEvent.rawValue).tag(RecurringGameScope.singleEvent)
                            Text(RecurringGameScope.thisAndFuture.rawValue).tag(RecurringGameScope.thisAndFuture)
                            Text(RecurringGameScope.entireSeries.rawValue).tag(RecurringGameScope.entireSeries)
                        }
                    }
                }

                Section("Game Details") {
                    Picker("Game Type", selection: $draft.gameTypeRaw) {
                        ForEach(gameTypeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Picker("Skill Level", selection: $draft.skillLevelRaw) {
                        ForEach(skillOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Picker("Format", selection: $draft.gameFormatRaw) {
                        ForEach(formatOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Toggle("Requires DUPR", isOn: $draft.requiresDUPR)
                }

                Section("Capacity & Fee") {
                    PillStepperRow(label: "Duration: \(draft.durationMinutes) mins", value: $draft.durationMinutes, range: 30...240, step: 15)
                    PillStepperRow(label: "Max Spots: \(draft.maxSpots)", value: $draft.maxSpots, range: 2...64, step: 1)
                    PillStepperRow(label: "Courts: \(draft.courtCount)", value: $draft.courtCount, range: 1...20, step: 1)
                    if case .blocked = paymentsGate {
                        ProLockedRow(label: "Game Fee") {
                            paywallFeature = .payments
                        }
                    } else {
                        TextField("Fee (optional, $)", text: $draft.feeAmountText)
                            .keyboardType(.decimalPad)
                    }
                }

                Section {
                    if !savedVenues.isEmpty {
                        editVenuePicker(venues: savedVenues)
                    }
                    if draft.selectedVenueID == nil {
                        TextField("Venue name", text: $draft.venueName)
                        TextField("Location notes (optional)", text: $draft.location)
                    }
                } header: {
                    Text("Location & Rules")
                } footer: {
                    if !draft.hasVenue {
                        Text("A venue is required. Select a saved venue or enter a venue name.")
                            .foregroundStyle(Brand.errorRed)
                    }
                }

                Section {
                    if case .blocked = delayedPublishingGate {
                        ProLockedRow(label: "Delay Publishing") {
                            paywallFeature = .scheduledPublishing
                        }
                    } else {
                        Toggle("Delay Publishing", isOn: Binding(
                            get: { draft.publishAt != nil },
                            set: { enabled in
                                if enabled {
                                    draft.publishAt = draft.startDate.addingTimeInterval(-48 * 3600)
                                } else {
                                    draft.publishAt = nil
                                }
                            }
                        ))
                        if let publishAt = draft.publishAt {
                            DatePicker(
                                "Publish At",
                                selection: Binding(
                                    get: { draft.publishAt ?? draft.startDate.addingTimeInterval(-48 * 3600) },
                                    set: { draft.publishAt = $0 }
                                ),
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            Text(editPublishOffsetLabel(publishAt: publishAt, gameStart: draft.startDate))
                                .font(.caption)
                                .foregroundStyle(publishAt <= Date() ? Brand.errorRed : .secondary)
                        }
                    }
                } header: {
                    Text("Publishing")
                } footer: {
                    if draft.publishAt != nil, game.recurrenceGroupID != nil,
                       recurringEditScope != .singleEvent {
                        Text("Each affected game will publish at the same interval before its own start time.")
                            .font(.caption)
                    }
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.errorRed)
                    }
                }
            }
            .navigationTitle("Edit Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            let saved = await appState.updateGameForClub(
                                club,
                                game: game,
                                draft: draft,
                                scope: game.recurrenceGroupID == nil ? .singleEvent : recurringEditScope
                            )
                            if saved { dismiss() }
                        }
                    } label: {
                        if appState.isOwnerSavingGame(game) {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(appState.isOwnerSavingGame(game) || !draft.hasVenue)
                }
            }
            .task {
                // Refresh entitlements first so the delayed publishing gate reflects
                // a recent upgrade even if the Stripe webhook landed after the
                // paywall's polling window closed.
                await appState.fetchClubEntitlements(for: club.id)
                // Venues may already be seeded from init. Only fetch if missing.
                if savedVenues.isEmpty {
                    await appState.refreshVenues(for: club)
                    savedVenues = appState.venues(for: club)
                    // Retry matching after fetch in case venues weren't cached at open time.
                    // Resolution order: venue_id first, then venue_name fallback.
                    if draft.selectedVenueID == nil {
                        if let venueId = game.venueId,
                           let match = savedVenues.first(where: { $0.id == venueId }) {
                            draft.applyVenue(match)
                        } else {
                            let trimmed = draft.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty,
                               let match = savedVenues.first(where: {
                                   $0.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
                                       .caseInsensitiveCompare(trimmed) == .orderedSame
                               }) {
                                draft.applyVenue(match)
                            }
                        }
                    }
                }
            }
            .sheet(item: $paywallFeature) { feature in
                ClubUpgradePaywallView(club: club, lockedFeature: feature)
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func editVenuePicker(venues: [ClubVenue]) -> some View {
        Picker("Venue", selection: Binding(
            get: { draft.selectedVenueID },
            set: { newID in
                if let newID, let venue = venues.first(where: { $0.id == newID }) {
                    draft.applyVenue(venue)
                } else {
                    draft.clearVenue()
                }
            }
        )) {
            Text("Custom address").tag(Optional<UUID>.none)
            ForEach(venues) { venue in
                Text(venue.pickerLabel).tag(Optional(venue.id))
            }
        }
    }

    private func editPublishOffsetLabel(publishAt: Date, gameStart: Date) -> String {
        if publishAt <= Date() { return "Publish time must be in the future." }
        let diff = gameStart.timeIntervalSince(publishAt)
        guard diff > 0 else { return "Publish time is after game start — game will go live immediately." }
        let totalMinutes = Int(diff / 60)
        let days  = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let mins  = totalMinutes % 60
        var parts: [String] = []
        if days > 0  { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0  { parts.append("\(mins)m") }
        return "Game will go live \(parts.joined(separator: " ")) before its start time."
    }
}

struct OwnerMembersSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    @State private var selectedMember: ClubOwnerMember?
    @State private var searchText: String = ""

    private var filteredMembers: [ClubOwnerMember] {
        let all = appState.ownerMembers(for: club)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.memberName.localizedCaseInsensitiveContains(query) ||
            ($0.memberEmail?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var ownerSection: [ClubOwnerMember] {
        filteredMembers.filter { $0.isOwner }
            .sorted { $0.memberName.localizedCaseInsensitiveCompare($1.memberName) == .orderedAscending }
    }

    private var adminSection: [ClubOwnerMember] {
        filteredMembers.filter { $0.isAdmin && !$0.isOwner }
            .sorted { $0.memberName.localizedCaseInsensitiveCompare($1.memberName) == .orderedAscending }
    }

    private var memberSection: [ClubOwnerMember] {
        filteredMembers.filter { !$0.isAdmin && !$0.isOwner }
            .sorted { $0.memberName.localizedCaseInsensitiveCompare($1.memberName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.isLoadingOwnerMembers(for: club), appState.ownerMembers(for: club).isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading members...")
                            .foregroundStyle(Brand.mutedText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.ownerMembers(for: club).isEmpty {
                    ContentUnavailableView(
                        "No Members",
                        systemImage: "person.3",
                        description: Text("Approved members will appear here.")
                    )
                } else {
                    List {
                        if !ownerSection.isEmpty {
                            Section("Owner") {
                                ForEach(ownerSection) { member in
                                    memberRow(member)
                                }
                            }
                        }
                        if !adminSection.isEmpty {
                            Section("Admins") {
                                ForEach(adminSection) { member in
                                    memberRow(member)
                                }
                            }
                        }
                        if !memberSection.isEmpty {
                            Section("Members") {
                                ForEach(memberSection) { member in
                                    memberRow(member)
                                }
                            }
                        }
                        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           ownerSection.isEmpty, adminSection.isEmpty, memberSection.isEmpty {
                            Section {
                                Text("No members match your search.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Brand.pageGradient.opacity(0.2))
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search members")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshOwnerMembers(for: club) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                await appState.refreshOwnerMembers(for: club)
            }
            .sheet(item: $selectedMember) { member in
                OwnerMemberDetailSheet(club: club, member: member)
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ClubOwnerMember) -> some View {
        Button {
            selectedMember = member
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Avatar colour is identity data. Do not derive per-view.
                Circle()
                    .fill(AvatarGradients.resolveGradient(forKey: member.avatarColorKey))
                    .overlay(
                        Text(initials(for: member.memberName))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(member.memberName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(member.isOwner ? "Owner" : member.isAdmin ? "Admin" : "Member")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Brand.secondaryText)

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(Brand.secondaryText)

                        memberStatusChip(
                            label: "Emrg",
                            present: !memberFieldMissing(member.emergencyContactName) || !memberFieldMissing(member.emergencyContactPhone)
                        )
                        memberStatusChip(label: "Mob", present: !memberFieldMissing(member.memberPhone))
                        memberStatusChip(label: "Cond", present: member.conductAcceptedAt != nil)
                        memberStatusChip(label: "Pol", present: member.cancellationPolicyAcceptedAt != nil)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Brand.cardBackground)
    }

    private func initials(for name: String) -> String {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "M" : String(chars)
    }

    private func memberRolePill(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
    }

    private func memberFieldMissing(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    @ViewBuilder
    private func memberStatusChip(label: String, present: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: present ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(present ? Color.secondary.opacity(0.6) : Brand.spicyOrange)
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(present ? Color.secondary : Brand.spicyOrange)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

struct OwnerMemberDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let club: Club
    let member: ClubOwnerMember
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var confirmTransfer = false
    @State private var showDUPRUpdateSheet = false

    private var liveMember: ClubOwnerMember {
        appState.ownerMembers(for: club).first(where: { $0.userID == member.userID }) ?? member
    }

    private var viewerIsOwner: Bool {
        appState.isClubOwner(for: club)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(liveMember.isOwner ? Brand.coralBlaze.opacity(0.9) : Brand.slateBlue)
                            .overlay(
                                Text(initials(for: liveMember.memberName))
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)
                            )
                            .frame(width: 52, height: 52)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(liveMember.memberName)
                                .font(.headline)
                            if liveMember.isOwner {
                                memberRolePill("Owner", fill: Brand.coralBlaze, text: .white)
                            } else if liveMember.isAdmin {
                                memberRolePill("Admin", fill: Brand.slateBlueDark, text: .white)
                            } else {
                                memberRolePill("Member", fill: Brand.secondarySurface, text: Brand.primaryText)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Contact Card")
                }

                Section("Contact") {
                    minimalContactRow(
                        value: liveMember.memberEmail,
                        icon: "envelope",
                        placeholder: "No email provided"
                    ) {
                        guard let email = liveMember.memberEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !email.isEmpty,
                              let url = URL(string: "mailto:\(email)") else { return }
                        openURL(url)
                    }

                    minimalContactRow(
                        value: liveMember.memberPhone,
                        icon: "phone",
                        placeholder: "Not provided"
                    ) {
                        guard let raw = liveMember.memberPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !raw.isEmpty else { return }
                        let digits = raw.filter { $0.isNumber || $0 == "+" }
                        guard let url = URL(string: "tel:\(digits)") else { return }
                        openURL(url)
                    }
                }

                Section("Emergency Contact") {
                    if isMissing(liveMember.emergencyContactName) && isMissing(liveMember.emergencyContactPhone) {
                        Text("Not provided")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            if !isMissing(liveMember.emergencyContactName) {
                                HStack(spacing: 10) {
                                    Image(systemName: "person")
                                        .foregroundStyle(.secondary)
                                    Text(nonEmpty(liveMember.emergencyContactName))
                                        .font(.body.weight(.medium))
                                }
                            }
                            if !isMissing(liveMember.emergencyContactPhone) {
                                Button {
                                    guard let raw = liveMember.emergencyContactPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
                                          !raw.isEmpty else { return }
                                    let digits = raw.filter { $0.isNumber || $0 == "+" }
                                    guard let url = URL(string: "tel:\(digits)") else { return }
                                    openURL(url)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "cross.case")
                                            .foregroundStyle(.secondary)
                                        Text(nonEmpty(liveMember.emergencyContactPhone))
                                            .foregroundStyle(.primary)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        if let rating = liveMember.duprRating {
                            Text(String(format: "%.3f", rating))
                                .font(.body.weight(.medium))
                        } else {
                            Text("Not set")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update") { showDUPRUpdateSheet = true }
                            .buttonStyle(.bordered)
                            .tint(Brand.pineTeal)
                    }
                } header: {
                    Text("DUPR Rating")
                } footer: {
                    if let name = liveMember.duprUpdatedByName, let date = liveMember.duprUpdatedAt {
                        Text("Last updated by \(name) on \(date.formatted(.dateTime.day().month(.wide).year()))")
                            .foregroundStyle(Brand.mutedText)
                    }
                }
                .sheet(isPresented: $showDUPRUpdateSheet) {
                    DUPRUpdateSheet(memberName: liveMember.memberName) { rating in
                        Task {
                            await appState.adminUpdateMemberDUPR(liveMember, rating: rating)
                            await appState.refreshOwnerMembers(for: club)
                        }
                    }
                }

                Section("Code of Conduct") {
                    if let acceptedAt = liveMember.conductAcceptedAt {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Brand.pineTeal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Accepted")
                                    .font(.body.weight(.medium))
                                Text(acceptedAt.formatted(.dateTime.day().month(.wide).year().hour().minute()))
                                    .font(.caption)
                                    .foregroundStyle(Brand.mutedText)
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Brand.mutedText)
                            Text("Not accepted")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Cancellation Policy") {
                    if let acceptedAt = liveMember.cancellationPolicyAcceptedAt {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Brand.pineTeal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Accepted")
                                    .font(.body.weight(.medium))
                                Text(acceptedAt.formatted(.dateTime.day().month(.wide).year().hour().minute()))
                                    .font(.caption)
                                    .foregroundStyle(Brand.mutedText)
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Brand.mutedText)
                            Text("Not accepted")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Actions") {
                    if liveMember.isOwner {
                        // Owner row — fully protected
                        Label("Club owner cannot be modified.", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else if viewerIsOwner {
                        // Full owner controls
                        Button {
                            Task {
                                await appState.setOwnerMemberAdminAccess(liveMember, in: club, makeAdmin: !liveMember.isAdmin)
                            }
                        } label: {
                            HStack {
                                if appState.isUpdatingOwnerAdminAccess(for: liveMember.userID) {
                                    ProgressView()
                                } else {
                                    Image(systemName: liveMember.isAdmin ? "person.badge.minus" : "person.badge.plus")
                                }
                                Text(liveMember.isAdmin ? "Remove Admin" : "Make Admin")
                            }
                        }
                        .disabled(appState.isUpdatingOwnerAdminAccess(for: liveMember.userID) || appState.isModeratingOwnerMember(liveMember.userID))

                        Button { confirmTransfer = true } label: {
                            HStack {
                                if appState.isUpdatingOwnerAdminAccess(for: liveMember.userID) {
                                    ProgressView()
                                } else {
                                    Image(systemName: "crown.fill")
                                }
                                Text("Transfer Ownership")
                            }
                        }
                        .disabled(appState.isUpdatingOwnerAdminAccess(for: liveMember.userID) || appState.isModeratingOwnerMember(liveMember.userID))

                        Button(role: .destructive) { confirmRemove = true } label: {
                            HStack {
                                Image(systemName: "person.fill.xmark")
                                Text("Remove Member")
                            }
                        }
                        .disabled(appState.isModeratingOwnerMember(liveMember.userID))

                        Button(role: .destructive) { confirmBlock = true } label: {
                            HStack {
                                Image(systemName: "hand.raised.fill")
                                Text("Block Member")
                            }
                        }
                        .disabled(appState.isModeratingOwnerMember(liveMember.userID))

                        if appState.isModeratingOwnerMember(liveMember.userID) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Updating member access...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if liveMember.isAdmin {
                        // Viewer is admin looking at another admin — read-only
                        Label("Only the club owner can modify admin accounts.", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        // Viewer is admin, member is a regular member — limited controls
                        Button(role: .destructive) { confirmRemove = true } label: {
                            HStack {
                                Image(systemName: "person.fill.xmark")
                                Text("Remove Member")
                            }
                        }
                        .disabled(appState.isModeratingOwnerMember(liveMember.userID))

                        Button(role: .destructive) { confirmBlock = true } label: {
                            HStack {
                                Image(systemName: "hand.raised.fill")
                                Text("Block Member")
                            }
                        }
                        .disabled(appState.isModeratingOwnerMember(liveMember.userID))

                        if appState.isModeratingOwnerMember(liveMember.userID) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Updating member access...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let info = appState.ownerToolsInfoMessage, !info.isEmpty {
                    Section {
                        Text(info)
                            .foregroundStyle(Brand.pineTeal)
                    }
                }
                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.errorRed)
                    }
                }
            }
            .navigationTitle("Member Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .listStyle(.insetGrouped)
            .confirmationDialog(
                "Remove Member?",
                isPresented: $confirmRemove,
                titleVisibility: .visible
            ) {
                Button("Remove Member", role: .destructive) {
                    Task {
                        await appState.removeOwnerMember(liveMember, in: club)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the member from the club.")
            }
            .confirmationDialog(
                "Block Member?",
                isPresented: $confirmBlock,
                titleVisibility: .visible
            ) {
                Button("Block Member", role: .destructive) {
                    Task {
                        await appState.blockOwnerMember(liveMember, in: club)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This blocks the member from the club and removes access.")
            }
            .confirmationDialog(
                "Transfer ownership to \(liveMember.memberName)?",
                isPresented: $confirmTransfer,
                titleVisibility: .visible
            ) {
                Button("Transfer — I'll stay as Admin") {
                    Task {
                        await appState.transferClubOwnership(in: club, newOwnerID: liveMember.userID, oldOwnerNewRole: "admin")
                        dismiss()
                    }
                }
                Button("Transfer — I'll become a Member") {
                    Task {
                        await appState.transferClubOwnership(in: club, newOwnerID: liveMember.userID, oldOwnerNewRole: "member")
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They become the club owner. You stop being owner immediately and can no longer transfer ownership back without the new owner's action.")
            }
        }
    }

    private func minimalContactRow(
        value: String?,
        icon: String,
        placeholder: String,
        action: @escaping () -> Void
    ) -> some View {
        let hasValue = !isMissing(value)
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(hasValue ? nonEmpty(value) : placeholder)
                    .foregroundStyle(hasValue ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasValue)
    }

    private func nonEmpty(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Not provided" : trimmed
    }

    private func isMissing(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private func initials(for name: String) -> String {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "M" : String(chars)
    }

    private func memberRolePill(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
    }
}

// MARK: - DUPR Update Sheet

private struct DUPRUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss

    let memberName: String
    let onSave: (Double) -> Void

    @State private var ratingText = ""
    @State private var isSaving = false

    private var parsedRating: Double? {
        let trimmed = ratingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 3 else { return nil }
        guard let v = Double(trimmed), v >= 2.0, v <= 8.0 else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. 3.524", text: $ratingText)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("New rating for \(memberName)")
                } footer: {
                    Text("Must be between 2.000 and 8.000, exactly 3 decimal places.")
                }
            }
            .navigationTitle("Update DUPR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard let rating = parsedRating else { return }
                        isSaving = true
                        onSave(rating)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(parsedRating == nil || isSaving)
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}

// MARK: - Club Form Body (shared by Create and Edit)

/// All shared form sections for creating or editing a club.
/// Embed inside a `Form {}` in the parent sheet. The parent provides
/// flow-specific chrome: toolbar, success/error feedback, Danger Zone (edit only).
///
/// - `club: nil`  → create mode: venues section shows a placeholder (no club ID yet)
/// - `club: Club` → edit mode:   venues section shows full CRUD with add/edit/delete
struct ClubFormBody: View {
    @EnvironmentObject private var appState: AppState
    @Binding var draft: ClubOwnerEditDraft

    /// nil = create mode, non-nil = edit mode
    var club: Club?

    /// Hero key → asset name mapping. Static so it is never rebuilt during renders.
    private static let heroImageNames: [String: String] = [
        "hero_1": "vine_concept",
        "hero_2": "red_topdown",
        "hero_3": "blue_collage",
        "hero_4": "blue_closeup",
        "hero_5": "red_aerial",
        "hero_6": "dark_aerial",
    ]

    /// Venues for the current club. Computed once per render and reused throughout
    /// the body instead of calling `appState.venues(for:)` three separate times.
    private var clubVenues: [ClubVenue] {
        guard let club else { return [] }
        return appState.venues(for: club)
    }

    // Edit-mode venue callbacks
    var onAddVenue: (() -> Void)?
    var onEditVenue: ((ClubVenue) -> Void)?

    // Create-mode pending venue (local draft, not yet saved to DB)
    var pendingVenue: ClubVenueDraft? = nil
    var onAddPendingVenue: (() -> Void)? = nil
    var onEditPendingVenue: (() -> Void)? = nil
    var onRemovePendingVenue: (() -> Void)? = nil

    @State private var emailError: String? = nil
    @State private var websiteError: String? = nil

    // Stripe Connect — managed by StripeConnectStatusSection
    // Subscription state (Phase 4)
    @State private var showCancelSubscriptionConfirm = false
    @State private var isCancellingSubscription = false
    @State private var paywallFeature: LockedFeature? = nil

    // Custom image upload state
    @State private var avatarPhotoItem: PhotosPickerItem? = nil
    @State private var bannerPhotoItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var isUploadingBanner = false
    @State private var avatarUploadError: String? = nil
    @State private var bannerUploadError: String? = nil

    // Crop flow state
    @State private var pendingAvatarImage: UIImage? = nil
    @State private var pendingBannerImage: UIImage? = nil
    @State private var showAvatarCrop = false
    @State private var showBannerCrop = false

    var body: some View {
        Group {
            // MARK: Club
            Section("Club") {
                TextField("Club Name", text: $draft.name)
                Toggle("Require Approval To Join", isOn: $draft.membersOnly)
            }

            // MARK: Code of Conduct
            Section {
                NavigationLink {
                    ConductEditView(text: $draft.codeOfConduct)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Code of Conduct")
                            Text(draft.codeOfConduct.isEmpty ? "Not set" : "\(draft.codeOfConduct.count) characters")
                                .font(.caption)
                                .foregroundStyle(Brand.mutedText)
                        }
                        Spacer()
                        if !draft.codeOfConduct.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Brand.pineTeal)
                                .font(.caption)
                        }
                    }
                }
            } footer: {
                Text("Members will be required to read and accept before their join request is submitted.")
            }

            // MARK: Cancellation Policy
            Section {
                NavigationLink {
                    CancellationPolicyEditView(text: $draft.cancellationPolicy)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cancellation Policy")
                            Text(draft.cancellationPolicy.isEmpty ? "Not set" : "\(draft.cancellationPolicy.count) characters")
                                .font(.caption)
                                .foregroundStyle(Brand.mutedText)
                        }
                        Spacer()
                        if !draft.cancellationPolicy.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Brand.pineTeal)
                                .font(.caption)
                        }
                    }
                }
            } footer: {
                Text("Displayed at the bottom of every game. Members must accept before joining the club.")
            }

            // MARK: Venues
            if let club {
                // Edit mode — full venue CRUD (club ID is available)
                Section {
                    ForEach(clubVenues) { venue in
                        Button {
                            onEditVenue?(venue)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(venue.venueName)
                                        .foregroundStyle(Brand.ink)
                                    if let line2 = venue.addressLine2 {
                                        Text(line2)
                                            .font(.caption)
                                            .foregroundStyle(Brand.mutedText)
                                    }
                                }
                                Spacer()
                                if venue.isPrimary {
                                    Text("Primary")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Brand.primaryText)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Brand.mutedText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            let venue = clubVenues[i]
                            Task { await appState.deleteVenue(for: club, venue: venue) }
                        }
                    }

                    Button {
                        onAddVenue?()
                    } label: {
                        Label("Add Venue", systemImage: "plus.circle")
                            .foregroundStyle(Brand.primaryText)
                    }
                } header: {
                    Text("Venues")
                } footer: {
                    if !clubVenues.isEmpty && !clubVenues.contains(where: { $0.isPrimary }) {
                        Text("No primary venue set. Mark one venue as primary — it will be pre-selected when creating games.")
                            .foregroundStyle(Brand.errorRed)
                    } else {
                        Text("Used for maps, directions, and distance. At least one primary venue is required.")
                    }
                }
            } else {
                // Create mode — no club ID yet; capture one primary venue inline
                Section {
                    if let venue = pendingVenue {
                        // Saved-draft venue card with edit + remove
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(venue.venueName)
                                    .foregroundStyle(Brand.ink)
                                let parts = [venue.streetAddress, venue.suburb]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: ", ")
                                if !parts.isEmpty {
                                    Text(parts)
                                        .font(.caption)
                                        .foregroundStyle(Brand.mutedText)
                                }
                            }
                            Spacer()
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.primaryText)
                            Button { onEditPendingVenue?() } label: {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.primaryText)
                            }
                            .buttonStyle(.plain)
                            Button { onRemovePendingVenue?() } label: {
                                Image(systemName: "minus.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.errorRed)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button { onAddPendingVenue?() } label: {
                            Label("Add Primary Venue", systemImage: "plus.circle")
                                .foregroundStyle(Brand.primaryText)
                        }
                    }
                } header: {
                    Text("Venues")
                } footer: {
                    if pendingVenue == nil {
                        Text("A primary venue is required. Add the venue used for maps, directions, and distance.")
                            .foregroundStyle(Brand.errorRed)
                    } else {
                        Text("This will become the club's primary venue — used for maps, directions, and distance.")
                    }
                }
            }

            // MARK: Club Profile Picture
            Section("Club Profile Picture") {
                // Upload custom photo
                VStack(alignment: .leading, spacing: 6) {
                    PhotosPicker(
                        selection: $avatarPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(
                            isUploadingAvatar ? "Uploading…" : "Upload Custom Photo",
                            systemImage: isUploadingAvatar ? "arrow.triangle.2.circlepath" : "photo.badge.plus"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .disabled(isUploadingAvatar || club == nil)

                    // Dimension tip
                    Text("Best size: 400 × 400 px, square crop. PNG or JPEG. Shown as a rounded tile next to your club name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if club == nil {
                        Text("Save the club first to enable custom photo upload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = avatarUploadError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    // Preview uploaded avatar
                    if let uploadedURL = draft.uploadedAvatarURL {
                        HStack(spacing: 8) {
                            AsyncImage(url: uploadedURL) { phase in
                                if case let .success(img) = phase {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.2)
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom photo uploaded")
                                    .font(.caption.weight(.semibold))
                                Button("Remove") {
                                    draft.uploadedAvatarURL = nil
                                }
                                .font(.caption)
                                .foregroundStyle(.red)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Avatar background color — shown when no custom photo is uploaded
                if draft.uploadedAvatarURL == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Avatar background colour:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            ForEach(avatarSwatchColors) { swatch in
                                Button {
                                    draft.avatarBackgroundColor = swatch.key
                                } label: {
                                    Circle()
                                        .fill(swatch.gradient)
                                        .frame(width: 38, height: 38)
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    draft.avatarBackgroundColor == swatch.key
                                                        ? Color.white : Color.clear,
                                                    lineWidth: 3
                                                )
                                        )
                                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .onChange(of: avatarPhotoItem) { _, item in
                guard let item, club?.id != nil else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { return }
                    await MainActor.run {
                        pendingAvatarImage = img
                        showAvatarCrop = true
                        avatarPhotoItem = nil
                    }
                }
            }
            .sheet(isPresented: $showAvatarCrop) {
                if let img = pendingAvatarImage, let clubID = club?.id {
                    ImageCropSheet(
                        image: img,
                        aspectRatio: 1.0,
                        title: "Crop Profile Picture",
                        onCancel: {
                            showAvatarCrop = false
                            pendingAvatarImage = nil
                        }
                    ) { cropped in
                        showAvatarCrop = false
                        pendingAvatarImage = nil
                        Task { await uploadAvatarImage(cropped, clubID: clubID) }
                    }
                }
            }

            // MARK: Club Banner
            Section("Club Banner") {
                // Upload custom banner
                VStack(alignment: .leading, spacing: 6) {
                    PhotosPicker(
                        selection: $bannerPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(
                            isUploadingBanner ? "Uploading…" : "Upload Custom Banner",
                            systemImage: isUploadingBanner ? "arrow.triangle.2.circlepath" : "photo.badge.plus"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .disabled(isUploadingBanner || club == nil)

                    // Dimension tip
                    Text("Best size: 1500 × 1000 px (3:2 ratio). PNG or JPEG. Displayed full-width at the top of your club page — avoid important content near the edges.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if club == nil {
                        Text("Save the club first to enable custom banner upload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = bannerUploadError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    // Preview uploaded banner
                    if let uploadedURL = draft.uploadedBannerURL {
                        VStack(alignment: .leading, spacing: 4) {
                            AsyncImage(url: uploadedURL) { phase in
                                if case let .success(img) = phase {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.2)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            HStack {
                                Text("Custom banner uploaded")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Button("Remove") {
                                    draft.uploadedBannerURL = nil
                                }
                                .font(.caption)
                                .foregroundStyle(.red)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Preset grid
                Text("Or choose a preset:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(["hero_1", "hero_2", "hero_3", "hero_4", "hero_5", "hero_6"], id: \.self) { key in
                        let isSelected = draft.uploadedBannerURL == nil && draft.heroImageKey == key
                        Button {
                            draft.heroImageKey = (draft.uploadedBannerURL == nil && draft.heroImageKey == key) ? nil : key
                            draft.uploadedBannerURL = nil
                        } label: {
                            Image(Self.heroImageNames[key] ?? key)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .clipped()
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isSelected ? Brand.accentGreen : Color.clear, lineWidth: 2.5)
                                )
                                .overlay(alignment: .topTrailing) {
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Brand.accentGreen)
                                            .padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onChange(of: bannerPhotoItem) { _, item in
                guard let item, club?.id != nil else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { return }
                    await MainActor.run {
                        pendingBannerImage = img
                        showBannerCrop = true
                        bannerPhotoItem = nil
                    }
                }
            }
            .sheet(isPresented: $showBannerCrop) {
                if let img = pendingBannerImage, let clubID = club?.id {
                    ImageCropSheet(
                        image: img,
                        aspectRatio: ClubHeroView.bannerAspectRatio,
                        title: "Crop Banner",
                        onCancel: {
                            showBannerCrop = false
                            pendingBannerImage = nil
                        }
                    ) { cropped in
                        showBannerCrop = false
                        pendingBannerImage = nil
                        Task { await uploadBannerImage(cropped, clubID: clubID) }
                    }
                }
            }

            // MARK: Contact
            Section("Contact") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Contact Email", text: $draft.contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .onChange(of: draft.contactEmail) { _, new in
                            emailError = (!new.isEmpty && !new.contains("@"))
                                ? "Enter a valid email address" : nil
                        }
                    if let emailError {
                        Text(emailError)
                            .font(.caption)
                            .foregroundStyle(Brand.errorRed)
                    }
                }
                TextField("Manager Name", text: $draft.managerName)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Website", text: $draft.website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: draft.website) { _, new in
                            websiteError = (!new.isEmpty && URL(string: new) == nil)
                                ? "Enter a valid URL (e.g. https://myclub.com)" : nil
                        }
                    if let websiteError {
                        Text(websiteError)
                            .font(.caption)
                            .foregroundStyle(Brand.errorRed)
                    }
                }
            }

            // MARK: Description
            Section("Description") {
                TextField("About the club", text: $draft.description, axis: .vertical)
                    .lineLimit(4...8)
            }

            // MARK: Scoring
            Section("Scoring") {
                Picker("Win Condition", selection: $draft.winCondition) {
                    ForEach(WinCondition.allCases) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }
                .pickerStyle(.menu)
                Text("Used for score recording during scheduled sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Venue (Courts)
            Section("Venue") {
                HStack {
                    Label("Default courts", systemImage: "rectangle.split.2x1")
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    HStack(spacing: 0) {
                        Button {
                            draft.defaultCourtCount = max(1, draft.defaultCourtCount - 1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(draft.defaultCourtCount > 1 ? Brand.primaryText : Brand.mutedText)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(Brand.softOutline)
                            .frame(width: 1, height: 20)

                        Text("\(draft.defaultCourtCount)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                            .frame(minWidth: 32)
                            .multilineTextAlignment(.center)

                        Rectangle()
                            .fill(Brand.softOutline)
                            .frame(width: 1, height: 20)

                        Button {
                            draft.defaultCourtCount = min(20, draft.defaultCourtCount + 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(draft.defaultCourtCount < 20 ? Brand.primaryText : Brand.mutedText)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                    .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 0.5))
                }
                Text("Auto-selected when scheduling a game at this club.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Accept Payments (edit mode only — requires a saved club ID)
            if let club {
                Section {
                    StripeConnectStatusSection(club: club)
                } header: {
                    Text("Accept Payments")
                } footer: {
                    Text("Payments require a Stripe account. Funds are transferred to your connected account after each booking.")
                }
            }

            // MARK: Plan & Billing (edit mode only)
            if let club {
            Section {
                let currentSub = appState.subscriptionsByClubID[club.id]

                if let sub = currentSub {
                    // Active subscription
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: sub.isCanceling ? "clock.badge.xmark" : (sub.isActive ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(sub.isCanceling ? .orange : (sub.isActive ? .green : .orange))
                            Text("\(sub.planDisplayName) Plan — \(sub.statusDisplayName)")
                                .font(.subheadline.weight(.semibold))
                        }
                        if let end = sub.currentPeriodEnd {
                            Text(sub.isCanceling ? "Ends \(end.formatted(.dateTime.day().month(.wide).year()))" : "Renews \(end.formatted(.dateTime.day().month(.wide).year()))")
                                .font(.caption)
                                .foregroundStyle(Brand.mutedText)
                            if sub.isCanceling {
                                Text("Paid features remain active until then.")
                                    .font(.caption)
                                    .foregroundStyle(Brand.mutedText)
                            }
                        }
                        if sub.isPastDue {
                            Text("Update your payment method to keep your plan active.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let err = appState.subscriptionError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }

                        // Upgrade Starter → Pro (not shown when cancellation is pending)
                        if sub.isActive && !sub.isCanceling && sub.planDisplayName.lowercased() == "starter" {
                            subscriptionUpgradeButton(
                                label: "Upgrade to Pro",
                                priceID: appState.subscriptionPriceID(for: "pro") ?? "",
                                club: club
                            )
                        }

                        // Cancel subscription (not shown once already canceling)
                        if !sub.isCanceling {
                        Button {
                            showCancelSubscriptionConfirm = true
                        } label: {
                            HStack {
                                if isCancellingSubscription {
                                    ProgressView().tint(.red)
                                }
                                Text(isCancellingSubscription ? "Cancelling…" : "Cancel Subscription")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(Brand.errorRed)
                            .background(Brand.errorRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Brand.errorRed.opacity(0.25), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isCancellingSubscription)
                        } // if !sub.isCanceling
                    }
                    .confirmationDialog(
                        "Cancel Subscription?",
                        isPresented: $showCancelSubscriptionConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Cancel Subscription", role: .destructive) {
                            isCancellingSubscription = true
                            Task {
                                await appState.cancelClubSubscription(for: club)
                                await appState.fetchClubSubscription(for: club.id)
                                isCancellingSubscription = false
                            }
                        }
                        Button("Keep Plan", role: .cancel) {}
                    } message: {
                        Text("Your subscription will remain active until the end of the billing period, then automatically end.")
                    }
                } else {
                    // Free tier — show upgrade options
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Free Plan")
                            .font(.subheadline.weight(.semibold))
                        Text("Upgrade to unlock additional features.")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)

                        if let err = appState.subscriptionError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }

                        HStack(spacing: 12) {
                            subscriptionUpgradeButton(label: "Starter", priceID: appState.subscriptionPriceID(for: "starter") ?? "", club: club)
                            subscriptionUpgradeButton(label: "Pro", priceID: appState.subscriptionPriceID(for: "pro") ?? "", club: club)
                        }
                    }
                }
            } header: {
                Text("Plan & Billing")
            } footer: {
                Text("Subscriptions are billed monthly. Manage billing in the Stripe Dashboard.")
            }
            .task {
                await appState.fetchClubSubscription(for: club.id)
                await appState.fetchClubEntitlements(for: club.id)
            }
            } // if let club (Plan & Billing)

        }
        .sheet(item: $paywallFeature) { feature in
            if let club {
                ClubUpgradePaywallView(club: club, lockedFeature: feature)
                    .environmentObject(appState)
            }
        }
    }

    /// Routes every plan/upgrade CTA in this billing section to the canonical paywall.
    /// `priceID` is ignored — `ClubUpgradePaywallView` is the single source of truth for
    /// plan selection, Stripe presentation, polling, and entitlement refresh.
    @ViewBuilder
    private func subscriptionUpgradeButton(label: String, priceID: String, club: Club) -> some View {
        Button {
            paywallFeature = .managePlan
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func uploadAvatarImage(_ image: UIImage, clubID: UUID) async {
        isUploadingAvatar = true
        avatarUploadError = nil
        defer { isUploadingAvatar = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            avatarUploadError = "Couldn't process image. Please try another photo."
            return
        }
        do {
            // Capture the URL being replaced before overwriting it.
            let previousURL = draft.uploadedAvatarURL
            let url = try await appState.uploadClubAvatarImage(jpeg, clubID: clubID)
            print("[ClubFormBody] Avatar uploaded → \(url.absoluteString)")
            draft.uploadedAvatarURL = url
            // Delete the previous in-session upload — it will never be saved.
            if let old = previousURL {
                Task { await appState.deleteClubStorageImageIfManaged(old) }
            }
        } catch {
            print("[ClubFormBody] Avatar upload error: \(error)")
            avatarUploadError = error.localizedDescription
        }
    }

    @MainActor
    private func uploadBannerImage(_ image: UIImage, clubID: UUID) async {
        isUploadingBanner = true
        bannerUploadError = nil
        defer { isUploadingBanner = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            bannerUploadError = "Couldn't process image. Please try another photo."
            return
        }
        do {
            // Capture the URL being replaced before overwriting it.
            let previousURL = draft.uploadedBannerURL
            let url = try await appState.uploadClubBannerImage(jpeg, clubID: clubID)
            draft.uploadedBannerURL = url
            draft.heroImageKey = nil
            // Delete the previous in-session upload — it will never be saved.
            if let old = previousURL {
                Task { await appState.deleteClubStorageImageIfManaged(old) }
            }
        } catch {
            print("[ClubFormBody] Banner upload error: \(error)")
            bannerUploadError = error.localizedDescription
        }
    }

    private var avatarSwatchColors: [AvatarGradients.Entry] { AvatarGradients.softLuxury }
}

// MARK: - Club Settings Design System

private enum CSPillTone {
    case live, ok, warn, danger, ghost, dark, accent
}

private struct CSPillView: View {
    let label: String
    let tone: CSPillTone

    private var bg: Color {
        switch tone {
        case .live:    return Brand.primaryText
        case .accent:  return Brand.accentGreen
        case .ok:      return Color(hex: "D1FAE5")
        case .warn:    return Color(hex: "FEF3C7")
        case .danger:  return Brand.errorRed.opacity(0.1)
        case .ghost:   return Brand.secondarySurface
        case .dark:    return Color(hex: "26241E")
        }
    }

    private var fg: Color {
        switch tone {
        case .live:    return Brand.accentGreen
        case .accent:  return Brand.primaryText
        case .ok:      return Color(hex: "065F46")
        case .warn:    return Color(hex: "92400E")
        case .danger:  return Brand.errorRed
        case .ghost:   return Brand.primaryText
        case .dark:    return .white
        }
    }

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(fg)
            .tracking(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
    }
}

private struct CSNavRow: View {
    let icon: String
    var iconBg: Color = Brand.secondarySurface
    var iconColor: Color = Brand.primaryText
    let label: String
    var sub: String? = nil
    var trailingPill: (label: String, tone: CSPillTone)? = nil
    var danger: Bool = false
    var divider: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(iconBg)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(danger ? Brand.errorRed : iconColor)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(danger ? Brand.errorRed : Brand.primaryText)
                    .lineLimit(1)
                if let sub {
                    Text(sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if let pill = trailingPill {
                    CSPillView(label: pill.label, tone: pill.tone)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle()
                    .fill(Brand.dividerColor)
                    .frame(height: 0.5)
                    .padding(.leading, 60)
            }
        }
    }
}

private struct CSProgressRing: View {
    let pct: Double
    var size: CGFloat = 56
    var lineWidth: CGFloat = 5
    var color: Color = Brand.accentGreen
    var trackColor: Color = Color.white.opacity(0.2)

    var body: some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(CGFloat(pct / 100), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: pct)
        }
        .frame(width: size, height: size)
    }
}

private struct CSSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Brand.secondaryText)
            .tracking(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }
}

private struct CSControlRow: View {
    let label: String
    var sub: String? = nil
    var divider: Bool = true
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                if let sub {
                    Text(sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 16)
            }
        }
    }
}

// MARK: - Auto-save pill

/// Floating "Saving… / Saved" capsule shown at the bottom of settings screens.
/// Define at module scope so both ClubOwnerSheets and MainTabView can use it.
struct AutoSavePill: View {
    let saving: Bool
    let saved: Bool

    var body: some View {
        if saving || saved {
            HStack(spacing: 6) {
                if saving {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(Brand.primaryText)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.primaryText)
                }
                Text(saving ? "Saving…" : "Saved")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Owner Edit Club Sheet

struct OwnerEditClubSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    @State private var draft: ClubOwnerEditDraft
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isSavingAuto = false
    @State private var showSavedPill = false
    @State private var isInitialLoad = true

    init(club: Club) {
        self.club = club
        _draft = State(initialValue: ClubOwnerEditDraft(club: club))
    }

    private var venues: [ClubVenue] { appState.venues(for: club) }

    private var setupChecks: [(label: String, done: Bool)] {[
        ("Name your club", !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
        ("Add a primary venue", venues.contains(where: { $0.isPrimary })),
        ("Set profile picture", draft.uploadedAvatarURL != nil || draft.avatarBackgroundColor != nil),
        ("Choose a banner", draft.heroImageKey != nil || draft.uploadedBannerURL != nil),
        ("Add a Code of Conduct", !draft.codeOfConduct.isEmpty),
    ]}

    private var setupPct: Int {
        let checks = setupChecks
        guard !checks.isEmpty else { return 100 }
        return Int(Double(checks.filter(\.done).count) / Double(checks.count) * 100)
    }

    private var isStripeConnected: Bool {
        appState.stripeAccountByClubID[club.id]?.payoutsEnabled == true
    }

    private var canAutoSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (venues.isEmpty || venues.contains(where: { $0.isPrimary }))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Error banner
                    if let err = appState.ownerToolsErrorMessage, !err.isEmpty {
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Brand.errorRed.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Club identity card
                    HStack(spacing: 12) {
                        ClubImageBadge(club: club)
                            .frame(width: 50, height: 50)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Brand.accentGreen, lineWidth: 2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name.isEmpty ? club.name : draft.name)
                                .font(.system(size: 17, weight: .black))
                                .foregroundStyle(Brand.primaryText)
                            Text("\(club.memberCount) members")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer()
                        NavigationLink {
                            ClubShareQRView(club: club).environmentObject(appState)
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(Brand.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Brand.secondarySurface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(Brand.cardBackground,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // Setup completeness
                    if setupPct < 100 {
                        NavigationLink {
                            ClubSetupChecklistView(club: club, draft: $draft)
                                .environmentObject(appState)
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    CSProgressRing(pct: Double(setupPct), size: 56, lineWidth: 5)
                                    Text("\(setupPct)%")
                                        .font(.system(size: 14, weight: .black, design: .rounded))
                                        .foregroundStyle(Brand.accentGreen)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("SETUP")
                                        .font(.system(size: 11, weight: .black))
                                        .foregroundStyle(Brand.accentGreen)
                                        .tracking(1.5)
                                    let remaining = setupChecks.filter { !$0.done }
                                    Text("\(remaining.count) step\(remaining.count == 1 ? "" : "s") to complete")
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(.white)
                                    if let next = remaining.first {
                                        Text("Next: \(next.label)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(16)
                            .background(Brand.primaryText,
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Brand.accentGreen)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(Brand.primaryText)
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Profile complete")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(.white)
                                Text("You're set up and live.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Brand.primaryText,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    // Stripe alert
                    if !isStripeConnected {
                        NavigationLink {
                            ClubPaymentsSettingsView(club: club).environmentObject(appState)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(hex: "92400E"))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Payments not connected")
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundStyle(Color(hex: "5a3a0a"))
                                    Text("Tap to set up Stripe and accept bookings")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(hex: "7a5224"))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(hex: "92400E"))
                            }
                            .padding(14)
                            .background(Color(hex: "FEF3C7"),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    // CLUB group
                    CSSectionLabel(text: "Club")
                    VStack(spacing: 0) {
                        NavigationLink {
                            ClubInfoSettingsView(draft: $draft).environmentObject(appState)
                        } label: {
                            CSNavRow(icon: "info.circle", label: "Club Info", sub: draft.name)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ClubVenuesSettingsView(club: club).environmentObject(appState)
                        } label: {
                            let primary = venues.first(where: { $0.isPrimary })
                            CSNavRow(
                                icon: "mappin.and.ellipse",
                                label: "Venues",
                                sub: "\(venues.count) venue\(venues.count == 1 ? "" : "s")" +
                                     (primary.map { " · \($0.venueName)" } ?? "")
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ClubAppearanceSettingsView(draft: $draft, club: club).environmentObject(appState)
                        } label: {
                            CSNavRow(icon: "paintpalette", label: "Appearance",
                                     sub: "Avatar, banner, accent")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ClubGamesRulesSettingsView(draft: $draft)
                        } label: {
                            CSNavRow(
                                icon: "sportscourt",
                                label: "Games & Rules",
                                sub: "\(draft.winCondition.displayName) · \(draft.defaultCourtCount) court\(draft.defaultCourtCount == 1 ? "" : "s")",
                                divider: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Brand.cardBackground,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // MEMBERS group
                    CSSectionLabel(text: "Members")
                    VStack(spacing: 0) {
                        NavigationLink {
                            ClubRolesSettingsView(club: club).environmentObject(appState)
                        } label: {
                            CSNavRow(icon: "person.2", label: "Roles & Permissions",
                                     sub: "Admins, coaches, members")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ClubNotificationsSettingsView(club: club).environmentObject(appState)
                        } label: {
                            CSNavRow(icon: "bell", label: "Notifications",
                                     sub: "Per-channel controls",
                                     trailingPill: ("Live", .live))
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ClubShareQRView(club: club).environmentObject(appState)
                        } label: {
                            CSNavRow(icon: "qrcode", label: "Share & Join Link",
                                     sub: "QR + invite link", divider: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Brand.cardBackground,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // BUSINESS group
                    CSSectionLabel(text: "Business")
                    VStack(spacing: 0) {
                        NavigationLink {
                            ClubPaymentsSettingsView(club: club).environmentObject(appState)
                        } label: {
                            CSNavRow(
                                icon: "creditcard",
                                label: "Payments",
                                sub: isStripeConnected
                                    ? "Active · \(SupabaseConfig.defaultPlatformFeeBps / 100)% fee"
                                    : "Not connected",
                                trailingPill: isStripeConnected ? ("Active", .ok) : ("Setup", .warn)
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ClubPlanBillingSettingsView(club: club).environmentObject(appState)
                        } label: {
                            let sub = appState.subscriptionsByClubID[club.id]
                            let planName = sub?.planDisplayName ?? "Free"
                            CSNavRow(
                                icon: "chart.bar.doc.horizontal",
                                label: "Plan & Billing",
                                sub: sub.map {
                                    let renew = $0.currentPeriodEnd.map {
                                        $0.formatted(.dateTime.day().month(.abbreviated).year())
                                    } ?? "—"
                                    return "\(planName) · Renews \(renew)"
                                } ?? "Free plan",
                                trailingPill: (planName, .dark),
                                divider: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Brand.cardBackground,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // DANGER group
                    CSSectionLabel(text: "Danger Zone")
                    VStack(spacing: 0) {
                        NavigationLink {
                            ClubDangerZoneSettingsView(club: club, onDeleted: { dismiss() })
                                .environmentObject(appState)
                        } label: {
                            CSNavRow(
                                icon: "trash",
                                iconBg: Brand.errorRed.opacity(0.1),
                                iconColor: Brand.errorRed,
                                label: "Delete Club",
                                sub: "Permanently remove this club",
                                danger: true,
                                divider: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Brand.cardBackground,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Text("CLUB ID · \(club.id.uuidString.prefix(8).uppercased())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Brand.tertiaryText)
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Brand.appBackground)
            .navigationTitle("Club Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await appState.refreshVenues(for: club) }
            .onAppear {
                // Suppress auto-save triggered by the initial state population
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isInitialLoad = false
                }
            }
            .onChange(of: draft) { _, _ in
                guard !isInitialLoad else { return }
                scheduleAutoSave()
            }
        }
        .tint(Brand.primaryText)
        .overlay(alignment: .bottom) {
            ZStack {
                AutoSavePill(saving: isSavingAuto, saved: showSavedPill && !isSavingAuto)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.25), value: isSavingAuto || showSavedPill)
        }
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await performAutoSave()
        }
    }

    private func performAutoSave() async {
        guard canAutoSave, !appState.isSavingClubOwnerSettings else { return }
        let oldAvatarURL = club.imageURL
        let oldBannerURL = club.customBannerURL
        await MainActor.run { isSavingAuto = true; showSavedPill = false }
        let didSave = await appState.updateClubOwnerFields(club, draft: draft)
        await MainActor.run {
            isSavingAuto = false
            guard didSave else { return }
            if draft.uploadedAvatarURL != nil {
                Task { await appState.deleteClubStorageImageIfManaged(oldAvatarURL) }
            }
            if draft.uploadedBannerURL != nil {
                Task { await appState.deleteClubStorageImageIfManaged(oldBannerURL) }
            }
            showSavedPill = true
            Task {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                await MainActor.run { showSavedPill = false }
            }
        }
    }
}

// MARK: - Club Info Settings

struct ClubInfoSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var draft: ClubOwnerEditDraft

    @State private var emailError: String?
    @State private var websiteError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CSSectionLabel(text: "Club")
                VStack(spacing: 0) {
                    HStack {
                        Text("Name")
                            .font(.system(size: 15.5, weight: .semibold))
                        Spacer()
                        TextField("Club name", text: $draft.name)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15.5, weight: .medium))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 16)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Require approval to join")
                                .font(.system(size: 15.5, weight: .semibold))
                            Text("Manually approve each new member")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer()
                        Toggle("", isOn: $draft.membersOnly)
                            .labelsHidden()
                            .tint(Brand.primaryText)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                CSSectionLabel(text: "Policies")
                VStack(spacing: 0) {
                    NavigationLink {
                        ConductEditView(text: $draft.codeOfConduct)
                    } label: {
                        CSNavRow(
                            icon: "doc.text",
                            label: "Code of Conduct",
                            sub: draft.codeOfConduct.isEmpty
                                ? "Not set" : "\(draft.codeOfConduct.count) characters",
                            trailingPill: draft.codeOfConduct.isEmpty ? nil : ("Done", .ok)
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        CancellationPolicyEditView(text: $draft.cancellationPolicy)
                    } label: {
                        CSNavRow(
                            icon: "calendar.badge.clock",
                            label: "Cancellation Policy",
                            sub: draft.cancellationPolicy.isEmpty
                                ? "Not set" : "\(draft.cancellationPolicy.count) characters",
                            trailingPill: draft.cancellationPolicy.isEmpty ? nil : ("Done", .ok),
                            divider: false
                        )
                    }
                    .buttonStyle(.plain)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Members must read and accept these before their join request is submitted. Cancellation policy displays at the bottom of every game.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)

                CSSectionLabel(text: "Contact")
                VStack(spacing: 0) {
                    csInlineField(icon: "envelope", label: "Email",
                                  binding: $draft.contactEmail, placeholder: "contact@club.com",
                                  keyboard: .emailAddress, error: emailError, divider: true)
                    .onChange(of: draft.contactEmail) { _, v in
                        emailError = (!v.isEmpty && !v.contains("@")) ? "Enter a valid email" : nil
                    }
                    csInlineField(icon: "phone", label: "Phone",
                                  binding: $draft.contactPhone, placeholder: "+61 ...",
                                  keyboard: .phonePad, divider: true)
                    csInlineField(icon: "person", label: "Manager",
                                  binding: $draft.managerName, placeholder: "Name", divider: true)
                    csInlineField(icon: "globe", label: "Website",
                                  binding: $draft.website, placeholder: "https://",
                                  keyboard: .URL, error: websiteError, divider: false)
                    .onChange(of: draft.website) { _, v in
                        websiteError = (!v.isEmpty && URL(string: v) == nil)
                            ? "Enter a valid URL (e.g. https://myclub.com)" : nil
                    }
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                CSSectionLabel(text: "Description")
                VStack(alignment: .leading, spacing: 0) {
                    TextField("About the club", text: $draft.description, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(4...10)
                        .padding(16)
                    HStack {
                        Spacer()
                        Text("\(draft.description.count) / 2000")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Brand.tertiaryText)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Club Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func csInlineField(
        icon: String, label: String, binding: Binding<String>,
        placeholder: String, keyboard: UIKeyboardType = .default,
        error: String? = nil, divider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Brand.secondarySurface)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.primaryText)
                    )
                Text(label).font(.system(size: 15.5, weight: .semibold))
                Spacer()
                TextField(placeholder, text: binding)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15.5, weight: .medium))
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Brand.errorRed)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 60)
            }
        }
    }
}

// MARK: - Club Venues Settings

struct ClubVenuesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    @State private var editingVenue: ClubVenue?
    @State private var showAddVenue = false

    private var clubVenues: [ClubVenue] { appState.venues(for: club) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    CSSectionLabel(text: "Venues")
                    Spacer()
                    Text("\(clubVenues.count) / 5")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    ForEach(Array(clubVenues.enumerated()), id: \.element.id) { idx, venue in
                        Button { editingVenue = venue } label: {
                            CSNavRow(
                                icon: "mappin.and.ellipse",
                                label: venue.venueName,
                                sub: venue.addressLine2,
                                trailingPill: venue.isPrimary ? ("Primary", .ghost) : nil,
                                divider: idx < clubVenues.count - 1 || true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showAddVenue = true } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Brand.secondarySurface)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Brand.primaryText)
                                )
                            Text("Add Venue")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(Brand.primaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !clubVenues.isEmpty && !clubVenues.contains(where: { $0.isPrimary }) {
                    Text("No primary venue set. Mark one venue as primary — it will be pre-selected when creating games.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                } else {
                    Text("Used for maps, directions, and distance. At least one primary venue is required.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Brand.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Venues")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingVenue) { venue in
            OwnerVenueFormSheet(club: club, existingVenue: venue).environmentObject(appState)
        }
        .sheet(isPresented: $showAddVenue) {
            OwnerVenueFormSheet(club: club, existingVenue: nil).environmentObject(appState)
        }
        .task { await appState.refreshVenues(for: club) }
    }
}

// MARK: - Club Appearance Settings

struct ClubAppearanceSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var draft: ClubOwnerEditDraft
    let club: Club

    @State private var avatarPhotoItem: PhotosPickerItem?
    @State private var bannerPhotoItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var isUploadingBanner = false
    @State private var avatarUploadError: String?
    @State private var bannerUploadError: String?
    @State private var pendingAvatarImage: UIImage?
    @State private var pendingBannerImage: UIImage?
    @State private var showAvatarCrop = false
    @State private var showBannerCrop = false

    private static let heroImageNames: [String: String] = [
        "hero_1": "vine_concept", "hero_2": "red_topdown", "hero_3": "blue_collage",
        "hero_4": "blue_closeup", "hero_5": "red_aerial",  "hero_6": "dark_aerial",
    ]
    private var avatarSwatchColors: [AvatarGradients.Entry] { AvatarGradients.softLuxury }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Live preview
                CSSectionLabel(text: "Preview")
                ClubImageBadge(club: club)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Brand.accentGreen, lineWidth: 2.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)

                // Profile picture
                CSSectionLabel(text: "Profile Picture")
                VStack(spacing: 0) {
                    PhotosPicker(selection: $avatarPhotoItem, matching: .images, photoLibrary: .shared()) {
                        CSNavRow(
                            icon: isUploadingAvatar ? "arrow.triangle.2.circlepath" : "photo.badge.plus",
                            label: isUploadingAvatar ? "Uploading…" : "Upload Custom Photo",
                            sub: "400×400 px · PNG or JPEG",
                            divider: draft.uploadedAvatarURL != nil || draft.uploadedAvatarURL == nil
                        )
                    }
                    .disabled(isUploadingAvatar)
                    .buttonStyle(.plain)

                    if let uploadedURL = draft.uploadedAvatarURL {
                        HStack(spacing: 12) {
                            AsyncImage(url: uploadedURL) { phase in
                                if case let .success(img) = phase { img.resizable().scaledToFill() }
                                else { Color.secondary.opacity(0.2) }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom photo uploaded")
                                    .font(.system(size: 14, weight: .semibold))
                                Button("Remove") { draft.uploadedAvatarURL = nil }
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.errorRed)
                                    .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 16)
                        }
                    }

                    if let err = avatarUploadError {
                        Text(err).font(.caption).foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                    }

                    if draft.uploadedAvatarURL == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Avatar background colour")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Brand.secondaryText)
                            HStack(spacing: 12) {
                                ForEach(avatarSwatchColors) { swatch in
                                    Button {
                                        draft.avatarBackgroundColor = swatch.key
                                    } label: {
                                        Circle()
                                            .fill(swatch.gradient)
                                            .frame(width: 40, height: 40)
                                            .overlay(
                                                Circle().stroke(
                                                    draft.avatarBackgroundColor == swatch.key
                                                        ? Brand.accentGreen : Color.clear,
                                                    lineWidth: 3
                                                )
                                            )
                                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onChange(of: avatarPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let img = UIImage(data: data) else { return }
                        await MainActor.run { pendingAvatarImage = img; showAvatarCrop = true; avatarPhotoItem = nil }
                    }
                }
                .sheet(isPresented: $showAvatarCrop) {
                    if let img = pendingAvatarImage {
                        ImageCropSheet(image: img, aspectRatio: 1.0, title: "Crop Profile Picture",
                            onCancel: { showAvatarCrop = false; pendingAvatarImage = nil }
                        ) { cropped in
                            showAvatarCrop = false; pendingAvatarImage = nil
                            Task { await uploadAvatarImage(cropped, clubID: club.id) }
                        }
                    }
                }

                // Banner
                CSSectionLabel(text: "Banner")
                VStack(spacing: 0) {
                    PhotosPicker(selection: $bannerPhotoItem, matching: .images, photoLibrary: .shared()) {
                        CSNavRow(
                            icon: isUploadingBanner ? "arrow.triangle.2.circlepath" : "photo.badge.plus",
                            label: isUploadingBanner ? "Uploading…" : "Upload Custom Banner",
                            sub: "1500×1000 px · 3:2 ratio"
                        )
                    }
                    .disabled(isUploadingBanner)
                    .buttonStyle(.plain)

                    if let uploadedURL = draft.uploadedBannerURL {
                        VStack(alignment: .leading, spacing: 4) {
                            AsyncImage(url: uploadedURL) { phase in
                                if case let .success(img) = phase { img.resizable().scaledToFill() }
                                else { Color.secondary.opacity(0.2) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 70).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            HStack {
                                Text("Custom banner uploaded")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button("Remove") { draft.uploadedBannerURL = nil }
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.errorRed)
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 16)
                        }
                    }

                    if let err = bannerUploadError {
                        Text(err).font(.caption).foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or choose a preset")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Brand.secondaryText)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(["hero_1","hero_2","hero_3","hero_4","hero_5","hero_6"], id: \.self) { key in
                                let isSelected = draft.uploadedBannerURL == nil && draft.heroImageKey == key
                                Button {
                                    draft.heroImageKey = isSelected ? nil : key
                                    draft.uploadedBannerURL = nil
                                } label: {
                                    Image(Self.heroImageNames[key] ?? key)
                                        .resizable().scaledToFill()
                                        .frame(maxWidth: .infinity).frame(height: 60).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(isSelected ? Brand.accentGreen : Color.clear,
                                                        lineWidth: 2.5)
                                        )
                                        .overlay(alignment: .topTrailing) {
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Brand.accentGreen)
                                                    .padding(4)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onChange(of: bannerPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let img = UIImage(data: data) else { return }
                        await MainActor.run { pendingBannerImage = img; showBannerCrop = true; bannerPhotoItem = nil }
                    }
                }
                .sheet(isPresented: $showBannerCrop) {
                    if let img = pendingBannerImage {
                        ImageCropSheet(image: img, aspectRatio: ClubHeroView.bannerAspectRatio,
                            title: "Crop Banner",
                            onCancel: { showBannerCrop = false; pendingBannerImage = nil }
                        ) { cropped in
                            showBannerCrop = false; pendingBannerImage = nil
                            Task { await uploadBannerImage(cropped, clubID: club.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func uploadAvatarImage(_ image: UIImage, clubID: UUID) async {
        isUploadingAvatar = true; avatarUploadError = nil
        defer { isUploadingAvatar = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            avatarUploadError = "Couldn't process image. Please try another photo."; return
        }
        do {
            let previousURL = draft.uploadedAvatarURL
            let url = try await appState.uploadClubAvatarImage(jpeg, clubID: clubID)
            draft.uploadedAvatarURL = url
            if let old = previousURL { Task { await appState.deleteClubStorageImageIfManaged(old) } }
        } catch { avatarUploadError = error.localizedDescription }
    }

    @MainActor
    private func uploadBannerImage(_ image: UIImage, clubID: UUID) async {
        isUploadingBanner = true; bannerUploadError = nil
        defer { isUploadingBanner = false }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            bannerUploadError = "Couldn't process image. Please try another photo."; return
        }
        do {
            let previousURL = draft.uploadedBannerURL
            let url = try await appState.uploadClubBannerImage(jpeg, clubID: clubID)
            draft.uploadedBannerURL = url; draft.heroImageKey = nil
            if let old = previousURL { Task { await appState.deleteClubStorageImageIfManaged(old) } }
        } catch { bannerUploadError = error.localizedDescription }
    }
}

// MARK: - Club Games & Rules Settings

struct ClubGamesRulesSettingsView: View {
    @Binding var draft: ClubOwnerEditDraft
    @State private var showWinPicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CSSectionLabel(text: "Scoring")
                VStack(spacing: 0) {
                    CSControlRow(label: "Win condition", divider: true,
                                 trailing: AnyView(
                                     Button {
                                         showWinPicker = true
                                     } label: {
                                         HStack(spacing: 4) {
                                             Text(draft.winCondition.displayName)
                                                 .font(.system(size: 15, weight: .semibold))
                                                 .foregroundStyle(Brand.primaryText)
                                             Image(systemName: "chevron.up.chevron.down")
                                                 .font(.system(size: 12, weight: .semibold))
                                                 .foregroundStyle(Brand.secondaryText)
                                         }
                                     }
                                     .buttonStyle(.plain)
                                 ))
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Used for score recording during scheduled sessions.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)

                CSSectionLabel(text: "Venue Defaults")
                VStack(spacing: 0) {
                    CSControlRow(
                        label: "Default courts",
                        sub: "Auto-selected when scheduling",
                        divider: false,
                        trailing: AnyView(
                            HStack(spacing: 0) {
                                Button {
                                    draft.defaultCourtCount = max(1, draft.defaultCourtCount - 1)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .foregroundStyle(draft.defaultCourtCount > 1
                                                         ? Brand.primaryText : Brand.tertiaryText)
                                }
                                .buttonStyle(.plain)

                                Text("\(draft.defaultCourtCount)")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Brand.primaryText)
                                    .frame(minWidth: 28)
                                    .multilineTextAlignment(.center)
                                    .overlay(
                                        HStack {
                                            Rectangle().fill(Brand.dividerColor).frame(width: 0.5)
                                            Spacer()
                                            Rectangle().fill(Brand.dividerColor).frame(width: 0.5)
                                        }
                                    )

                                Button {
                                    draft.defaultCourtCount = min(20, draft.defaultCourtCount + 1)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .foregroundStyle(draft.defaultCourtCount < 20
                                                         ? Brand.primaryText : Brand.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }
                            .background(Brand.secondarySurface, in: Capsule())
                            .overlay(Capsule().stroke(Brand.dividerColor, lineWidth: 0.5))
                        )
                    )
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Games & Rules")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if showWinPicker {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { showWinPicker = false }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 0) {
                            Capsule()
                                .fill(Brand.dividerColor)
                                .frame(width: 36, height: 4)
                                .padding(.top, 10).padding(.bottom, 12)
                            Text("Win condition")
                                .font(.system(size: 18, weight: .black))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.bottom, 12)
                            VStack(spacing: 0) {
                                ForEach(WinCondition.allCases) { condition in
                                    Button {
                                        draft.winCondition = condition
                                        showWinPicker = false
                                    } label: {
                                        HStack {
                                            Text(condition.displayName)
                                                .font(.system(size: 15.5, weight: .semibold))
                                                .foregroundStyle(Brand.primaryText)
                                            Spacer()
                                            if draft.winCondition == condition {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(Brand.primaryText)
                                            }
                                        }
                                        .padding(.horizontal, 16).padding(.vertical, 14)
                                        .overlay(alignment: .bottom) {
                                            if condition != WinCondition.allCases.last {
                                                Rectangle().fill(Brand.dividerColor)
                                                    .frame(height: 0.5).padding(.leading, 16)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(Brand.cardBackground,
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 32)
                        }
                        .background(Brand.appBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showWinPicker)
    }
}

// MARK: - Club Payments Settings

struct ClubPaymentsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    private var stripeAccount: ClubStripeAccount? { appState.stripeAccountByClubID[club.id] }
    private var isConnected: Bool { stripeAccount?.payoutsEnabled == true }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero status card
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isConnected ? "ACTIVE" : "NOT CONNECTED")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(isConnected ? Brand.accentGreen : Color(hex: "FCA43C"))
                                .tracking(1.5)
                            Text(isConnected
                                 ? "Accepting card payments"
                                 : "Connect Stripe to take bookings")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Circle()
                            .fill(isConnected ? Brand.accentGreen : Color.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: isConnected ? "checkmark" : "bolt.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(isConnected ? Brand.primaryText : .white)
                            )
                    }
                    .padding(18)

                    if isConnected {
                        HStack(spacing: 8) {
                            ForEach([
                                ("Volume (30d)", "$—"),
                                ("Bookings", "—"),
                                ("Fee", "\(SupabaseConfig.defaultPlatformFeeBps / 100)%"),
                            ], id: \.0) { stat in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stat.0)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .tracking(0.8)
                                    Text(stat.1)
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 18).padding(.bottom, 18)
                    }
                }
                .background(Brand.primaryText,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Stripe connect section
                CSSectionLabel(text: "Account")
                VStack(spacing: 0) {
                    StripeConnectStatusSection(club: club)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Payments require a Stripe account. Funds are transferred to your connected account after each booking.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Payments")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Club Plan & Billing Settings

struct ClubPlanBillingSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    @State private var showCancelSubscriptionConfirm = false
    @State private var isCancellingSubscription = false
    @State private var paywallFeature: LockedFeature? = nil

    private struct PlanDisplayRow: Identifiable {
        let id: String
        let name: String
        let price: String
        let features: [String]
    }

    private static let planFeatures: [String: [String]] = [
        "free":    ["3 active games", "20 members", "Basic scheduling"],
        "starter": ["10 active games", "100 members", "Accept paid bookings"],
        "pro":     ["Unlimited games & members", "Payments + analytics", "Recurring games"],
    ]

    private var planDisplayRows: [PlanDisplayRow] {
        var rows: [PlanDisplayRow] = [
            PlanDisplayRow(id: "free", name: "Free", price: "Free",
                           features: Self.planFeatures["free"]!)
        ]
        for serverPlan in appState.subscriptionPlans {
            rows.append(PlanDisplayRow(
                id: serverPlan.planID,
                name: serverPlan.displayName,
                price: serverPlan.displayPrice,
                features: Self.planFeatures[serverPlan.planID] ?? []
            ))
        }
        return rows
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                let currentSub = appState.subscriptionsByClubID[club.id]

                // Current plan hero
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CURRENT PLAN")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Brand.accentGreen)
                                .tracking(1.5)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(currentSub?.planDisplayName ?? "Free")
                                    .font(.system(size: 26, weight: .black))
                                    .foregroundStyle(.white)
                                Text("·")
                                    .font(.system(size: 26, weight: .black))
                                    .foregroundStyle(Brand.accentGreen)
                                Text(currentSub?.statusDisplayName ?? "Active")
                                    .font(.system(size: 26, weight: .black))
                                    .foregroundStyle(.white)
                            }
                            if let end = currentSub?.currentPeriodEnd {
                                Text("\(currentSub?.isCanceling == true ? "Ends" : "Renews") \(end.formatted(.dateTime.day().month(.abbreviated).year()))")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.6))
                            } else {
                                Text("Upgrade to unlock premium features.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        Spacer()
                        CSPillView(label: currentSub?.planDisplayName ?? "Free", tone: .accent)
                    }
                    .padding(18)

                    if currentSub?.isPastDue == true {
                        Text("Update your payment method to keep your plan active.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "FCA43C"))
                            .padding(.horizontal, 18).padding(.bottom, 16)
                    }
                }
                .background(Brand.primaryText,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Error / state messages
                if let err = appState.subscriptionError {
                    Text(err).font(.subheadline).foregroundStyle(Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Brand.errorRed.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Cancel subscription (if active and not already cancelling)
                if let sub = currentSub, !sub.isCanceling {
                    CSSectionLabel(text: "Manage")
                    VStack(spacing: 0) {
                        Button {
                            showCancelSubscriptionConfirm = true
                        } label: {
                            CSNavRow(
                                icon: "xmark.circle",
                                iconBg: Brand.errorRed.opacity(0.1),
                                iconColor: Brand.errorRed,
                                label: isCancellingSubscription ? "Cancelling…" : "Cancel Subscription",
                                sub: "Reverts to Free at period end",
                                danger: true,
                                divider: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isCancellingSubscription)
                    }
                    .background(Brand.cardBackground,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                // Plan cards
                CSSectionLabel(text: "Change Plan")
                VStack(spacing: 12) {
                    ForEach(planDisplayRows) { plan in
                        let isCurrent = (currentSub?.planDisplayName.lowercased() == plan.id)
                            || (currentSub == nil && plan.id == "free")
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(plan.name)
                                    .font(.system(size: 18, weight: .black))
                                Spacer()
                                Text(plan.price)
                                    .font(.system(size: 18, weight: .black))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(plan.features, id: \.self) { feature in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Brand.primaryText)
                                        Text(feature)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Brand.primaryText)
                                    }
                                }
                            }
                            if isCurrent {
                                CSPillView(label: "Current plan", tone: .ghost)
                            } else if let sub = currentSub,
                                      !sub.isCanceling,
                                      sub.isActive,
                                      sub.planDisplayName.lowercased() == "starter",
                                      plan.id == "pro" {
                                subscriptionUpgradeButton(label: "Upgrade to \(plan.name)",
                                                         priceID: appState.subscriptionPriceID(for: "pro") ?? "")
                            } else if currentSub == nil, plan.id != "free" {
                                subscriptionUpgradeButton(
                                    label: "Upgrade to \(plan.name)",
                                    priceID: appState.subscriptionPriceID(for: plan.id) ?? ""
                                )
                            } else if currentSub == nil, plan.id == "free" {
                                CSPillView(label: "Current plan", tone: .ghost)
                            }
                        }
                        .padding(16)
                        .background(Brand.cardBackground,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(isCurrent ? Brand.primaryText : Brand.dividerColor,
                                        lineWidth: isCurrent ? 1.5 : 0.5)
                        )
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Plan & Billing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await appState.fetchClubSubscription(for: club.id)
            await appState.fetchClubEntitlements(for: club.id)
        }
        .confirmationDialog("Cancel Subscription?", isPresented: $showCancelSubscriptionConfirm, titleVisibility: .visible) {
            Button("Cancel Subscription", role: .destructive) {
                isCancellingSubscription = true
                Task {
                    await appState.cancelClubSubscription(for: club)
                    await appState.fetchClubSubscription(for: club.id)
                    isCancellingSubscription = false
                }
            }
            Button("Keep Plan", role: .cancel) {}
        } message: {
            Text("Your subscription will remain active until the end of the billing period, then automatically end.")
        }
        .sheet(item: $paywallFeature) { feature in
            ClubUpgradePaywallView(club: club, lockedFeature: feature)
                .environmentObject(appState)
        }
    }

    /// Routes every plan card CTA in this view to the canonical paywall.
    /// `priceID` is ignored — `ClubUpgradePaywallView` is the single source of truth for
    /// plan selection, Stripe presentation, polling, and entitlement refresh.
    @ViewBuilder
    private func subscriptionUpgradeButton(label: String, priceID: String) -> some View {
        Button {
            paywallFeature = .managePlan
        } label: {
            Text(label)
                .font(.system(size: 13.5, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Club Danger Zone Settings

struct ClubDangerZoneSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club
    let onDeleted: () -> Void

    @State private var showDeleteSheet = false
    @State private var deleteConfirmText = ""

    private var canDelete: Bool { deleteConfirmText.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CSSectionLabel(text: "Permanent actions")
                VStack(spacing: 0) {
                    Button { showDeleteSheet = true } label: {
                        CSNavRow(
                            icon: "trash",
                            iconBg: Brand.errorRed.opacity(0.1),
                            iconColor: Brand.errorRed,
                            label: "Delete Club",
                            sub: "Cannot be undone",
                            danger: true,
                            divider: false
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isDeletingClub(club))
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Permanently deletes the club, all games, memberships, and posts. Members will lose access immediately. This cannot be undone.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Danger Zone")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDeleteSheet, onDismiss: { deleteConfirmText = "" }) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Brand.dividerColor)
                    .frame(width: 36, height: 4)
                    .padding(.top, 10).padding(.bottom, 16)

                Circle()
                    .fill(Brand.errorRed.opacity(0.1))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "trash")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Brand.errorRed)
                    )
                    .padding(.bottom, 14)

                Text("Delete \(club.name)?")
                    .font(.system(size: 22, weight: .black))
                    .multilineTextAlignment(.center)

                Text("This is permanent. Your \(club.memberCount) members will lose access immediately. Type **DELETE** to confirm.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Brand.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8).padding(.bottom, 18)

                HStack {
                    TextField("Type DELETE", text: $deleteConfirmText)
                        .font(.system(size: 16, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                .padding(14)
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(canDelete ? Brand.errorRed : Brand.dividerColor, lineWidth: 1.5)
                )
                .padding(.horizontal, 16).padding(.bottom, 14)

                Button {
                    guard canDelete else { return }
                    Task {
                        let deleted = await appState.deleteClub(club)
                        if deleted {
                            showDeleteSheet = false
                            onDeleted()
                        }
                    }
                } label: {
                    HStack {
                        if appState.isDeletingClub(club) { ProgressView().tint(.white) }
                        Text(appState.isDeletingClub(club) ? "Deleting…" : "Permanently delete club")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(canDelete ? Brand.errorRed : Color(hex: "f3d6d3"),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canDelete || appState.isDeletingClub(club))
                .padding(.horizontal, 16)

                Button { showDeleteSheet = false } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
    }
}

// MARK: - Club Setup Checklist

struct ClubSetupChecklistView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club
    @Binding var draft: ClubOwnerEditDraft

    private var venues: [ClubVenue] { appState.venues(for: club) }

    private var checks: [(id: String, label: String, done: Bool)] {[
        ("name",   "Name your club",       !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
        ("venue",  "Add a primary venue",  venues.contains(where: { $0.isPrimary })),
        ("avatar", "Set profile picture",  draft.uploadedAvatarURL != nil || draft.avatarBackgroundColor != nil),
        ("banner", "Choose a banner",      draft.heroImageKey != nil || draft.uploadedBannerURL != nil),
        ("cod",    "Add a Code of Conduct", !draft.codeOfConduct.isEmpty),
    ]}

    private var pct: Int {
        let c = checks
        return c.isEmpty ? 100 : Int(Double(c.filter(\.done).count) / Double(c.count) * 100)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pct == 100 ? "You're all set." : "Let's finish the basics.")
                        .font(.system(size: 28, weight: .black))
                        .lineLimit(2)
                    Text("Clubs with a complete profile get more join requests.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Brand.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

                HStack(spacing: 16) {
                    ZStack {
                        CSProgressRing(pct: Double(pct), size: 64, lineWidth: 6)
                        Text("\(pct)%")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(Brand.accentGreen)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(checks.filter(\.done).count) / \(checks.count) complete")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                        Text("Tap any item to jump there")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                }
                .padding(18)
                .background(Brand.primaryText,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { idx, check in
                        HStack(spacing: 12) {
                            if check.done {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Brand.emeraldAction)
                            } else {
                                Circle()
                                    .strokeBorder(Brand.tertiaryText, lineWidth: 2, antialiased: true)
                                    .frame(width: 22, height: 22)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.label)
                                    .font(.system(size: 15.5, weight: .semibold))
                                    .foregroundStyle(Brand.primaryText)
                                Text(check.done ? "Done" : "Tap to complete")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.tertiaryText)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if idx < checks.count - 1 {
                                Rectangle().fill(Brand.dividerColor)
                                    .frame(height: 0.5).padding(.leading, 50)
                            }
                        }
                    }
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Club Roles Settings

struct ClubRolesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    private var allMembers: [ClubOwnerMember] { appState.ownerMembers(for: club) }

    private var staffMembers: [ClubOwnerMember] {
        allMembers.filter { $0.isAdmin || $0.isOwner }
    }

    private let capabilities: [(role: String, desc: String)] = [
        ("Owner",  "Full control, billing, delete club"),
        ("Admin",  "Edit settings, manage members, schedule"),
        ("Member", "Join games, view schedule"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    CSSectionLabel(text: "Staff")
                    Spacer()
                    if !staffMembers.isEmpty {
                        Text("\(staffMembers.count) staff")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.secondaryText)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    ForEach(Array(staffMembers.enumerated()), id: \.element.id) { idx, member in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Brand.secondarySurface)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Text(initials(member.memberName))
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Brand.primaryText)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.memberName)
                                    .font(.system(size: 15.5, weight: .semibold))
                                Text(member.isOwner ? "Owner" : "Admin")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            Spacer()
                            CSPillView(label: member.isOwner ? "Owner" : "Admin",
                                       tone: member.isOwner ? .live : .ghost)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            if idx < staffMembers.count - 1 {
                                Rectangle().fill(Brand.dividerColor)
                                    .frame(height: 0.5).padding(.leading, 60)
                            }
                        }
                    }

                    if staffMembers.isEmpty {
                        Text("No staff found.")
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.secondaryText)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                CSSectionLabel(text: "What each role can do")
                VStack(spacing: 0) {
                    ForEach(Array(capabilities.enumerated()), id: \.element.role) { idx, cap in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cap.role)
                                    .font(.system(size: 15.5, weight: .semibold))
                                Text(cap.desc)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            if idx < capabilities.count - 1 {
                                Rectangle().fill(Brand.dividerColor)
                                    .frame(height: 0.5).padding(.leading, 16)
                            }
                        }
                    }
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Roles & Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await appState.refreshOwnerMembers(for: club) }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }
}

// MARK: - Club Notifications Settings

struct ClubNotificationsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    @AppStorage private var pauseAll: Bool
    @AppStorage private var notifGames: Bool
    @AppStorage private var notifJoins: Bool
    @AppStorage private var notifScores: Bool
    @AppStorage private var notifAnnouncements: Bool
    @AppStorage private var notifPayments: Bool
    @AppStorage private var notifCancellations: Bool

    init(club: Club) {
        self.club = club
        let base = "club_notif_\(club.id.uuidString)"
        _pauseAll          = AppStorage(wrappedValue: false, "\(base)_pause")
        _notifGames        = AppStorage(wrappedValue: true,  "\(base)_games")
        _notifJoins        = AppStorage(wrappedValue: true,  "\(base)_joins")
        _notifScores       = AppStorage(wrappedValue: true,  "\(base)_scores")
        _notifAnnouncements = AppStorage(wrappedValue: true, "\(base)_announcements")
        _notifPayments     = AppStorage(wrappedValue: true,  "\(base)_payments")
        _notifCancellations = AppStorage(wrappedValue: true, "\(base)_cancellations")
    }

    private let groups: [(label: String, items: [(key: String, label: String)])] = [
        ("Activity",  [("games", "New game scheduled"), ("joins", "Join requests"), ("scores", "Score updates")]),
        ("Members",   [("announcements", "Club announcements")]),
        ("Business",  [("payments", "Payment received"), ("cancellations", "Cancellations")]),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Master pause toggle
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Brand.secondarySurface)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Image(systemName: "bell.slash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Brand.primaryText)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pause everything")
                                .font(.system(size: 15.5, weight: .semibold))
                            Text(pauseAll ? "Paused" : "Live · all channels active")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer()
                        Toggle("", isOn: $pauseAll)
                            .labelsHidden()
                            .tint(Brand.primaryText)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Affects only this club. Player profile notifications stay as-is.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)

                // Per-channel groups
                CSSectionLabel(text: "Activity")
                channelCard(bindings: [
                    ("New game scheduled", $notifGames, true),
                    ("Join requests",       $notifJoins, true),
                    ("Score updates",       $notifScores, false),
                ])

                CSSectionLabel(text: "Members")
                channelCard(bindings: [
                    ("Club announcements", $notifAnnouncements, false),
                ])

                CSSectionLabel(text: "Business")
                channelCard(bindings: [
                    ("Payment received", $notifPayments, true),
                    ("Cancellations",    $notifCancellations, false),
                ])
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func channelCard(
        bindings: [(label: String, binding: Binding<Bool>, divider: Bool)]
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(bindings, id: \.label) { item in
                HStack {
                    Text(item.label)
                        .font(.system(size: 15.5, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: item.binding)
                        .labelsHidden()
                        .tint(Brand.primaryText)
                        .disabled(pauseAll)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    if item.divider {
                        Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 16)
                    }
                }
                .opacity(pauseAll ? 0.45 : 1)
            }
        }
        .background(Brand.cardBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Club Share & QR

struct ClubShareQRView: View {
    @EnvironmentObject private var appState: AppState
    let club: Club

    private var joinLink: String { "bookadink.app/c/\(club.id.uuidString.lowercased().prefix(8))" }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CSSectionLabel(text: "Scan to join")

                VStack(spacing: 16) {
                    // Decorative QR block
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                        QRPatternView(initials: clubInitials(club.name))
                            .frame(width: 220, height: 220)
                    }
                    .frame(width: 260, height: 260)
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 4) {
                        Text(club.name)
                            .font(.system(size: 17, weight: .black))
                        Text(joinLink)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Brand.secondaryText)
                    }
                }
                .padding(22)
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Actions
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = "https://\(joinLink)"
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Brand.primaryText,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    ShareLink(item: URL(string: "https://\(joinLink)")!) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Brand.primaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Brand.accentGreen,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                // Settings
                CSSectionLabel(text: "Settings")
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Public listing")
                                .font(.system(size: 15.5, weight: .semibold))
                            Text("Discoverable in search")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer()
                        Toggle("", isOn: .constant(true))
                            .labelsHidden()
                            .tint(Brand.primaryText)
                            .disabled(true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Brand.dividerColor).frame(height: 0.5).padding(.leading, 16)
                    }

                    HStack {
                        Text("Require approval")
                            .font(.system(size: 15.5, weight: .semibold))
                        Spacer()
                        Toggle("", isOn: .constant(club.membersOnly))
                            .labelsHidden()
                            .tint(Brand.primaryText)
                            .disabled(true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .background(Brand.cardBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("To change approval settings, go to Club Info.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 40)
        }
        .background(Brand.appBackground)
        .navigationTitle("Share Club")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clubInitials(_ name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }
}

private struct QRPatternView: View {
    let initials: String
    private let cells = 21

    private func isOn(_ i: Int, _ j: Int) -> Bool {
        let isCorner = (i < 7 && j < 7) || (i < 7 && j >= cells - 7) || (i >= cells - 7 && j < 7)
        if isCorner {
            let li = i < 7 ? i : i - (cells - 7)
            let lj = j < 7 ? j : j - (cells - 7)
            if li == 0 || li == 6 || lj == 0 || lj == 6 { return true }
            if li >= 2 && li <= 4 && lj >= 2 && lj <= 4 { return true }
            return false
        }
        return ((i * 7 + j * 13 + i * j) % 5) < 2
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let cell: CGFloat = size.width / CGFloat(cells)
                for i in 0..<cells {
                    for j in 0..<cells {
                        guard isOn(i, j) else { continue }
                        let centerX = CGFloat(j) * cell + cell / 2
                        let centerY = CGFloat(i) * cell + cell / 2
                        if centerX > size.width * 0.35 && centerX < size.width * 0.65
                            && centerY > size.height * 0.35 && centerY < size.height * 0.65 { continue }
                        let rect = CGRect(x: CGFloat(j) * cell + 0.5,
                                         y: CGFloat(i) * cell + 0.5,
                                         width: cell - 1, height: cell - 1)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(Brand.primaryText))
                    }
                }
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.accentGreen)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white, lineWidth: 4)
                )
                .overlay(
                    Text(initials)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(Brand.primaryText)
                )
        }
    }
}

struct PillStepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle()
                    .fill(Color(.systemGray4))
                    .frame(width: 0.5, height: 22)
                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.accentColor)
            .background(Color(.systemGray6), in: Capsule())
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(.systemGray4), lineWidth: 0.5))
        }
    }
}

// MARK: - Image Crop Sheet

private struct ImageCropSheet: View {
    let image: UIImage
    /// Width ÷ Height — 1.0 for avatar square, ClubHeroView.bannerAspectRatio for banner
    let aspectRatio: CGFloat
    let title: String
    var onCancel: (() -> Void)? = nil
    let onConfirm: (UIImage) -> Void

    // Accumulated transform
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    // Live gesture deltas
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var pinchDelta: CGFloat = 1.0

    private let cropBoxWidth: CGFloat = UIScreen.main.bounds.width - 48

    private var cropBoxHeight: CGFloat { cropBoxWidth / aspectRatio }

    /// Minimum size that fills the crop box given the image's own aspect ratio
    private var fillSize: CGSize {
        let imgAR = image.size.width / image.size.height
        if imgAR > aspectRatio {
            // image is wider than crop box — match height
            return CGSize(width: cropBoxHeight * imgAR, height: cropBoxHeight)
        } else {
            // image is taller — match width
            return CGSize(width: cropBoxWidth, height: cropBoxWidth / imgAR)
        }
    }

    private var liveScale: CGFloat { max(1.0, scale * pinchDelta) }

    private func clampedOffset(scale s: CGFloat, raw: CGSize) -> CGSize {
        let fs = fillSize
        let maxX = max(0, (fs.width * s - cropBoxWidth) / 2)
        let maxY = max(0, (fs.height * s - cropBoxHeight) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, raw.width)),
            height: min(maxY, max(-maxY, raw.height))
        )
    }

    private var liveOffset: CGSize {
        let raw = CGSize(
            width: offset.width + dragDelta.width,
            height: offset.height + dragDelta.height
        )
        return clampedOffset(scale: liveScale, raw: raw)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    // Photo
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: fillSize.width * liveScale,
                            height: fillSize.height * liveScale
                        )
                        .offset(liveOffset)

                    // Dim overlay with cut-out
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                        RoundedRectangle(cornerRadius: aspectRatio == 1.0 ? cropBoxWidth * 0.15 : 10, style: .continuous)
                            .frame(width: cropBoxWidth, height: cropBoxHeight)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    // Crop frame border
                    RoundedRectangle(cornerRadius: aspectRatio == 1.0 ? cropBoxWidth * 0.15 : 10, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .frame(width: cropBoxWidth, height: cropBoxHeight)
                        .allowsHitTesting(false)

                    // Rule-of-thirds grid
                    Canvas { ctx, size in
                        let w = cropBoxWidth, h = cropBoxHeight
                        let ox = (size.width - w) / 2, oy = (size.height - h) / 2
                        var path = Path()
                        for i in 1...2 {
                            let x = ox + w * CGFloat(i) / 3
                            path.move(to: CGPoint(x: x, y: oy))
                            path.addLine(to: CGPoint(x: x, y: oy + h))
                            let y = oy + h * CGFloat(i) / 3
                            path.move(to: CGPoint(x: ox, y: y))
                            path.addLine(to: CGPoint(x: ox + w, y: y))
                        }
                        ctx.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    DragGesture()
                        .updating($dragDelta) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let raw = CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            )
                            offset = clampedOffset(scale: liveScale, raw: raw)
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($pinchDelta) { value, state, _ in state = value }
                        .onEnded { value in
                            let newScale = max(1.0, scale * value)
                            scale = newScale
                            offset = clampedOffset(scale: newScale, raw: offset)
                        }
                )
            }
            .ignoresSafeArea()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel?()
                    }
                    .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use Photo") {
                        onConfirm(croppedImage())
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .colorScheme(.dark)
        }
    }

    private func croppedImage() -> UIImage {
        // Output width: 400 for avatar (square), 1200 for banner.
        // Output height is derived from aspectRatio so the rendered pixels
        // exactly match the crop box proportions — WYSIWYG.
        let outputWidth: CGFloat  = aspectRatio == 1.0 ? 400 : 1200
        let outputHeight: CGFloat = outputWidth / aspectRatio

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputWidth, height: outputHeight))
        return renderer.image { ctx in
            let s = liveScale
            let fs = fillSize
            // Scale image to fill output
            let scaleX = outputWidth  / cropBoxWidth
            let scaleY = outputHeight / cropBoxHeight
            let outImgW = fs.width  * s * scaleX
            let outImgH = fs.height * s * scaleY
            let centerX = outputWidth  / 2
            let centerY = outputHeight / 2
            let imgX = centerX - outImgW / 2 + liveOffset.width  * scaleX
            let imgY = centerY - outImgH / 2 + liveOffset.height * scaleY
            image.draw(in: CGRect(x: imgX, y: imgY, width: outImgW, height: outImgH))
        }
    }
}

// MARK: - Owner Venue Form Sheet

private enum VenueEntryMode {
    /// Default: user is searching for a venue or address.
    case search
    /// A place was selected and resolved — showing location summary + editable name.
    case resolved
    /// Manual fallback: user types address fields directly.
    case manual
}

struct OwnerVenueFormSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = ApplePlaceSearchService()

    let club: Club
    let existingVenue: ClubVenue?

    @State private var draft: ClubVenueDraft
    @State private var entryMode: VenueEntryMode
    @State private var searchQuery = ""

    private var isEditing: Bool { existingVenue != nil }

    /// True when an existing venue is missing coordinates — shown as a warning.
    private var hasLegacyGap: Bool {
        guard let v = existingVenue else { return false }
        return !v.hasResolvedCoordinates
    }

    init(club: Club, existingVenue: ClubVenue?) {
        self.club = club
        self.existingVenue = existingVenue
        _draft = State(initialValue: existingVenue.map { ClubVenueDraft(venue: $0) } ?? ClubVenueDraft())
        // Existing valid venue → start resolved. New or invalid → start search.
        if let v = existingVenue, v.hasResolvedCoordinates {
            _entryMode = State(initialValue: .resolved)
        } else {
            _entryMode = State(initialValue: .search)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                if hasLegacyGap {
                    Section {
                        Label("This venue is missing location data. Search for the correct address to fix it.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                switch entryMode {
                case .search:  searchContent
                case .resolved: resolvedContent
                case .manual:  manualContent
                }

                Section {
                    Toggle("Primary venue", isOn: $draft.isPrimary)
                } footer: {
                    Text("The primary venue is pre-selected when creating a game and represents this club's main location.")
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error).font(.subheadline).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Venue" : "Add Venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    saveToolbarItem
                }
            }
            .onChange(of: search.state) { _, newState in
                if case .resolved(let place) = newState {
                    applyPlace(place)
                    entryMode = .resolved
                    // Clear search state so .resolved is no longer published.
                    // PlaceSearchState.resolved always compares unequal to itself,
                    // so without this, every re-render fires onChange and resets venueName.
                    search.clear()
                }
            }
        }
    }

    // MARK: - Search content

    @ViewBuilder
    private var searchContent: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyinglass").foregroundStyle(.secondary)
                TextField("Search venue or address", text: $searchQuery)
                    .autocorrectionDisabled()
                    .onChange(of: searchQuery) { _, new in search.search(query: new) }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        switch search.state {
        case .idle:
            Section {
                manualFallbackButton
            }

        case .searching, .resolving:
            Section {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text(search.state == .resolving ? "Loading location…" : "Searching…")
                        .foregroundStyle(.secondary)
                }
            }

        case .results(let suggestions):
            if suggestions.isEmpty {
                Section {
                    Text("No results found.").foregroundStyle(.secondary)
                    manualFallbackButton
                }
            } else {
                Section("Results") {
                    ForEach(suggestions) { suggestion in
                        Button {
                            Task { await search.resolve(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section {
                    manualFallbackButton
                }
            }

        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button("Try again") {
                    searchQuery = ""
                    search.clear()
                }
                manualFallbackButton
            }

        case .resolved:
            // onChange handles this transition — nothing to render here.
            EmptyView()
        }
    }

    private var manualFallbackButton: some View {
        Button("Enter address manually") {
            entryMode = .manual
            search.clear()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Resolved content

    @ViewBuilder
    private var resolvedContent: some View {
        Section("Location") {
            VStack(alignment: .leading, spacing: 4) {
                let street = draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let locality = [draft.suburb, draft.state, draft.postcode]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !street.isEmpty {
                    Text(street).font(.subheadline)
                }
                if !locality.isEmpty {
                    Text(locality).font(.subheadline).foregroundStyle(.secondary)
                }
                if street.isEmpty && locality.isEmpty {
                    Text(draft.venueName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Button("Change location") {
                entryMode = .search
                searchQuery = ""
                search.clear()
                draft.resolvedLatitude = nil
                draft.resolvedLongitude = nil
            }
            .foregroundColor(.accentColor)
        }

        Section("Venue Name") {
            TextField("e.g. Kwinana Recreation Centre", text: $draft.venueName)
        }
    }

    // MARK: - Manual content

    @ViewBuilder
    private var manualContent: some View {
        Section {
            Button {
                entryMode = .search
                search.clear()
                searchQuery = ""
            } label: {
                Label("Search instead", systemImage: "magnifyinglass")
            }
            .foregroundColor(.accentColor)
        } footer: {
            Text("Search finds precise coordinates automatically. Manual entry geocodes the address at save time.")
        }

        Section("Venue Details") {
            TextField("Venue name", text: $draft.venueName)
            TextField("Street address", text: $draft.streetAddress)
                .onChange(of: draft.streetAddress) { _, _ in clearResolvedCoordinates() }
            TextField("Suburb", text: $draft.suburb)
                .onChange(of: draft.suburb) { _, _ in clearResolvedCoordinates() }
            HStack(spacing: 12) {
                TextField("State", text: $draft.state)
                    .onChange(of: draft.state) { _, _ in clearResolvedCoordinates() }
                TextField("Postcode", text: $draft.postcode).keyboardType(.numberPad)
                    .onChange(of: draft.postcode) { _, _ in clearResolvedCoordinates() }
            }
            Picker("Country", selection: $draft.country) {
                Text("Australia").tag("Australia")
                Text("New Zealand").tag("New Zealand")
                Text("United States").tag("United States")
                Text("United Kingdom").tag("United Kingdom")
                Text("Canada").tag("Canada")
                Text("Other").tag("Other")
            }
            .pickerStyle(.menu)
            .onChange(of: draft.country) { _, _ in clearResolvedCoordinates() }
        }
    }

    // MARK: - Save

    @ViewBuilder
    private var saveToolbarItem: some View {
        if !appState.savingClubVenueIDs.isEmpty {
            ProgressView()
        } else {
            Button {
                Task {
                    let ok: Bool
                    if let existing = existingVenue {
                        ok = await appState.updateVenue(for: club, venue: existing, draft: draft)
                    } else {
                        ok = await appState.createVenue(for: club, draft: draft)
                    }
                    if ok { dismiss() }
                }
            } label: {
                Text("Save").fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(!saveEnabled)
        }
    }

    private var saveEnabled: Bool {
        guard appState.savingClubVenueIDs.isEmpty else { return false }
        switch entryMode {
        case .resolved:
            return draft.isValid
        case .manual:
            return draft.isValid && draft.hasUsableAddress
        case .search:
            // Must select a location before saving.
            return false
        }
    }

    // MARK: - Helpers

    private func applyPlace(_ place: ResolvedPlace) {
        draft.venueName = place.name
        draft.streetAddress = place.thoroughfare ?? ""
        draft.suburb = place.locality ?? ""
        draft.state = place.administrativeArea ?? ""
        draft.postcode = place.postalCode ?? ""
        draft.country = mappedCountry(place.country)
        draft.resolvedLatitude = place.coordinate.latitude
        draft.resolvedLongitude = place.coordinate.longitude
    }

    private func mappedCountry(_ country: String?) -> String {
        let known = ["Australia", "New Zealand", "United States", "United Kingdom", "Canada"]
        guard let c = country, known.contains(c) else { return "Other" }
        return c
    }

    /// Clears pre-resolved coordinates when the user manually edits any address field.
    /// Prevents saving a mismatched pair of text address + stale search coordinates.
    private func clearResolvedCoordinates() {
        guard draft.resolvedLatitude != nil || draft.resolvedLongitude != nil else { return }
        draft.resolvedLatitude = nil
        draft.resolvedLongitude = nil
    }
}

// MARK: - Owner Manage Games View

struct OwnerManageGamesView: View {
    let club: Club
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editingGame: Game? = nil
    @State private var duplicatingGame: Game? = nil
    @State private var deleteCandidate: Game? = nil
    @State private var showDeleteConfirm = false
    @State private var cancelCandidate: Game? = nil
    @State private var showCancelConfirm = false
    @State private var viewingGame: Game? = nil
    @State private var managingPlayersFor: Game? = nil
    @State private var schedulingGame: Game? = nil
    @State private var showPastGames = false
    @State private var showCreateGame = false

    private var upcomingGames: [Game] {
        let now = Date()
        return appState.games(for: club)
            .filter { $0.dateTime >= now }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var pastGames: [Game] {
        let now = Date()
        return appState.games(for: club)
            .filter { $0.dateTime < now }
            .sorted { $0.dateTime > $1.dateTime }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Upcoming ──────────────────────────────────────────────
                if upcomingGames.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "calendar.badge.exclamationmark")
                                    .font(.system(size: 36))
                                    .foregroundStyle(Brand.mutedText)
                                Text("No upcoming games")
                                    .font(.subheadline)
                                    .foregroundStyle(Brand.mutedText)
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    }
                } else {
                    Section("Upcoming") {
                        ForEach(upcomingGames) { game in
                            upcomingGameRow(game)
                        }
                    }
                }

                // ── Past Games ────────────────────────────────────────────
                Section {
                    Button {
                        withAnimation { showPastGames.toggle() }
                    } label: {
                        HStack {
                            Label("Past Games", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.ink)
                            Spacer()
                            Text("\(pastGames.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.mutedText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Brand.secondarySurface, in: Capsule())
                            Image(systemName: showPastGames ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.mutedText)
                        }
                    }
                    .buttonStyle(.plain)

                    if showPastGames {
                        ForEach(pastGames) { game in
                            pastGameRow(game)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Manage Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateGame = true
                    } label: {
                        Image(systemName: "plus").fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                await appState.refreshGames(for: club)
                if appState.venues(for: club).isEmpty {
                    await appState.refreshVenues(for: club)
                }
                async let attendees: () = prefetchUpcomingAttendees()
                async let members: () = appState.refreshOwnerMembers(for: club)
                _ = await (attendees, members)
            }
            .refreshable {
                await appState.refreshGames(for: club)
                async let attendees: () = prefetchUpcomingAttendees()
                async let members: () = appState.refreshOwnerMembers(for: club)
                _ = await (attendees, members)
            }
        }
        .sheet(item: $viewingGame) { game in
            GameDetailView(game: game)
                .environmentObject(appState)
        }
        .sheet(item: $managingPlayersFor) { game in
            ManagePlayersView(game: game, club: club)
                .environmentObject(appState)
        }
        .sheet(item: $schedulingGame) { game in
            let confirmed = (appState.attendeesByGameID[game.id] ?? []).filter {
                if case .confirmed = $0.booking.state { return true }; return false
            }
            GameScheduleSheet(game: game, confirmedPlayers: confirmed)
        }
        .sheet(item: $editingGame) { game in
            OwnerEditGameSheet(club: club, game: game, initialVenues: appState.venues(for: club))
                .environmentObject(appState)
        }
        .sheet(item: $duplicatingGame) { game in
            let draft: ClubOwnerGameDraft = {
                var d = ClubOwnerGameDraft(game: game)
                d.startDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: game.dateTime) ?? game.dateTime
                d.repeatWeekly = false
                d.repeatCount = 1
                return d
            }()
            OwnerCreateGameSheet(club: club, initialDraft: draft)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showCreateGame) {
            OwnerCreateGameSheet(club: club)
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Cancel \"\(cancelCandidate?.title ?? "Game")\"?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel Game", role: .destructive) {
                if let game = cancelCandidate {
                    Task {
                        await appState.cancelGame(for: game)
                        cancelCandidate = nil
                    }
                }
            }
            Button("Keep Game", role: .cancel) { cancelCandidate = nil }
        } message: {
            Text("Booked players will be notified. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.title ?? "Game")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let game = deleteCandidate {
                    Task {
                        _ = await appState.deleteGameForClub(club, game: game)
                        deleteCandidate = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            let bookingCount = deleteCandidate?.confirmedCount ?? 0
            if bookingCount > 0 {
                Text("\(bookingCount) player\(bookingCount == 1 ? "" : "s") will lose their booking. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    // MARK: - Helpers

    private func prefetchUpcomingAttendees() async {
        let now = Date()
        let upcoming = appState.games(for: club).filter { $0.dateTime >= now }
        await withTaskGroup(of: Void.self) { group in
            for game in upcoming {
                group.addTask { await appState.refreshAttendees(for: game) }
            }
        }
    }

    // MARK: - Row helpers

    private static let publishFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
    }()

    private static let metaDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    private static let metaTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private func gameFillRate(_ game: Game) -> Double {
        guard let confirmed = game.confirmedCount, game.maxSpots > 0 else { return 0 }
        return min(Double(confirmed) / Double(game.maxSpots), 1.0)
    }

    private func gameFillColor(_ game: Game) -> Color {
        if game.isFull { return Brand.ink }
        guard let confirmed = game.confirmedCount else { return Brand.softOutline }
        let left = max(game.maxSpots - confirmed, 0)
        if left == 1 { return Brand.errorRed }
        if left <= 5 { return Brand.softOrangeAccent }
        return Brand.emeraldAction
    }

    private func gameFillText(_ game: Game) -> String {
        guard let confirmed = game.confirmedCount else { return "–/\(game.maxSpots)" }
        if game.isFull { return "FULL" }
        let left = max(game.maxSpots - confirmed, 0)
        return "\(confirmed)/\(game.maxSpots) • \(left) spot\(left == 1 ? "" : "s") left"
    }

    private func gameAdminInitials(_ name: String) -> String {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "?" : String(chars)
    }

    @ViewBuilder
    private func adminSignalRow(_ game: Game) -> some View {
        let hoursUntil = game.dateTime.timeIntervalSinceNow / 3600
        let hasWaitlist = (game.waitlistCount ?? 0) > 0
        let startingSoon = hoursUntil > 0 && hoursUntil < 2
        let lowFill = gameFillRate(game) < 0.5 && hoursUntil < 48 && hoursUntil > 0 && !game.isFull

        if lowFill || hasWaitlist || startingSoon {
            HStack(spacing: 5) {
                if lowFill {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.softOrangeAccent)
                }
                if hasWaitlist {
                    Image(systemName: "person.badge.clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.ink)
                }
                if startingSoon {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.errorRed)
                }
            }
        }
    }

    private func upcomingGameRow(_ game: Game) -> some View {
        let isCancelled = game.status == "cancelled"
        let venueName = game.venueName ?? club.name
        let loadedAttendees = appState.attendeesByGameID[game.id] ?? []
        let confirmedAttendees = loadedAttendees.filter {
            if case .confirmed = $0.booking.state { return true }; return false
        }
        let cancelledCount = loadedAttendees.filter {
            if case .cancelled = $0.booking.state { return true }; return false
        }.count
        let avatarPreview = Array(confirmedAttendees.prefix(3))
        let avatarOverflow = max(0, confirmedAttendees.count - 3)

        // When attendee data is loaded, derive all counts from the canonical
        // attendeesByGameID source (same as ManagePlayersView) so both surfaces
        // always agree. Fall back to denormalized game fields before first prefetch.
        let confirmedN = loadedAttendees.isEmpty ? (game.confirmedCount ?? 0) : confirmedAttendees.count
        let spotsLeft = max(game.maxSpots - confirmedN, 0)
        let isFullLive = spotsLeft == 0
        // Inline fill bar values from confirmedN so the bar and summaryText use
        // the same source — avoids the bar showing game.confirmedCount while the
        // summary line shows the live attendee-derived count.
        let fillFraction = game.maxSpots > 0 ? min(Double(confirmedN) / Double(game.maxSpots), 1.0) : 0
        let fillColor: Color = {
            if isFullLive { return Brand.ink }
            if spotsLeft == 1 { return Brand.errorRed }
            if spotsLeft <= 5 { return Brand.softOrangeAccent }
            return Brand.emeraldAction
        }()
        let fillText: String = isFullLive
            ? "FULL"
            : "\(confirmedN)/\(game.maxSpots) • \(spotsLeft) spot\(spotsLeft == 1 ? "" : "s") left"
        let summaryText: String? = loadedAttendees.isEmpty ? nil : {
            var p = ["\(confirmedN) booked"]
            if cancelledCount > 0 { p.append("\(cancelledCount) cancelled") }
            if !isFullLive { p.append("\(spotsLeft) spot\(spotsLeft == 1 ? "" : "s") left") }
            return p.joined(separator: " • ")
        }()

        return HStack(alignment: .top, spacing: 10) {
            // ── Left content ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 5) {

                // Title + status badge
                HStack(spacing: 6) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCancelled ? Brand.mutedText : Brand.ink)
                        .strikethrough(isCancelled, color: Brand.mutedText)
                        .lineLimit(1)
                    if isCancelled {
                        Text("Cancelled")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.errorRed, in: Capsule())
                    }
                    Spacer()
                }

                // Fill bar + text (skip for cancelled)
                if !isCancelled {
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(.systemGray5))
                                    .frame(height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(fillColor)
                                    .frame(width: geo.size.width * fillFraction, height: 3)
                            }
                        }
                        .frame(height: 3)

                        Text(fillText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isFullLive ? Brand.ink : Brand.mutedText)
                            .fixedSize()
                    }
                }

                // Avatar stack + booking summary (only when attendee data is already loaded)
                if !isCancelled && !loadedAttendees.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        if !avatarPreview.isEmpty {
                            HStack(spacing: -6) {
                                ForEach(avatarPreview, id: \.id) { attendee in
                                    Circle()
                                        .fill(Brand.secondarySurface)
                                        .overlay(
                                            Text(gameAdminInitials(attendee.userName))
                                                .font(.system(size: 8, weight: .semibold))
                                                .foregroundStyle(Brand.ink)
                                        )
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(Brand.cardBackground, lineWidth: 1.5))
                                }
                                if avatarOverflow > 0 {
                                    Circle()
                                        .fill(Color(.systemGray5))
                                        .overlay(
                                            Text("+\(avatarOverflow)")
                                                .font(.system(size: 7, weight: .medium))
                                                .foregroundStyle(Brand.mutedText)
                                        )
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(Brand.cardBackground, lineWidth: 1.5))
                                }
                            }
                        }
                        if let summary = summaryText {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.mutedText)
                                .lineLimit(1)
                        }
                    }
                }

                // Date · Time
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.mutedText)
                    Text("\(Self.metaDateFmt.string(from: game.dateTime)) · \(Self.metaTimeFmt.string(from: game.dateTime))")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                }

                // Venue
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.mutedText)
                    Text(venueName)
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .lineLimit(1)
                }

                // Admin signal icons
                if !isCancelled {
                    adminSignalRow(game)
                }

                // Scheduled publish badge
                if game.isScheduled, let pa = game.publishAt {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge")
                            .font(.caption2)
                        Text("Publishes \(Self.publishFmt.string(from: pa))")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.orange)
                }
            }

            // ── Right: quick action + menu ────────────────────────────────────
            HStack(spacing: 2) {
                Button {
                    if isCancelled { duplicatingGame = game } else { editingGame = game }
                } label: {
                    Image(systemName: isCancelled ? "doc.on.doc" : "square.and.pencil")
                        .font(.system(size: 16))
                        .foregroundStyle(Brand.mutedText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Menu {
                    // ── Primary ──────────────────────────────────────────────
                    Button { viewingGame = game } label: {
                        Label("View Game", systemImage: "eye")
                    }
                    Button { editingGame = game } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }

                    Divider()

                    // ── Operations ───────────────────────────────────────────
                    Button { managingPlayersFor = game } label: {
                        Label("Manage Players", systemImage: "person.3")
                    }
                    let confirmedCount = (appState.attendeesByGameID[game.id] ?? []).filter {
                        if case .confirmed = $0.booking.state { return true }; return false
                    }.count
                    if confirmedCount >= 4 {
                        Button { schedulingGame = game } label: {
                            Label("Generate Play", systemImage: "shuffle")
                        }
                    }

                    Divider()

                    // ── Lifecycle ────────────────────────────────────────────
                    Button { duplicatingGame = game } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    if !isCancelled {
                        Button(role: .destructive) {
                            cancelCandidate = game
                            showCancelConfirm = true
                        } label: {
                            Label("Cancel Game", systemImage: "xmark.circle")
                        }
                    }
                    Button(role: .destructive) {
                        deleteCandidate = game
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Game", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Brand.mutedText)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 6)
        .opacity(isCancelled ? 0.65 : 1.0)
    }

    private func pastGameRow(_ game: Game) -> some View {
        let venueName = game.venueName ?? club.name
        let isCancelled = game.status == "cancelled"
        let loadedAttendees = appState.attendeesByGameID[game.id] ?? []
        let attendedCount = loadedAttendees.filter {
            if case .confirmed = $0.booking.state { return true }; return false
        }.count
        let cancelledBookingCount = loadedAttendees.filter {
            if case .cancelled = $0.booking.state { return true }; return false
        }.count

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                        .strikethrough(isCancelled, color: Brand.tertiaryText)
                        .lineLimit(1)
                    if isCancelled {
                        Text("Cancelled")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Brand.errorRed.opacity(0.7), in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.tertiaryText)
                    Text("\(Self.metaDateFmt.string(from: game.dateTime)) · \(Self.metaTimeFmt.string(from: game.dateTime))")
                        .font(.caption)
                        .foregroundStyle(Brand.tertiaryText)
                }

                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.tertiaryText)
                    Text(venueName)
                        .font(.caption)
                        .foregroundStyle(Brand.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if !loadedAttendees.isEmpty {
                    Text("\(attendedCount) attended")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.mutedText)
                    if cancelledBookingCount > 0 {
                        Text("\(cancelledBookingCount) cancelled")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.tertiaryText)
                    }
                } else if let confirmed = game.confirmedCount {
                    Text("\(confirmed)/\(game.maxSpots)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.mutedText)
                    Text("booked")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.tertiaryText)
                }
            }
            Menu {
                Button { viewingGame = game } label: {
                    Label("View Game", systemImage: "eye")
                }
                Button { managingPlayersFor = game } label: {
                    Label("Manage Players", systemImage: "person.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.mutedText)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Conduct Edit View (pushed from Club Settings)

struct ConductEditView: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Paste your club's rules and code of conduct here.\n\nMembers will be required to read and accept these before their join request is submitted. Leave blank to skip this step.")
                    .font(.body)
                    .foregroundStyle(Color(.placeholderText))
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .padding(12)
                .focused($focused)
        }
        .navigationTitle("Code of Conduct")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Conduct Acceptance Sheet

struct ConductAcceptanceSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(Brand.pineTeal)
                    Text(club.name)
                        .font(.headline)
                        .foregroundStyle(Brand.ink)
                    Text("Code of Conduct")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()

                // Conduct text
                ScrollView {
                    Text(club.codeOfConduct ?? "")
                        .font(.body)
                        .foregroundStyle(Brand.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }

                Divider()

                // Accept / Cancel
                VStack(spacing: 12) {
                    Text("By tapping \"I Accept\", you confirm that you have read and agree to this club's code of conduct.")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .multilineTextAlignment(.center)

                    Button {
                        onAccept()
                        dismiss()
                    } label: {
                        Text("I Accept & Request to Join")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isRequestingMembership(for: club))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Before You Join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Cancellation Policy Edit View

struct CancellationPolicyEditView: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Paste your club's cancellation policy here.\n\nMembers will be required to read and accept this before their join request is submitted. It will also be displayed at the bottom of every game. Leave blank to skip this step.")
                    .font(.body)
                    .foregroundStyle(Color(.placeholderText))
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .padding(12)
                .focused($focused)
        }
        .navigationTitle("Cancellation Policy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Cancellation Policy Acceptance Sheet

struct CancellationPolicyAcceptanceSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(Brand.pineTeal)
                    Text(club.name)
                        .font(.headline)
                        .foregroundStyle(Brand.ink)
                    Text("Cancellation Policy")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.mutedText)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()

                ScrollView {
                    Text(club.cancellationPolicy ?? "")
                        .font(.body)
                        .foregroundStyle(Brand.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }

                Divider()

                VStack(spacing: 12) {
                    Text("By tapping \"I Accept\", you confirm that you have read and agree to this club's cancellation policy.")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .multilineTextAlignment(.center)

                    Button {
                        onAccept()
                        dismiss()
                    } label: {
                        Text("I Accept & Request to Join")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Brand.pineTeal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isRequestingMembership(for: club))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Before You Join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Analytics Sheet

struct AnalyticsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club

    private var isDemo: Bool {
        if case .blocked = FeatureGateService.canAccessAnalytics(appState.entitlementsByClubID[club.id]) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ClubAnalyticsDashboardView(club: club, isDemo: isDemo)
                .environmentObject(appState)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Analytics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - ProLockedRow

/// A Form row that renders like a disabled toggle but is tappable to trigger the upgrade paywall.
/// Use inside a `Section` wherever a Pro-only toggle would otherwise appear.
struct ProLockedRow: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Text("Pro")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Brand.primaryText.opacity(0.75), in: Capsule())
                // Mimic the appearance of a disabled toggle
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.mutedText)
                    .padding(.leading, 6)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Role History (audit trail)

struct OwnerRoleHistorySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club

    private var entries: [ClubRoleAuditEntry] { appState.roleHistory(for: club) }
    private var isLoading: Bool { appState.isLoadingRoleHistory(for: club) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading role history…")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No role changes yet")
                            .font(.headline)
                        Text("Promotions, demotions, and ownership transfers will show here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries) { entry in
                        RoleHistoryRow(entry: entry)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Role History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .refreshable {
                await appState.refreshClubRoleHistory(for: club)
            }
            .task {
                if entries.isEmpty {
                    await appState.refreshClubRoleHistory(for: club)
                }
            }
        }
    }
}

private struct RoleHistoryRow: View {
    let entry: ClubRoleAuditEntry

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        switch entry.changeType {
        case "promoted_to_admin":
            return "\(entry.targetName) became an admin"
        case "demoted_to_member":
            return "\(entry.targetName) was demoted to member"
        case "transferred_in":
            return "\(entry.targetName) became the owner"
        case "transferred_out_to_admin":
            return "\(entry.targetName) stepped down as owner (now admin)"
        case "transferred_out_to_member":
            return "\(entry.targetName) stepped down as owner (now member)"
        case "club_created":
            return "\(entry.targetName) created the club"
        case "member_removed_cascade":
            let role = entry.oldRole ?? "member"
            return "\(entry.targetName) was removed (was \(role))"
        case "self_relinquished":
            return "\(entry.targetName) relinquished admin access"
        default:
            return "\(entry.targetName): \(entry.changeType)"
        }
    }

    private var subline: String {
        if let actor = entry.actorUserID, actor == entry.targetUserID {
            return "by themself"
        }
        return "by \(entry.actorName)"
    }

    private var iconName: String {
        switch entry.changeType {
        case "promoted_to_admin":          return "person.badge.plus"
        case "demoted_to_member":          return "person.badge.minus"
        case "transferred_in":             return "crown.fill"
        case "transferred_out_to_admin",
             "transferred_out_to_member":  return "crown"
        case "club_created":               return "sparkles"
        case "member_removed_cascade":     return "person.fill.xmark"
        case "self_relinquished":          return "arrow.uturn.down"
        default:                           return "clock.arrow.circlepath"
        }
    }

    private var iconTint: Color {
        switch entry.changeType {
        case "promoted_to_admin", "transferred_in", "club_created": return Brand.pineTeal
        case "demoted_to_member", "transferred_out_to_admin",
             "transferred_out_to_member":                            return Brand.spicyOrange
        case "member_removed_cascade":                               return Brand.errorRed
        default:                                                     return Brand.mutedText
        }
    }
}
