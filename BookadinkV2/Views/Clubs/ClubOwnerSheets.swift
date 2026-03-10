import SwiftUI
import os

enum OwnerToolSheet: String, Identifiable {
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
                                    .actionBorder(cornerRadius: 12, color: Brand.slateBlue.opacity(0.22))

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
                                    .actionBorder(cornerRadius: 12, color: Brand.lightCyan.opacity(0.45))
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.white.opacity(0.82))
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

    init(club: Club) {
        self.club = club
        _draft = State(initialValue: ClubOwnerGameDraft())
    }

    init(club: Club, initialDraft: ClubOwnerGameDraft) {
        self.club = club
        _draft = State(initialValue: initialDraft)
    }

    private let skillOptions: [(value: String, label: String)] = [
        ("all", "All"),
        ("beginner", "Beginner"),
        ("intermediate", "Intermediate"),
        ("advanced", "Advanced")
    ]

    private let formatOptions: [(value: String, label: String)] = [
        ("open_play", "Open Play"),
        ("social", "Social"),
        ("doubles", "Doubles"),
        ("singles", "Singles"),
        ("round_robin", "Round Robin"),
        ("king_of_court", "King of the Court")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Game title", text: $draft.title)
                    TextField("Description (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(2...4)
                    DatePicker("Start", selection: $draft.startDate)
                }

                Section("Game Type") {
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

                Section("Capacity & Fee") {
                    PillStepperRow(label: "Duration: \(draft.durationMinutes) mins", value: $draft.durationMinutes, range: 30...240, step: 15)
                    PillStepperRow(label: "Max Spots: \(draft.maxSpots)", value: $draft.maxSpots, range: 2...64, step: 1)
                    TextField("Fee (optional, $)", text: $draft.feeAmountText)
                        .keyboardType(.decimalPad)
                }

                Section("Location & Rules") {
                    TextField("Location (optional)", text: $draft.location)
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Requires DUPR", isOn: $draft.requiresDUPR)
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
                    .disabled(appState.isCreatingOwnerGame)
                }
            }
        }
    }
}

struct OwnerEditGameSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    let game: Game
    @State private var draft: ClubOwnerGameDraft
    @State private var recurringEditScope: RecurringGameScope = .singleEvent

    private let skillOptions: [(value: String, label: String)] = [
        ("all", "All"),
        ("beginner", "Beginner"),
        ("intermediate", "Intermediate"),
        ("advanced", "Advanced")
    ]

    private let formatOptions: [(value: String, label: String)] = [
        ("open_play", "Open Play"),
        ("social", "Social"),
        ("doubles", "Doubles"),
        ("singles", "Singles"),
        ("round_robin", "Round Robin"),
        ("king_of_court", "King of the Court")
    ]

    init(club: Club, game: Game) {
        self.club = club
        self.game = game
        _draft = State(initialValue: ClubOwnerGameDraft(game: game))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Game title", text: $draft.title)
                    TextField("Description (optional)", text: $draft.description, axis: .vertical)
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

                Section("Game Type") {
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
                    TextField("Fee (optional, $)", text: $draft.feeAmountText)
                        .keyboardType(.decimalPad)
                }

                Section("Location & Rules") {
                    TextField("Location (optional)", text: $draft.location)
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Requires DUPR", isOn: $draft.requiresDUPR)
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
                    .disabled(appState.isOwnerSavingGame(game))
                }
            }
        }
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
                                                memberRolePill("Member", fill: Color.white.opacity(0.92), text: Brand.pineTeal)
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
                            .listRowBackground(Color.white.opacity(0.82))
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

    private var liveMember: ClubOwnerMember {
        appState.ownerMembers(for: club).first(where: { $0.userID == member.userID }) ?? member
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
                                memberRolePill("Member", fill: Color.white.opacity(0.92), text: Brand.pineTeal)
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

                Section("Owner Actions") {
                    if liveMember.isOwner {
                        Text("Owner access is protected and cannot be changed here.")
                            .foregroundStyle(.secondary)
                    } else {
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

                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            HStack {
                                Image(systemName: "person.fill.xmark")
                                Text("Remove Member")
                            }
                        }
                        .disabled(appState.isModeratingOwnerMember(liveMember.userID))

                        Button(role: .destructive) {
                            confirmBlock = true
                        } label: {
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

struct OwnerEditClubSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let club: Club
    @State private var draft: ClubOwnerEditDraft
    @State private var showSaveSuccess = false
    @State private var pendingDismissTask: Task<Void, Never>?
    @State private var showDeleteClubConfirm = false

    init(club: Club) {
        self.club = club
        _draft = State(initialValue: ClubOwnerEditDraft(club: club))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Club") {
                    TextField("Club Name", text: $draft.name)
                    TextField("Location", text: $draft.location, axis: .vertical)
                        .lineLimit(2...3)
                    Toggle("Require Approval To Join", isOn: $draft.membersOnly)
                }

                Section("Club Profile Picture") {
                    Text("Choose one of 9 profile pictures.")
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

                Section("Contact") {
                    TextField("Contact Email", text: $draft.contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Manager Name", text: $draft.managerName)
                    TextField("Website", text: $draft.website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Description") {
                    TextField("About the club", text: $draft.description, axis: .vertical)
                        .lineLimit(4...8)
                }

                if showSaveSuccess {
                    Section {
                        Label("Saved! Club settings updated.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.pineTeal)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.errorRed)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteClubConfirm = true
                    } label: {
                        HStack {
                            if appState.isDeletingClub(club) {
                                ProgressView()
                            } else {
                                Image(systemName: "trash")
                            }
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
                                await MainActor.run {
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        if appState.isSavingClubOwnerSettings {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isSaveDisabled)
                }
            }
            .onDisappear {
                pendingDismissTask?.cancel()
            }
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
        }
    }

    private var isSaveDisabled: Bool {
        appState.isSavingClubOwnerSettings || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func tileBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Brand.emeraldAction.opacity(0.12) : Color.white.opacity(0.88))
    }

    private func tileBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? Brand.emeraldAction : Brand.slateBlue.opacity(0.14), lineWidth: isSelected ? 2 : 1)
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
