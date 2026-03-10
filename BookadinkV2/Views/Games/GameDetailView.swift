import SwiftUI

struct GameDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    let game: Game
    @State private var showDUPRBookingSheet = false
    @State private var showScheduleSheet = false
    @State private var showAddPlayerSheet = false
    @State private var addPlayerSearch = ""
    @State private var duprIDDraft = ""
    @State private var duprDoublesRatingText = ""
    @State private var duprSinglesRatingText = ""
    @State private var duprBookingConfirmed = false
    @State private var duprSheetErrorMessage: String? = nil
    
    private var clubName: String? {
        appState.clubs.first(where: { $0.id == game.clubID })?.name
    }

    private var clubForGame: Club? {
        appState.clubs.first(where: { $0.id == game.clubID })
    }

    private var isClubAdminUser: Bool {
        guard let club = clubForGame else { return false }
        return appState.isClubAdmin(for: club)
    }

    private var canViewAttendees: Bool {
        guard let club = clubForGame else { return false }
        if isClubAdminUser { return true }
        if appState.bookingState(for: game).canCancel { return true }
        let membership = appState.membershipState(for: club)
        switch membership {
        case .approved, .unknown:
            return true
        case .none, .pending, .rejected:
            return false
        }
    }

    private var canBookGameByClubMembership: Bool {
        guard let club = clubForGame else { return true }
        if appState.isClubAdmin(for: club) { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown:
            return true
        case .none, .pending, .rejected:
            return false
        }
    }

    private var bookingMembershipRequirementMessage: String? {
        guard let club = clubForGame else { return nil }
        let state = appState.membershipState(for: club)
        guard appState.bookingState(for: game).canBook, !canBookGameByClubMembership else { return nil }
        switch state {
        case .pending:
            return "Your club join request is pending. You can book after approval."
        case .none, .rejected:
            return "Join the club to book this game."
        case .approved, .unknown:
            return nil
        }
    }

    private var gameLocationNavigationQuery: String {
        if let club = clubForGame {
            let pieces = [
                game.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                club.name,
                club.address
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

            if !pieces.isEmpty {
                return pieces.joined(separator: ", ")
            }
        }
        return game.displayLocation
    }

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    bookingActionCard
                    if canViewAttendees {
                        attendeesCard
                    }
                    detailsCard
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .clipped()
        }
        .navigationTitle("Game Details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: game.id) {
            if canViewAttendees {
                await appState.refreshAttendees(for: game)
            }
            if let club = clubForGame, appState.authState == .signedIn {
                await appState.refreshClubAdminRole(for: club)
                if appState.isClubAdmin(for: club) {
                    await appState.refreshOwnerMembers(for: club)
                }
            }
        }
        .sheet(isPresented: $showDUPRBookingSheet) {
            duprBookingSheet
        }
        .sheet(isPresented: $showAddPlayerSheet) {
            addPlayerSheet
        }
        .sheet(isPresented: $showScheduleSheet) {
            let confirmed = appState.gameAttendees(for: game).filter {
                if case .confirmed = $0.booking.state { return true } else { return false }
            }
            GameScheduleSheet(game: game, confirmedPlayers: confirmed)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(game.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
            }

            Text(game.dateTime.formatted(date: .complete, time: .shortened))
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.92))

            if let clubName, !clubName.isEmpty {
                Label(clubName, systemImage: "building.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 10) {
                pillLabel(icon: "clock", text: "\(game.durationMinutes) mins")
                navigationPillLabel(icon: "mappin.and.ellipse", text: game.displayLocation, destination: gameLocationNavigationQuery)
            }

            HStack(spacing: 10) {
                pillLabel(icon: "figure.pickleball", text: prettify(game.gameFormat))
                pillLabel(icon: "chart.line.uptrend.xyaxis", text: prettify(game.skillLevel))
                if game.requiresDUPR {
                    pillLabel(icon: "checkmark.shield", text: "DUPR")
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24, tint: Color.white.opacity(0.12))
    }

    private var bookingActionCard: some View {
        let state = appState.bookingState(for: game)
        let booking = appState.existingBooking(for: game)
        let isRequesting = appState.isRequestingBooking(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let hasReminder = appState.hasReminder(for: game)
        let hasCalendarExport = appState.hasCalendarExport(for: game)
        let isExportingCalendar = appState.isExportingCalendar(for: game)
        let bookingButtonEnabled = state.canBook && canBookGameByClubMembership

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Booking")
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
                Spacer()
                if let confirmed = game.confirmedCount {
                    Text("\(confirmed)/\(game.maxSpots) spots")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                } else {
                    Text("\(game.maxSpots) spots")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                }
            }

            if let spotsLeft = game.spotsLeft {
                Text(game.isFull ? "Game is full. New joins may be waitlisted." : "\(spotsLeft) spots left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(game.isFull ? Brand.spicyOrange : Brand.pineTeal)
            }

            if let waitlist = game.waitlistCount, waitlist > 0 {
                Text("\(waitlist) on waitlist")
                    .font(.footnote)
                    .foregroundStyle(Brand.mutedText)
            }

            if let fee = game.feeAmount, fee > 0 {
                Text("Fee: $\(fee, specifier: "%.2f")")
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
            } else {
                Text("Fee: Free")
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
            }

            if let booking {
                HStack(spacing: 8) {
                    statusReasonBadge(for: booking)
                    Spacer(minLength: 8)
                    paymentIndicatorBadge(for: booking)
                }
            }

            Button {
                handlePrimaryBookingTap(state: state)
            } label: {
                HStack(spacing: 8) {
                    if isRequesting {
                        ProgressView().tint(.white)
                    }
                    Image(systemName: bookingIcon(for: state))
                    Text(isRequesting ? "Booking..." : state.actionTitle)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(foregroundColor(for: state))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(joinBackground(for: state), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(isRequesting || isCancelling || !bookingButtonEnabled)
            .opacity((isRequesting || isCancelling || !bookingButtonEnabled) ? 0.88 : 1)
            .buttonStyle(.plain)
            .actionBorder(
                cornerRadius: 16,
                color: bookingButtonEnabled ? Brand.lightCyan.opacity(0.55) : Brand.slateBlue.opacity(0.22)
            )

            if let bookingMembershipRequirementMessage {
                Text(bookingMembershipRequirementMessage)
                    .font(.footnote)
                    .foregroundStyle(Brand.spicyOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if game.requiresDUPR && state.canBook && canBookGameByClubMembership {
                Text("DUPR games require ID confirmation before booking.")
                    .font(.footnote)
                    .foregroundStyle(Brand.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.canCancel {
                HStack(spacing: 10) {
                    Button {
                        Task { await appState.cancelBooking(for: game) }
                    } label: {
                        HStack(spacing: 8) {
                            if isCancelling {
                                ProgressView().tint(Brand.pineTeal)
                            }
                            Image(systemName: "xmark.circle")
                            Text(isCancelling ? "Cancelling..." : "Cancel Booking")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                    }
                    .foregroundStyle(Brand.pineTeal)
                    .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(isCancelling || isRequesting)
                    .buttonStyle(.plain)
                    .actionBorder(cornerRadius: 14, color: Brand.slateBlue.opacity(0.22))

                    Button {
                        Task { await appState.toggleReminder(for: game) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: hasReminder ? "bell.fill" : "bell.badge")
                            Text(hasReminder ? "Reminder On" : "Remind Me")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                    }
                    .foregroundStyle(.white)
                    .background(
                        (hasReminder ? Brand.brandPrimary : Brand.emeraldAction),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .disabled(isCancelling || isRequesting || game.startsInPast)
                    .opacity(game.startsInPast ? 0.75 : 1)
                    .buttonStyle(.plain)
                    .actionBorder(cornerRadius: 14, color: Brand.lightCyan.opacity(0.5))
                }

                Button {
                    Task { await appState.toggleCalendarExport(for: game) }
                } label: {
                    HStack(spacing: 8) {
                        if isExportingCalendar {
                            ProgressView().tint(Brand.pineTeal)
                        } else {
                            Image(systemName: hasCalendarExport ? "calendar.badge.minus" : "calendar.badge.plus")
                        }
                        Text(hasCalendarExport ? "Remove From Calendar" : "Add To Calendar")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(Brand.pineTeal)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .actionBorder(
                        cornerRadius: 14,
                        color: hasCalendarExport ? Brand.slateBlue.opacity(0.32) : Brand.slateBlue.opacity(0.22)
                    )
                }
                .disabled(isCancelling || isRequesting || isExportingCalendar || (game.startsInPast && !hasCalendarExport))
                .opacity((game.startsInPast && !hasCalendarExport) ? 0.75 : 1)
                .buttonStyle(.plain)
            }

            if let info = appState.bookingInfoMessage, !info.isEmpty {
                Text(info)
                    .font(.footnote)
                    .foregroundStyle(Brand.pineTeal)
            }

            if let error = appState.bookingsErrorMessage, !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(AppCopy.friendlyError(error))
                }
                .font(.footnote)
                .foregroundStyle(Brand.errorRed)
                .appErrorCardStyle(cornerRadius: 12)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24, tint: Color.white.opacity(0.68))
    }

    private var duprBookingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This game requires a verified DUPR profile before booking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        // Try DUPR app first, fall back to website
                        if let appURL = URL(string: "dupr://"), UIApplication.shared.canOpenURL(appURL) {
                            openURL(appURL)
                        } else if let webURL = URL(string: "https://mydupr.com") {
                            openURL(webURL)
                        }
                    } label: {
                        Label("Open DUPR", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                    }
                } header: {
                    Text("DUPR Profile")
                }

                Section {
                    TextField("DUPR ID (e.g. XKXR74)", text: $duprIDDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("DUPR ID")
                } footer: {
                    Text("6-character alphanumeric code found in your DUPR profile.")
                        .font(.caption)
                }

                Section {
                    HStack {
                        Text("Doubles")
                        Spacer()
                        TextField("e.g. 2.928", text: $duprDoublesRatingText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    HStack {
                        Text("Singles")
                        Spacer()
                        TextField("Optional", text: $duprSinglesRatingText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("DUPR Ratings")
                } footer: {
                    Text("Doubles rating is required (1.0–8.0). Singles is optional.")
                        .font(.caption)
                }

                Section {
                    Toggle("I confirm this is my DUPR profile.", isOn: $duprBookingConfirmed)
                }

                if let error = duprSheetErrorMessage, !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Brand.errorRed)
                    }
                }
            }
            .navigationTitle("Confirm DUPR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showDUPRBookingSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await confirmDUPRAndBook() }
                    } label: {
                        if appState.isRequestingBooking(for: game) {
                            ProgressView()
                        } else {
                            Text("Confirm")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(
                        duprIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        duprDoublesRatingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !duprBookingConfirmed ||
                        appState.isRequestingBooking(for: game)
                    )
                }
            }
            .onAppear {
                duprIDDraft = appState.duprID ?? ""
                if let d = appState.duprDoublesRating { duprDoublesRatingText = String(d) } else { duprDoublesRatingText = "" }
                if let s = appState.duprSinglesRating { duprSinglesRatingText = String(s) } else { duprSinglesRatingText = "" }
                duprBookingConfirmed = false
                duprSheetErrorMessage = nil
            }
        }
    }

    private var addPlayerSheet: some View {
        NavigationStack {
            let club = clubForGame
            let allMembers = club.map { appState.ownerMembers(for: $0) } ?? []
            let existingUserIDs: Set<UUID> = Set(
                appState.gameAttendees(for: game)
                    .filter {
                        switch $0.booking.state {
                        case .confirmed, .waitlisted: return true
                        default: return false
                        }
                    }
                    .compactMap { $0.booking.userID }
            )
            let bookableMembers = allMembers.filter {
                $0.membershipStatus == .approved && !existingUserIDs.contains($0.userID)
            }
            let filtered = addPlayerSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? bookableMembers
                : bookableMembers.filter {
                    $0.memberName.localizedCaseInsensitiveContains(addPlayerSearch) ||
                    ($0.memberEmail?.localizedCaseInsensitiveContains(addPlayerSearch) ?? false)
                }

            VStack(spacing: 0) {
                if let info = appState.ownerToolsInfoMessage, !info.isEmpty {
                    Text(info)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Brand.pineTeal.opacity(0.08))
                }

                if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Brand.errorRed.opacity(0.08))
                }

                List {
                    if filtered.isEmpty {
                        Text(bookableMembers.isEmpty ? "All club members are already in this game." : "No members match your search.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filtered) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.memberName)
                                        .font(.subheadline.weight(.semibold))
                                    if let email = member.memberEmail {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    Task {
                                        await appState.ownerAddPlayerToGame(member, game: game)
                                    }
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
                .searchable(text: $addPlayerSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search members")
            }
            .navigationTitle("Add Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAddPlayerSheet = false }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailRow("Status", value: prettify(game.status))
            detailRow("Format", value: prettify(game.gameFormat))
            detailRow("Skill Level", value: prettify(game.skillLevel))
            if let description = game.description, !description.isEmpty {
                detailBlock("Description", value: description)
            }
            if let notes = game.notes, !notes.isEmpty {
                detailBlock("Notes", value: notes)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24, tint: Color.white.opacity(0.68))
    }

    private var attendeesCard: some View {
        let attendees = appState.gameAttendees(for: game)
        let confirmed = attendees.filter { if case .confirmed = $0.booking.state { return true } else { return false } }
        let waitlisted = attendees.filter { if case .waitlisted = $0.booking.state { return true } else { return false } }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attendees")
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
                Spacer()
                if isClubAdminUser {
                    if confirmed.count >= 4 {
                        Button {
                            showScheduleSheet = true
                        } label: {
                            Label("Schedule", systemImage: "shuffle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.pineTeal)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Brand.pineTeal.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        addPlayerSearch = ""
                        showAddPlayerSheet = true
                    } label: {
                        Label("Add", systemImage: "person.badge.plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.slateBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Brand.slateBlue.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if appState.isLoadingAttendees(for: game) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await appState.refreshAttendees(for: game) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.pineTeal)
                }
            }

            if attendees.isEmpty, !appState.isLoadingAttendees(for: game) {
                Text("No attendees yet.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
            } else {
                if isClubAdminUser, !waitlisted.isEmpty {
                    ownerWaitlistBulkActions
                }
                attendeeSection(title: "Booked", rows: confirmed, emptyText: "No confirmed players yet.")
                attendeeSection(title: "Waitlist", rows: waitlisted, emptyText: "No one on the waitlist.")
            }

            if let info = appState.ownerToolsInfoMessage, !info.isEmpty {
                Text(info)
                    .font(.footnote)
                    .foregroundStyle(Brand.pineTeal)
            }

            if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Brand.spicyOrange)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24, tint: Color.white.opacity(0.68))
    }

    @ViewBuilder
    private func attendeeSection(title: String, rows: [GameAttendee], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.ink)

            if rows.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(Brand.mutedText)
            } else {
                ForEach(rows) { attendee in
                    attendeeRow(attendee)
                }
            }
        }
    }

    private func attendeeRow(_ attendee: GameAttendee) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Brand.slateBlue)
                    .overlay(
                        Text(initials(attendee.userName))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(attendee.userName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.ink)
                        if appState.isCheckedIn(bookingID: attendee.booking.id) {
                            Text("Checked In")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Brand.pineTeal, in: Capsule())
                        }
                    }
                    if attendee.booking.userID == appState.authUserID,
                       let doubles = appState.duprDoublesRating {
                        let singlesText = appState.duprSinglesRating.map { " · \(String(format: "%g", $0))S" } ?? ""
                        Text("DUPR \(String(format: "%g", doubles))D\(singlesText)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Brand.slateBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.slateBlue.opacity(0.1), in: Capsule())
                    }
                    attendeePaymentCaption(attendee.booking)
                    attendeeStateCaption(attendee.booking)
                }

                Spacer(minLength: 0)
            }

            if isClubAdminUser {
                ownerAttendeeActions(attendee)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Brand.slateBlue.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func attendeePaymentCaption(_ booking: BookingRecord) -> some View {
        let fee = game.feeAmount ?? 0
        if fee <= 0 {
            Text("Free")
                .font(.caption)
                .foregroundStyle(Brand.mutedText)
        } else if booking.feePaid || booking.paidAt != nil || booking.stripePaymentIntentID != nil {
            Text("Paid")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.pineTeal)
        } else {
            Text("Unpaid")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.spicyOrange)
        }
    }

    @ViewBuilder
    private func attendeeStateCaption(_ booking: BookingRecord) -> some View {
        switch booking.state {
        case .confirmed:
            Text("Confirmed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.pineTeal)
        case let .waitlisted(position):
            Text(position.map { "Waitlist #\($0)" } ?? "Waitlisted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.spicyOrange)
        case .cancelled:
            Text("Cancelled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.mutedText)
        case .unknown:
            Text("Status updated")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.mutedText)
        case .none:
            EmptyView()
        }
    }

    private func ownerAttendeeActions(_ attendee: GameAttendee) -> some View {
        HStack(spacing: 8) {
            if attendee.booking.state != .confirmed {
                ownerActionButton("Confirm", icon: "checkmark.circle.fill", filled: true, busy: appState.isUpdatingOwnerBooking(attendee.booking.id)) {
                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .confirmed) }
                }
            }

            if !isWaitlisted(attendee.booking.state) {
                ownerActionButton("Waitlist", icon: "clock.badge", filled: false, busy: appState.isUpdatingOwnerBooking(attendee.booking.id)) {
                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .waitlisted(position: nil)) }
                }
            }

            ownerActionButton(appState.isCheckedIn(bookingID: attendee.booking.id) ? "Undo Check-In" : "Check In",
                              icon: appState.isCheckedIn(bookingID: attendee.booking.id) ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark",
                              filled: false,
                              busy: appState.isUpdatingOwnerBooking(attendee.booking.id)) {
                Task { await appState.toggleCheckIn(for: game, attendee: attendee) }
            }

            ownerActionButton("Cancel", icon: "trash", filled: false, destructive: true, busy: appState.isUpdatingOwnerBooking(attendee.booking.id)) {
                Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .cancelled) }
            }

            if isWaitlisted(attendee.booking.state) {
                ownerActionButton("Up", icon: "arrow.up", filled: false, busy: appState.isUpdatingOwnerBooking(attendee.booking.id)) {
                    Task { await appState.ownerMoveWaitlistAttendee(for: game, attendee: attendee, directionUp: true) }
                }
                ownerActionButton("Down", icon: "arrow.down", filled: false, busy: appState.isUpdatingOwnerBooking(attendee.booking.id)) {
                    Task { await appState.ownerMoveWaitlistAttendee(for: game, attendee: attendee, directionUp: false) }
                }
            }
        }
    }

    private var ownerWaitlistBulkActions: some View {
        HStack(spacing: 10) {
            ownerActionButton("Confirm All Waitlist", icon: "checkmark.circle", filled: true, busy: false) {
                Task { await appState.ownerConfirmAllWaitlist(for: game) }
            }

            ownerActionButton("Clear Waitlist", icon: "trash", filled: false, destructive: true, busy: false) {
                Task { await appState.ownerClearWaitlist(for: game) }
            }
        }
    }

    private func ownerActionButton(
        _ title: String,
        icon: String,
        filled: Bool,
        destructive: Bool = false,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(filled ? .white : Brand.pineTeal)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(buttonTextColor(filled: filled, destructive: destructive))
            .background(buttonFillColor(filled: filled, destructive: destructive), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .actionBorder(cornerRadius: 12, color: filled ? Brand.lightCyan.opacity(0.45) : Brand.slateBlue.opacity(0.22))
    }

    private func buttonFillColor(filled: Bool, destructive: Bool) -> Color {
        if filled {
            return destructive ? Brand.errorRed : Brand.emeraldAction
        }
        return destructive ? Color.white.opacity(0.92) : Color.white.opacity(0.92)
    }

    private func buttonTextColor(filled: Bool, destructive: Bool) -> Color {
        if filled { return .white }
        return destructive ? Brand.errorRed : Brand.brandPrimaryDark
    }

    private func initials(_ name: String) -> String {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "M" : String(chars)
    }

    private func isWaitlisted(_ state: BookingState) -> Bool {
        if case .waitlisted = state { return true }
        return false
    }

    private func pillLabel(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1), in: Capsule())
    }

    private func navigationPillLabel(icon: String, text: String, destination: String) -> some View {
        Group {
            if let url = MapNavigationURL.directions(to: destination) {
                Button {
                    openURL(url)
                } label: {
                    pillLabel(icon: icon, text: text)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            } else {
                pillLabel(icon: icon, text: text)
            }
        }
    }

    private func handlePrimaryBookingTap(state: BookingState) {
        if game.requiresDUPR && state.canBook && canBookGameByClubMembership {
            duprIDDraft = appState.duprID ?? ""
            if let d = appState.duprDoublesRating { duprDoublesRatingText = String(d) } else { duprDoublesRatingText = "" }
            if let s = appState.duprSinglesRating { duprSinglesRatingText = String(s) } else { duprSinglesRatingText = "" }
            duprBookingConfirmed = false
            duprSheetErrorMessage = nil
            showDUPRBookingSheet = true
            return
        }
        Task { await appState.requestBooking(for: game) }
    }

    private func confirmDUPRAndBook() async {
        // Validate and save DUPR ID
        if let error = appState.saveCurrentUserDUPRID(duprIDDraft) {
            duprSheetErrorMessage = error
            return
        }

        // Validate and save doubles rating (required)
        let doublesText = duprDoublesRatingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doublesRating = Double(doublesText) else {
            duprSheetErrorMessage = "Enter a valid Doubles rating (e.g. 2.928)."
            return
        }

        // Parse singles rating (optional)
        let singlesText = duprSinglesRatingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let singlesRating: Double? = singlesText.isEmpty ? nil : Double(singlesText)
        if !singlesText.isEmpty && singlesRating == nil {
            duprSheetErrorMessage = "Enter a valid Singles rating or leave it blank."
            return
        }

        if let error = appState.saveDUPRRatings(doubles: doublesRating, singles: singlesRating) {
            duprSheetErrorMessage = error
            return
        }

        guard duprBookingConfirmed else {
            duprSheetErrorMessage = "Please confirm this is your DUPR profile."
            return
        }
        duprSheetErrorMessage = nil
        showDUPRBookingSheet = false
        await appState.requestBooking(for: game)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
                .multilineTextAlignment(.trailing)
        }
    }

    private func detailBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
            Text(value)
                .foregroundStyle(Brand.mutedText)
        }
    }

    private func statusReasonBadge(for booking: BookingRecord) -> some View {
        let text: String
        switch booking.state {
        case .confirmed:
            text = "Confirmed"
        case let .waitlisted(position):
            text = position.map { "Waitlist #\($0)" } ?? "Waitlisted"
        case .cancelled:
            text = "Cancelled"
        case .unknown:
            text = "Status updated"
        case .none:
            text = "Not booked"
        }

        return Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Brand.slateBlue, in: Capsule())
    }

    private func paymentIndicatorBadge(for booking: BookingRecord) -> some View {
        let fee = game.feeAmount ?? 0
        let label: String
        let fill: Color
        let textColor: Color

        if fee <= 0 {
            label = "Free"
            fill = Color.white.opacity(0.9)
            textColor = Brand.pineTeal
        } else if booking.feePaid || booking.paidAt != nil || booking.stripePaymentIntentID != nil {
            label = "Paid"
            fill = Brand.emeraldAction
            textColor = .white
        } else {
            label = "Payment Due"
            fill = Color.white.opacity(0.9)
            textColor = Brand.pineTeal
        }

        return Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
    }

    private func prettify(_ raw: String) -> String {
        if raw.caseInsensitiveCompare("ladder") == .orderedSame {
            return "King of the Court"
        }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func bookingIcon(for state: BookingState) -> String {
        switch state {
        case .none, .cancelled:
            return "plus.circle.fill"
        case .confirmed, .unknown:
            return "checkmark.circle.fill"
        case .waitlisted:
            return "clock.badge.checkmark.fill"
        }
    }

    private func foregroundColor(for state: BookingState) -> Color {
        switch state {
        case .none, .cancelled:
            return .white
        case .confirmed, .waitlisted, .unknown:
            return Brand.pineTeal
        }
    }

    private func joinBackground(for state: BookingState) -> Color {
        switch state {
        case .none, .cancelled:
            return Brand.emeraldAction
        case .confirmed, .waitlisted, .unknown:
            return Color.white.opacity(0.9)
        }
    }
}

#Preview {
    NavigationStack {
        GameDetailView(
            game: Game(
                id: UUID(),
                clubID: UUID(),
                title: "Tuesday Open Play",
                description: "Casual social session with mixed levels.",
                dateTime: .now.addingTimeInterval(3600 * 24),
                durationMinutes: 90,
                skillLevel: "all",
                gameFormat: "open_play",
                maxSpots: 16,
                feeAmount: 5,
                feeCurrency: "AUD",
                location: "Court 2",
                status: "upcoming",
                notes: "Bring indoor shoes.",
                requiresDUPR: false,
                confirmedCount: 10,
                waitlistCount: 2
            )
        )
        .environmentObject(AppState())
    }
}
