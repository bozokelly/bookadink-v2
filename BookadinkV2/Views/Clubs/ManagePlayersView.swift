import SwiftUI

struct ManagePlayersView: View {
    let game: Game
    let club: Club
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var addPlayerSearch: String = ""
    @State private var showAddPlayerSheet = false

    // MARK: - Computed attendee sets

    private var currentGame: Game {
        appState.gamesByClubID[game.clubID]?.first(where: { $0.id == game.id }) ?? game
    }

    private var allAttendees: [GameAttendee] {
        appState.gameAttendees(for: game)
    }

    private var confirmedAttendees: [GameAttendee] {
        allAttendees
            .filter { if case .confirmed = $0.booking.state { return true } else { return false } }
            .sorted { ($0.booking.createdAt ?? .distantFuture) < ($1.booking.createdAt ?? .distantFuture) }
    }

    private var pendingPaymentAttendees: [GameAttendee] {
        allAttendees
            .filter { if case .pendingPayment = $0.booking.state { return true } else { return false } }
            .sorted { ($0.booking.createdAt ?? .distantFuture) < ($1.booking.createdAt ?? .distantFuture) }
    }

    private var waitlistedAttendees: [GameAttendee] {
        allAttendees
            .filter { if case .waitlisted = $0.booking.state { return true } else { return false } }
            .sorted { a, b in
                let posA: Int
                if case .waitlisted(let p) = a.booking.state { posA = p ?? Int.max } else { posA = Int.max }
                let posB: Int
                if case .waitlisted(let p) = b.booking.state { posB = p ?? Int.max } else { posB = Int.max }
                if posA != posB { return posA < posB }
                return (a.booking.createdAt ?? .distantFuture) < (b.booking.createdAt ?? .distantFuture)
            }
    }

    private var cancelledAttendees: [GameAttendee] {
        allAttendees
            .filter { if case .cancelled = $0.booking.state { return true } else { return false } }
            .sorted { ($0.booking.createdAt ?? .distantFuture) < ($1.booking.createdAt ?? .distantFuture) }
    }

    private var checkedInCount: Int {
        confirmedAttendees.filter { appState.isCheckedIn(bookingID: $0.booking.id) }.count
    }

