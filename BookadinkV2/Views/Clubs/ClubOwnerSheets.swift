import SwiftUI
import os

enum OwnerToolSheet: String, Identifiable {
    case manageGames
    case joinRequests
    case createGame
    case editClub
    case members

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
        ("all", "All"),
        ("beginner", "Beginner (2.0–<2.5)"),
        ("intermediate", "Intermediate (2.5–<3.5)"),
        ("advanced", "Advanced (3.5+)")
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
                }

                Section("Schedule") {
                    Toggle("Repeat Weekly", isOn: $draft.repeatWeekly)
                    if draft.repeatWeekly {
                        PillStepperRow(label: "Occurrences: \(draft.repeatCount)", value: $draft.repeatCount, range: 2...12, step: 1)
                        Text("Creates a weekly series starting from the selected date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
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
                    TextField("Fee (optional, $)", text: $draft.feeAmountText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    if !savedVenues.isEmpty {
                        venuePicker(venues: savedVenues)
                    }
                    if draft.selectedVenueID == nil {
                        TextField("Venue name", text: $draft.venueName)
                        TextField("Location notes (optional)", text: $draft.location)
                    }
                    Toggle("Requires DUPR", isOn: $draft.requiresDUPR)
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
                savedVenues = appState.venues(for: club)
                if savedVenues.isEmpty {
                    await appState.refreshVenues(for: club)
                    savedVenues = appState.venues(for: club)
                }
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

    private let gameTypeOptions: [(value: String, label: String)] = [
        ("doubles", "Doubles"),
        ("singles", "Singles")
    ]

    private let skillOptions: [(value: String, label: String)] = [
        ("all", "All"),
        ("beginner", "Beginner (2.0–<2.5)"),
        ("intermediate", "Intermediate (2.5–<3.5)"),
        ("advanced", "Advanced (3.5+)")
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
                }

                Section("Capacity & Fee") {
                    PillStepperRow(label: "Duration: \(draft.durationMinutes) mins", value: $draft.durationMinutes, range: 30...240, step: 15)
                    PillStepperRow(label: "Max Spots: \(draft.maxSpots)", value: $draft.maxSpots, range: 2...64, step: 1)
                    PillStepperRow(label: "Courts: \(draft.courtCount)", value: $draft.courtCount, range: 1...20, step: 1)
                    TextField("Fee (optional, $)", text: $draft.feeAmountText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    if !savedVenues.isEmpty {
                        editVenuePicker(venues: savedVenues)
                    }
                    if draft.selectedVenueID == nil {
                        TextField("Venue name", text: $draft.venueName)
                        TextField("Location notes (optional)", text: $draft.location)
                    }
                    Toggle("Requires DUPR", isOn: $draft.requiresDUPR)
                } header: {
                    Text("Location & Rules")
                } footer: {
                    if !draft.hasVenue {
                        Text("A venue is required. Select a saved venue or enter a venue name.")
                            .foregroundStyle(Brand.errorRed)
                    }
                }

                Section {
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
                        Section {
                            Text("Tap a member to view their contact card and owner actions.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(appState.ownerMembers(for: club)) { member in
                            Button {
                                selectedMember = member
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Circle()
                                        .fill(member.isOwner ? Brand.coralBlaze.opacity(0.9) : Brand.slateBlue)
                                        .overlay(
                                            Text(initials(for: member.memberName))
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        )
                                        .frame(width: 38, height: 38)

                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Text(member.memberName)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            if member.isOwner {
                                                memberRolePill("Owner", fill: Brand.coralBlaze, text: .white)
                                            } else if member.isAdmin {
                                                memberRolePill("Admin", fill: Brand.slateBlueDark, text: .white)
                                            } else {
                                                memberRolePill("Member", fill: Brand.secondarySurface, text: Brand.primaryText)
                                            }
                                        }
                                        Text(member.isOwner ? "Tap to view protected contact card" : "Tap to view contact card and actions")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 8)

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Brand.cardBackground)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Brand.pageGradient.opacity(0.2))
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
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

struct OwnerMemberDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let club: Club
    let member: ClubOwnerMember
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var duprRatingText = ""
    @State private var duprSaved = false

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
                        placeholder: "No phone provided"
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
                        Text("No emergency contact provided")
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
                        TextField("e.g. 3.524", text: $duprRatingText)
                            .keyboardType(.decimalPad)
                        if duprSaved {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Brand.pineTeal)
                        }
                        Button("Save") {
                            guard let rating = Double(duprRatingText.trimmingCharacters(in: .whitespacesAndNewlines)),
                                  rating >= 1.0, rating <= 8.0 else { return }
                            duprSaved = false
                            Task {
                                await appState.adminUpdateMemberDUPR(liveMember, rating: rating)
                                if appState.ownerToolsErrorMessage == nil { duprSaved = true }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Brand.pineTeal)
                        .disabled(Double(duprRatingText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                } header: {
                    Text("DUPR Rating")
                } footer: {
                    if let current = liveMember.memberEmail {
                        Text("Current value on file for \(liveMember.memberName). Must be between 1.0 and 8.0.")
                    } else {
                        Text("Must be between 1.0 and 8.0.")
                    }
                }
                .onAppear {
                    // Pre-fill with whatever is on their profile if we have it
                    duprRatingText = ""
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
                            Text("Not recorded")
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

            // MARK: Display Location
            Section {
                TextField("Landmark or display name", text: $draft.venueName)
            } header: {
                Text("Display Location")
            } footer: {
                Text("Shown in the app for recognition only. Not used for maps or distance. e.g. \"Aqua Jetty, Warnbro\"")
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
                Text("Choose one of 8 profile pictures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(ClubProfileImagePresets.all) { preset in
                        Button {
                            draft.profilePicturePresetID = preset.id
                        } label: {
                            VStack(spacing: 6) {
                                ProfileAvatarArtwork(preset: preset)
                                    .frame(height: 72)
                                Text(preset.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .top)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(tileBackground(isSelected: draft.profilePicturePresetID == preset.id))
                            .overlay(tileBorder(isSelected: draft.profilePicturePresetID == preset.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // MARK: Club Banner
            Section("Club Banner") {
                Text("Choose a banner image shown at the top of your club page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(["hero_1", "hero_2", "hero_3", "hero_4", "hero_5", "hero_6"], id: \.self) { key in
                        let isSelected = draft.heroImageKey == key
                        Button {
                            draft.heroImageKey = isSelected ? nil : key
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

        }
    }

    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Brand.emeraldAction.opacity(0.12) : Brand.secondarySurface)
    }

    private func tileBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? Brand.emeraldAction : Brand.softOutline, lineWidth: isSelected ? 2 : 1)
    }
}

// MARK: - Owner Edit Club Sheet

struct OwnerEditClubSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    @State private var draft: ClubOwnerEditDraft
    @State private var showSaveSuccess = false
    @State private var pendingDismissTask: Task<Void, Never>?
    @State private var showDeleteClubConfirm = false
    @State private var editingVenue: ClubVenue? = nil
    @State private var showAddVenue = false

    init(club: Club) {
        self.club = club
        _draft = State(initialValue: ClubOwnerEditDraft(club: club))
    }

    var body: some View {
        NavigationStack {
            Form {
                ClubFormBody(
                    draft: $draft,
                    club: club,
                    onAddVenue: { showAddVenue = true },
                    onEditVenue: { editingVenue = $0 }
                )

                if showSaveSuccess {
                    Section {
                        Label("Saved! Club settings updated.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.pineTeal)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(Brand.errorRed)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteClubConfirm = true
                    } label: {
                        HStack {
                            if appState.isDeletingClub(club) { ProgressView() }
                            else { Image(systemName: "trash") }
                            Text(appState.isDeletingClub(club) ? "Deleting Club..." : "Delete Club")
                        }
                    }
                    .disabled(appState.isDeletingClub(club))
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Permanently deletes the club, all games, memberships, and posts. This cannot be undone.")
                }
            }
            .navigationTitle("Club Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            showSaveSuccess = false
                            let saved = await appState.updateClubOwnerFields(club, draft: draft)
                            guard saved else { return }
                            showSaveSuccess = true
                            pendingDismissTask?.cancel()
                            pendingDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 800_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run { dismiss() }
                            }
                        }
                    } label: {
                        if appState.isSavingClubOwnerSettings { ProgressView() }
                        else { Text("Save").fontWeight(.semibold) }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaveDisabled)
                }
            }
            .onDisappear { pendingDismissTask?.cancel() }
            .confirmationDialog(
                "Delete \"\(club.name)\"?",
                isPresented: $showDeleteClubConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Club Permanently", role: .destructive) {
                    Task {
                        let deleted = await appState.deleteClub(club)
                        if deleted { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All games, memberships, and posts will be permanently deleted. This cannot be undone.")
            }
            .sheet(item: $editingVenue) { venue in
                OwnerVenueFormSheet(club: club, existingVenue: venue).environmentObject(appState)
            }
            .sheet(isPresented: $showAddVenue) {
                OwnerVenueFormSheet(club: club, existingVenue: nil).environmentObject(appState)
            }
            .task { await appState.refreshVenues(for: club) }
        }
    }

    private var isSaveDisabled: Bool {
        appState.isSavingClubOwnerSettings
            || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !hasPrimaryVenue
    }

    /// Returns false only when venues have loaded AND none is marked primary.
    /// An empty list is treated as "not yet loaded" to avoid blocking during the initial fetch.
    private var hasPrimaryVenue: Bool {
        let venues = appState.venues(for: club)
        guard !venues.isEmpty else { return true }
        return venues.contains(where: { $0.isPrimary })
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

// MARK: - Owner Venue Form Sheet

struct OwnerVenueFormSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    let existingVenue: ClubVenue?

    @State private var draft: ClubVenueDraft

    init(club: Club, existingVenue: ClubVenue?) {
        self.club = club
        self.existingVenue = existingVenue
        _draft = State(initialValue: existingVenue.map { ClubVenueDraft(venue: $0) } ?? ClubVenueDraft())
    }

    private var isEditing: Bool { existingVenue != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Venue Details") {
                    TextField("Venue name", text: $draft.venueName)
                    TextField("Street address", text: $draft.streetAddress)
                    TextField("Suburb", text: $draft.suburb)
                    HStack(spacing: 12) {
                        TextField("State", text: $draft.state)
                        TextField("Postcode", text: $draft.postcode)
                            .keyboardType(.numberPad)
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
                }

                Section {
                    Toggle("Primary venue", isOn: $draft.isPrimary)
                } footer: {
                    Text("The primary venue is pre-selected when creating a game.")
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red)
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
                        let isBusy = !appState.savingClubVenueIDs.isEmpty
                        if isBusy {
                            ProgressView()
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!draft.isValid || !appState.savingClubVenueIDs.isEmpty)
                }
            }
        }
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
    @State private var showPastGames = false

    private var upcomingGames: [Game] {
        let today = Calendar.current.startOfDay(for: Date())
        return appState.games(for: club)
            .filter { Calendar.current.startOfDay(for: $0.dateTime) >= today }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var pastGames: [Game] {
        let today = Calendar.current.startOfDay(for: Date())
        return appState.games(for: club)
            .filter { Calendar.current.startOfDay(for: $0.dateTime) < today }
            .sorted { $0.dateTime > $1.dateTime } // most recent first
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
                            NavigationLink(value: game) {
                                pastGameRow(game)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Manage Games")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Game.self) { game in
                GameDetailView(game: game)
                    .environmentObject(appState)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "plus").fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                if appState.venues(for: club).isEmpty {
                    await appState.refreshVenues(for: club)
                }
            }
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
            Text("This cannot be undone.")
        }
        .onAppear {
            Task { await appState.refreshGames(for: club) }
        }
    }

    // MARK: - Row helpers

    private static let publishFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
    }()

    private func upcomingGameRow(_ game: Game) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Text(game.dateTime.formatted(
                    .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                ))
                .font(.caption)
                .foregroundStyle(Brand.mutedText)
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
            Spacer()
            Menu {
                Button { editingGame = game } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                Button { duplicatingGame = game } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    deleteCandidate = game
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.mutedText)
            }
        }
        .padding(.vertical, 4)
    }

    private func pastGameRow(_ game: Game) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                Text(game.dateTime.formatted(
                    .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                ))
                .font(.caption)
                .foregroundStyle(Brand.mutedText)
            }
            Spacer()
            // Quick attendance summary from confirmed count
            if let confirmed = game.confirmedCount {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(confirmed)/\(game.maxSpots)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    Text("booked")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.mutedText)
                }
            }
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 16))
                .foregroundStyle(Brand.mutedText)
        }
        .padding(.vertical, 4)
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