    private var waitlistTotal: Int {
        waitlistedAttendees.count + pendingPaymentAttendees.count
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryStrip
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                // Confirmed
                Section {
                    if confirmedAttendees.isEmpty {
                        Text("No confirmed players yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Brand.cardBackground)
                    } else {
                        ForEach(confirmedAttendees) { attendee in
                            playerRow(attendee)
                                .listRowBackground(Brand.cardBackground)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                } header: {
                    sectionLabel(
                        "Confirmed",
                        count: confirmedAttendees.count,
                        color: Brand.emeraldAction
                    )
                }

                // Waitlist
                if waitlistTotal > 0 {
                    Section {
                        ForEach(pendingPaymentAttendees) { attendee in
                            playerRow(attendee, isPendingPayment: true)
                                .listRowBackground(Brand.cardBackground)
                                .listRowInsets(EdgeInsets())
                        }
                        ForEach(Array(waitlistedAttendees.enumerated()), id: \.element.id) { index, attendee in
                            playerRow(attendee, waitlistPos: index + 1)
                                .listRowBackground(Brand.cardBackground)
                                .listRowInsets(EdgeInsets())
                        }
                    } header: {
                        sectionLabel("Waitlist", count: waitlistTotal, color: Brand.spicyOrange)
                    }
                }

                // Cancelled
                if !cancelledAttendees.isEmpty {
                    Section {
                        ForEach(cancelledAttendees) { attendee in
                            cancelledRow(attendee)
                                .listRowBackground(Brand.cardBackground)
                                .listRowInsets(EdgeInsets())
                        }
                    } header: {
                        sectionLabel("Cancelled", count: cancelledAttendees.count, color: Brand.mutedText)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.pageGradient.ignoresSafeArea())
            .navigationTitle("Manage Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addPlayerSearch = ""
                        showAddPlayerSheet = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .fontWeight(.semibold)
                    }
                }
            }
            .task { await appState.refreshAttendees(for: game) }
            .refreshable { await appState.refreshAttendees(for: game) }
        }
        .sheet(isPresented: $showAddPlayerSheet) { addPlayerSheet }
    }

    // MARK: - Summary Strip

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            statCell(
                value: "\(confirmedAttendees.count)/\(currentGame.maxSpots)",
                label: "Booked",
                color: confirmedAttendees.count >= currentGame.maxSpots ? Brand.ink : Brand.emeraldAction
            )
            Divider().frame(height: 28)
            statCell(
                value: "\(waitlistTotal)",
                label: "Waitlist",
                color: waitlistTotal > 0 ? Brand.spicyOrange : Brand.mutedText
            )
            if currentGame.startsInPast {
                Divider().frame(height: 28)
                statCell(
                    value: "\(checkedInCount)",
                    label: "Attended",
                    color: checkedInCount > 0 ? Brand.pineTeal : Brand.mutedText
                )
            }
            Divider().frame(height: 28)
            statCell(
                value: "\(cancelledAttendees.count)",
                label: "Cancelled",
                color: cancelledAttendees.count > 0 ? Brand.errorRed.opacity(0.75) : Brand.mutedText
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    private func statCell(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Brand.mutedText)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionLabel(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .tracking(0.6)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1), in: Capsule())
        }
    }

    // MARK: - Player Row (Confirmed + Waitlist)

    private func playerRow(
        _ attendee: GameAttendee,
        waitlistPos: Int? = nil,
        isPendingPayment: Bool = false
    ) -> some View {
        let isChecked = appState.isCheckedIn(bookingID: attendee.booking.id)
        let isBusy = appState.isUpdatingOwnerBooking(attendee.booking.id)
        let isWaitlisted = waitlistPos != nil || isPendingPayment

        return HStack(alignment: .center, spacing: 12) {
            initialsCircle(attendee.userName, colorKey: attendee.avatarColorKey, size: 36, dim: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(attendee.userName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                if let doubles = attendee.duprRating {
                    Text("DUPR \(String(format: "%.3f", doubles))")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                } else if let email = attendee.userEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if isPendingPayment {
                    playerBadge("Awaiting Payment",
                                fill: Brand.spicyOrange.opacity(0.1),
                                text: Brand.spicyOrange)
                } else if let pos = waitlistPos {
                    playerBadge("#\(pos)", fill: Brand.secondarySurface, text: Brand.mutedText)
                }

                if !currentGame.startsInPast {
                    // Upcoming game controls
                    if !isWaitlisted, let fee = currentGame.feeAmount, fee > 0 {
                        paymentBadge(attendee)
                    }
                    if !isWaitlisted {
                        CheckInConfettiButton(isCheckedIn: isChecked, isBusy: isBusy) {
                            let status: String? = isChecked ? nil : "attended"
                            Task { await appState.setAttendance(for: game, attendee: attendee, status: status) }
                        }
                    }
                    upcomingActionMenu(attendee, isWaitlisted: isWaitlisted, waitlistPos: waitlistPos, isPendingPayment: isPendingPayment, isBusy: isBusy)
                } else {
                    // Past game controls
                    pastAttendanceMenu(attendee, isBusy: isBusy)
                    if isChecked {
                        pastPaymentMenu(attendee)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func upcomingActionMenu(
        _ attendee: GameAttendee,
        isWaitlisted: Bool,
        waitlistPos: Int?,
        isPendingPayment: Bool,
        isBusy: Bool
    ) -> some View {
        Menu {
            if !isWaitlisted {
                Button {
                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .waitlisted(position: nil)) }
                } label: { Label("Move to Waitlist", systemImage: "clock.badge") }
            } else if isPendingPayment {
                Button {
                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .confirmed) }
                } label: { Label("Confirm Player", systemImage: "checkmark.circle.fill") }
            } else if waitlistPos != nil {
                Button {
                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .confirmed) }
                } label: { Label("Promote to Confirmed", systemImage: "arrow.up.circle.fill") }
                Button {
                    Task { await appState.ownerMoveWaitlistAttendee(for: game, attendee: attendee, directionUp: true) }
                } label: { Label("Move Up", systemImage: "arrow.up") }
                Button {
                    Task { await appState.ownerMoveWaitlistAttendee(for: game, attendee: attendee, directionUp: false) }
                } label: { Label("Move Down", systemImage: "arrow.down") }
            }
            Divider()
            Button(role: .destructive) {
                Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .cancelled) }
            } label: { Label("Cancel Booking", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.mutedText)
                .frame(width: 32, height: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    @ViewBuilder
    private func pastAttendanceMenu(_ attendee: GameAttendee, isBusy: Bool) -> some View {
        let aStatus = appState.attendanceStatus(bookingID: attendee.booking.id)
        Menu {
            Button {
                Task { await appState.setAttendance(for: game, attendee: attendee, status: "attended") }
            } label: { Label("Attended", systemImage: "checkmark.circle.fill") }
            Button {
                Task { await appState.setAttendance(for: game, attendee: attendee, status: "no_show") }
            } label: { Label("No Show", systemImage: "xmark.circle") }
            if aStatus != "unmarked" {
                Divider()
                Button {
                    Task { await appState.setAttendance(for: game, attendee: attendee, status: nil) }
                } label: { Label("Remove", systemImage: "minus.circle") }
            }
        } label: {
            Image(systemName: aStatus == "no_show" ? "xmark" : "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(
                    aStatus == "attended" ? Color.black :
                    (aStatus == "no_show" ? Color.white : Color(UIColor.tertiaryLabel))
                )
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(
                        aStatus == "attended" ? Color(hex: "80FF00") :
                        (aStatus == "no_show" ? Brand.errorRed : Color(UIColor.tertiarySystemFill))
                    )
                )
                .overlay(
                    Circle().stroke(
                        aStatus == "attended" ? Color(hex: "80FF00") :
                        (aStatus == "no_show" ? Brand.errorRed : Color(UIColor.separator)),
                        lineWidth: 1
                    )
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    @ViewBuilder
    private func pastPaymentMenu(_ attendee: GameAttendee) -> some View {
        let pStatus = appState.paymentStatus(for: attendee.booking.id)
        Menu {
            Button {
                Task { await appState.updatePaymentStatus(for: game, attendee: attendee, status: "unpaid") }
            } label: { Label("Unpaid", systemImage: "xmark.circle") }
            Button {
                Task { await appState.updatePaymentStatus(for: game, attendee: attendee, status: "cash") }
            } label: { Label("Cash", systemImage: "banknote") }
            Button {
                Task { await appState.updatePaymentStatus(for: game, attendee: attendee, status: "stripe") }
            } label: { Label("Card / Stripe", systemImage: "creditcard") }
        } label: {
            paymentStatusBadge(pStatus)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    // MARK: - Cancelled Row

    private func cancelledRow(_ attendee: GameAttendee) -> some View {
        HStack(spacing: 12) {
            initialsCircle(attendee.userName, colorKey: attendee.avatarColorKey, size: 36, dim: true)
            Text(attendee.userName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.mutedText)
                .lineLimit(1)
            Spacer()
            playerBadge("Cancelled", fill: Brand.errorRed.opacity(0.08), text: Brand.errorRed.opacity(0.65))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(0.8)
    }

    // MARK: - Payment Badges

    @ViewBuilder
    private func paymentBadge(_ attendee: GameAttendee) -> some View {
        let method = attendee.booking.paymentMethod
        if method == "stripe" || method == "credits" {
            HStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Brand.mutedText)
                playerBadge(
                    method == "credits" ? "Credits" : "Card",
                    fill: Brand.slateBlue.opacity(0.12),
                    text: Brand.slateBlue
                )
            }
        } else {
            let label: String = method == "cash" ? "Cash" : "Unpaid"
            let fill: Color = method == "cash" ? Color.green.opacity(0.12) : Brand.spicyOrange.opacity(0.09)
            let text: Color = method == "cash" ? Color(hex: "1A6B2E") : Brand.spicyOrange.opacity(0.85)
            Menu {
                Button {
                    Task { await appState.updateBookingPaymentMethod(for: game, attendee: attendee, method: "cash") }
                } label: { Label("Mark as Cash", systemImage: "banknote") }
                Button {
                    Task { await appState.updateBookingPaymentMethod(for: game, attendee: attendee, method: "stripe") }
                } label: { Label("Mark as Card", systemImage: "creditcard") }
                Divider()
                Button(role: .destructive) {
                    Task { await appState.updateBookingPaymentMethod(for: game, attendee: attendee, method: "admin") }
                } label: { Label("Mark as Unpaid", systemImage: "xmark.circle") }
            } label: {
                playerBadge(label, fill: fill, text: text)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func paymentStatusBadge(_ status: String) -> some View {
        switch status {
        case "cash":
            playerBadge("Cash", fill: Brand.pineTeal.opacity(0.12), text: Brand.pineTeal)
        case "stripe":
            playerBadge("Card", fill: Brand.slateBlue.opacity(0.12), text: Brand.slateBlue)
        case "credits":
            playerBadge("Credits", fill: Brand.slateBlue.opacity(0.12), text: Brand.slateBlue)
        default:
            playerBadge("Unpaid", fill: Brand.spicyOrange.opacity(0.09), text: Brand.spicyOrange.opacity(0.85))
        }
    }

    private func playerBadge(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
    }

    private func initialsCircle(_ name: String, colorKey: String?, size: CGFloat, dim: Bool) -> some View {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        let text = chars.isEmpty ? "?" : String(chars)
        // Avatar colour is identity data. Do not derive per-view.
        let gradient = AvatarGradients.resolveGradient(forKey: colorKey)
        return Circle()
            .fill(gradient.opacity(dim ? 0.5 : 1))
            .overlay(
                Text(text)
                    .font(.system(size: size * 0.33, weight: .semibold))
                    .foregroundStyle(.white.opacity(dim ? 0.7 : 1))
            )
            .frame(width: size, height: size)
    }

    // MARK: - Add Player Sheet

    private var addPlayerSheet: some View {
        AddPlayerSheet(game: game, club: club, isPresented: $showAddPlayerSheet)
            .environmentObject(appState)
    }
}

// MARK: - Add Player Sheet (extracted to avoid ViewBuilder type-inference limits)

private struct AddPlayerSheet: View {
    let game: Game
    let club: Club
    @Binding var isPresented: Bool
    @EnvironmentObject private var appState: AppState
    @State private var search: String = ""

    private var allMembers: [ClubOwnerMember] { appState.ownerMembers(for: club) }

    private var existingUserIDs: Set<UUID> {
        Set(
            appState.gameAttendees(for: game)
                .filter {
                    switch $0.booking.state {
                    case .confirmed, .waitlisted: return true
                    default: return false
                    }
                }
                .compactMap { $0.booking.userID }
        )
    }

    private var selfEntry: ClubOwnerMember? {
        guard let userID = appState.authUserID,
              let profile = appState.profile,
              !existingUserIDs.contains(userID),
              !allMembers.contains(where: { $0.userID == userID })
        else { return nil }
        return ClubOwnerMember(
            membershipRecordID: UUID(),
            userID: userID,
            clubID: game.clubID,
            membershipStatus: .approved,
            memberName: profile.fullName.isEmpty ? "Me" : profile.fullName,
            memberEmail: profile.email.isEmpty ? nil : profile.email,
            memberPhone: profile.phone,
            emergencyContactName: nil,
            emergencyContactPhone: nil,
            isAdmin: true,
            isOwner: true,
            adminRole: .owner,
            conductAcceptedAt: nil,
            cancellationPolicyAcceptedAt: nil,
            duprRating: profile.duprRating,
            duprUpdatedAt: nil,
            duprUpdatedByName: nil,
            avatarColorKey: profile.avatarColorKey
        )
    }

    private var bookableMembers: [ClubOwnerMember] {
        (selfEntry.map { [$0] } ?? []) + allMembers.filter {
            $0.membershipStatus == .approved && !existingUserIDs.contains($0.userID)
        }
    }

    private var filtered: [ClubOwnerMember] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return bookableMembers }
        return bookableMembers.filter {
            $0.memberName.localizedCaseInsensitiveContains(trimmed) ||
            ($0.memberEmail?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let info = appState.gameOwnerInfoByID[game.id], !info.isEmpty {
                    Text(info)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Brand.pineTeal.opacity(0.08))
                }
                if let error = appState.gameOwnerErrorByID[game.id], !error.isEmpty {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Brand.errorRed.opacity(0.08))
                }
                List {
                    if filtered.isEmpty {
                        Text(bookableMembers.isEmpty
                             ? "All club members are already in this game."
                             : "No members match your search.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filtered) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.memberName).font(.subheadline.weight(.semibold))
                                    if let email = member.memberEmail {
                                        Text(email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    Task { await appState.ownerAddPlayerToGame(member, game: game) }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Brand.emeraldAction)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $search,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search members")
            }
            .navigationTitle("Add Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                        .fontWeight(.semibold)
                }
            }
            .task { await appState.refreshAttendees(for: game) }
        }
    }
}
