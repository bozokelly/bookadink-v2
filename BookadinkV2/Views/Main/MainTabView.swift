import SwiftUI
import UserNotifications

enum AppTab: Hashable {
    case home
    case clubs
    case bookings
    case notifications
    case profile
}

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: AppTab = .home
    @State private var deepLinkClub: Club? = nil
    @State private var deepLinkGame: Game? = nil
    /// Captures the game ID of whichever review prompt is currently being presented,
    /// so onDismiss can dismiss the correct game even if pendingReviewPrompt has changed.
    @State private var presentingReviewGameID: UUID? = nil

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(AppTab.home)

            NavigationStack {
                ClubsListView(clubs: appState.clubs)
                    .navigationDestination(item: $deepLinkClub) { club in
                        ClubDetailView(club: club)
                    }
            }
            .tabItem {
                Label("Clubs", systemImage: "building.2")
            }
            .tag(AppTab.clubs)

            NavigationStack {
                BookingsListView()
            }
            .tabItem {
                Label("Bookings", systemImage: "calendar")
            }
            .tag(AppTab.bookings)

            NavigationStack {
                NotificationsView()
            }
            .tabItem {
                Label("Notifications", systemImage: "bell")
            }
            .badge(appState.unreadNotificationCount > 0 ? appState.unreadNotificationCount : 0)
            .tag(AppTab.notifications)

            NavigationStack {
                ProfileDashboardView()
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .tag(AppTab.profile)
        }
        .tint(Brand.primaryText)
        // Force traditional bottom tab bar on all devices including iPad iOS 18+,
        // which defaults to a sidebar/top-bar layout when no explicit style is set.
        .tabViewStyle(DefaultTabViewStyle())
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(item: $deepLinkGame) { game in
            NavigationStack {
                GameDetailView(game: game)
            }
        }
        .sheet(item: $appState.pendingReviewPrompt, onDismiss: {
            // Use the captured ID rather than appState.pendingReviewPrompt so we dismiss
            // the correct game even if a second pending prompt was queued by submit.
            guard let gameID = presentingReviewGameID else { return }
            presentingReviewGameID = nil
            Task { await appState.dismissReviewPrompt(gameID: gameID) }
        }) { prompt in
            ReviewGameSheet(gameID: prompt.id, gameTitle: prompt.gameTitle)
        }
        .onChange(of: appState.pendingReviewPrompt) { _, newPrompt in
            if let newPrompt { presentingReviewGameID = newPrompt.id }
        }
        .onChange(of: appState.pendingDeepLink) { _, link in
            guard let link else { return }
            handleDeepLink(link)
        }
        .task {
            // Cold-launch: deep link or review prompt may have been set before this view entered
            // the hierarchy. onChange won't fire for values already set at first appearance.
            if let link = appState.pendingDeepLink {
                handleDeepLink(link)
            }
            if let prompt = appState.pendingReviewPrompt {
                presentingReviewGameID = prompt.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookADinkOpenNotificationsTab)) { _ in
            selectedTab = .notifications
        }
    }

    private func handleDeepLink(_ link: DeepLink) {
        switch link {
        case .club(let id):
            guard let club = appState.clubs.first(where: { $0.id == id }) else { return }
            selectedTab = .clubs
            // Small delay so the tab switch animates before the push
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                deepLinkClub = club
                appState.pendingDeepLink = nil
            }
        case .game(let id):
            let cached = appState.gamesByClubID.values.flatMap({ $0 }).first(where: { $0.id == id })
                ?? appState.bookings.first(where: { $0.booking.gameID == id })?.game
            if let game = cached {
                // Game already in memory — open immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    deepLinkGame = game
                    appState.pendingDeepLink = nil
                }
            } else {
                // Game not in cache (e.g. new_game notification before club loaded) — fetch then open
                appState.pendingDeepLink = nil
                Task {
                    guard let game = await appState.resolveGame(id: id) else { return }
                    await MainActor.run { deepLinkGame = game }
                }
            }
        case .review:
            // Review prompts are handled inline in NotificationsView — no tab switch needed
            appState.pendingDeepLink = nil
        case .connectReturn:
            // Handled in AppState.handleDeepLink — never reaches pendingDeepLink
            appState.pendingDeepLink = nil
        }
    }
}


// MARK: - Sport Blend shared helpers (used by all settings sub-views)

@ViewBuilder
private func sportFormSection<Content: View>(
    header: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(header)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(Brand.secondaryText)
            .padding(.horizontal, 4)

        VStack(spacing: 0) {
            content()
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.sportBorder, lineWidth: 1)
        )
    }
}

@ViewBuilder
private func sportFieldRow<Content: View>(
    label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(Brand.secondaryText)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
}

// MARK: - Account Hub

struct EditProfileSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showSignOutAlert = false
    @State private var showDeleteAlert = false

    // MARK: Derived stats for hero card

    private var initials: String {
        guard let name = appState.profile?.fullName else { return "?" }
        return name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    private var duprDisplay: String {
        if let r = appState.duprDoublesRating ?? appState.profile?.duprRating {
            return String(format: "%.3f", r)
        }
        return "—"
    }

    private var confirmedGameCount: Int {
        appState.bookings.filter {
            if case .confirmed = $0.booking.state { return true }
            return false
        }.count
    }

    private var memberClubCount: Int {
        appState.membershipStatesByClubID.values.filter {
            switch $0 {
            case .approved, .unknown: return true
            default: return false
            }
        }.count
    }

    private var memberSinceYear: String {
        Calendar.current.component(.year, from: Date()).description
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.sportBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        heroCard
                        sportSection(header: "PLAYER") {
                            sportNavRow(icon: "person", label: "Personal Info") { ProfilePersonalInfoView() }
                            sportDivider()
                            sportNavRow(icon: "phone", label: "Contact") { ProfileContactView() }
                            sportDivider()
                            sportNavRow(icon: "chart.line.uptrend.xyaxis", label: "DUPR Rating", highlighted: true) { ProfileDUPRView() }
                            sportDivider()
                            sportNavRow(icon: "paintpalette", label: "Appearance") { ProfileAppearanceView() }
                        }
                        sportSection(header: "SAFETY") {
                            sportNavRow(icon: "shield.lefthalf.filled", label: "Emergency Contact") { ProfileEmergencyContactView() }
                        }
                        sportSection(header: "ACCESS") {
                            sportNavRow(icon: "lock", label: "Password & Security") { ProfileSecurityView() }
                            sportDivider()
                            sportNavRow(icon: "bell", label: "Notifications") { ProfileNotificationsView() }
                        }
                        signOutCard
                        deleteAccountButton
                        Text("BookaDink · Member since \(memberSinceYear)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.secondaryText.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 44)
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Brand.sportStatement)
                }
            }
        }
        .tint(Brand.sportStatement)
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Delete Account", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { /* TODO: implement account deletion */ }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete your account and all data. This action cannot be undone.")
        }
    }

    // MARK: Hero Card

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            // Sport motif overlay
            Image(systemName: "figure.pickleball")
                .font(.system(size: 160))
                .foregroundStyle(Brand.sportPop.opacity(0.07))
                .rotationEffect(.degrees(18))
                .offset(x: 30, y: -18)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Avatar + name / email
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Brand.sportPop)
                            .frame(width: 70, height: 70)
                        ProfileAvatarBadge(
                            initials: initials,
                            colorKey: appState.profile?.avatarColorKey
                        )
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.profile?.fullName ?? "Player")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Brand.sportCream)
                        Text(appState.profile?.email ?? appState.authEmail ?? "")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.sportCream.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 18)

                // Stat strip
                HStack(spacing: 0) {
                    heroStatTile(label: "DUPR", value: duprDisplay)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30)
                    heroStatTile(label: "GAMES", value: "\(confirmedGameCount)")
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30)
                    heroStatTile(label: "CLUBS", value: "\(memberClubCount)")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.07))
            }
        }
        .background(Brand.sportStatement)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func heroStatTile(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(Brand.sportCream.opacity(0.45))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.sportCream)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Section helpers

    private func sportSection<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(header)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Brand.sportBorder, lineWidth: 1)
            )
        }
    }

    private func sportDivider() -> some View {
        Divider()
            .background(Brand.sportBorder)
            .padding(.leading, 54)
    }

    private func sportNavRow<Dest: View>(
        icon: String,
        label: String,
        detail: String? = nil,
        highlighted: Bool = false,
        @ViewBuilder destination: () -> Dest
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlighted ? Brand.sportStatement : Brand.sportBgAlt)
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(highlighted ? Brand.sportPop : Brand.sportStatement)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Brand.sportStatement)
                    if let d = detail {
                        Text(d)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.secondaryText)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.sportBorder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sign Out

    private var signOutCard: some View {
        Button { showSignOutAlert = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Brand.sportBgAlt)
                        .frame(width: 32, height: 32)
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.sportStatement)
                }
                Text("Sign Out")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Brand.sportStatement)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Brand.sportBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Delete Account

    private var deleteAccountButton: some View {
        Button { showDeleteAlert = true } label: {
            Text("DELETE ACCOUNT")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(Brand.sportWarn)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Brand.sportBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Personal Info

private struct ProfilePersonalInfoView: View {
    @EnvironmentObject private var appState: AppState
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var dateOfBirth: Date? = nil
    @State private var showDOBPicker = false
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isSavingPill = false
    @State private var showSavedPill = false
    @State private var isReady = false

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    sportFormSection(header: "NAME") {
                        sportFieldRow(label: "FIRST NAME") {
                            TextField("First name", text: $firstName)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                        Divider().background(Brand.sportBorder)
                        sportFieldRow(label: "LAST NAME") {
                            TextField("Last name", text: $lastName)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                    }

                    sportFormSection(header: "DATE OF BIRTH") {
                        Button {
                            withAnimation(.spring(duration: 0.25)) { showDOBPicker.toggle() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("DATE OF BIRTH")
                                        .font(.system(size: 11, weight: .bold)).kerning(0.6)
                                        .foregroundStyle(Brand.secondaryText)
                                    Text(dateOfBirth.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not set")
                                        .font(.system(size: 16))
                                        .foregroundStyle(dateOfBirth == nil ? Brand.secondaryText : Brand.sportStatement)
                                }
                                Spacer()
                                Image(systemName: showDOBPicker ? "calendar.badge.minus" : "calendar")
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)

                        if showDOBPicker {
                            Divider().background(Brand.sportBorder)
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { dateOfBirth ?? Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date() },
                                    set: { dateOfBirth = $0 }
                                ),
                                displayedComponents: .date
                            )
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .padding(.horizontal, 8)
                        }
                    }

                    if let error = appState.profileSaveErrorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption).foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Personal Info")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            AutoSavePill(saving: isSavingPill, saved: showSavedPill && !isSavingPill)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .animation(.spring(duration: 0.25), value: isSavingPill || showSavedPill)
        }
        .onAppear {
            populate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isReady = true }
        }
        .onChange(of: firstName) { _, _ in scheduleSave() }
        .onChange(of: lastName) { _, _ in scheduleSave() }
        .onChange(of: dateOfBirth) { _, _ in scheduleSave() }
    }

    private func populate() {
        guard let p = appState.profile else { return }
        firstName = p.firstName ?? String(p.fullName.split(separator: " ").first ?? Substring(p.fullName))
        lastName = p.lastName ?? p.fullName.split(separator: " ").dropFirst().joined(separator: " ")
        dateOfBirth = p.dateOfBirth
        appState.profileSaveErrorMessage = nil
    }

    private func scheduleSave() {
        guard isReady else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return }
        await MainActor.run { isSavingPill = true; showSavedPill = false }
        await appState.saveProfilePersonalInfo(
            firstName: first,
            lastName: last,
            fullName: "\(first) \(last)".trimmingCharacters(in: .whitespacesAndNewlines),
            phone: appState.profile?.phone,
            dateOfBirth: dateOfBirth,
            duprRating: appState.profile?.duprRating
        )
        await MainActor.run {
            isSavingPill = false
            if appState.profileSaveErrorMessage == nil {
                showSavedPill = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    await MainActor.run { showSavedPill = false }
                }
            }
        }
    }
}

// MARK: - DUPR

private struct ProfileDUPRView: View {
    @EnvironmentObject private var appState: AppState
    @State private var duprID = ""
    @State private var doublesText = ""
    @State private var singlesText = ""
    @State private var errorMessage: String? = nil
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isSavingPill = false
    @State private var showSavedPill = false
    @State private var isReady = false
    @AppStorage("duprSinglesRating") private var storedSingles: Double = 0

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    sportFormSection(header: "DUPR ID") {
                        sportFieldRow(label: "ID NUMBER") {
                            TextField("e.g. 1234567", text: $duprID)
                                .keyboardType(.numberPad)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                        Divider().background(Brand.sportBorder)
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.caption).foregroundStyle(Brand.secondaryText)
                            Text("Required for DUPR-rated games.")
                                .font(.caption).foregroundStyle(Brand.secondaryText)
                        }
                        .padding(.horizontal, 14).padding(.bottom, 12)
                    }

                    sportFormSection(header: "RATINGS") {
                        HStack(spacing: 0) {
                            sportFieldRow(label: "DOUBLES") {
                                TextField("e.g. 3.52", text: $doublesText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                            }
                            Rectangle().fill(Brand.sportBorder).frame(width: 1)
                            sportFieldRow(label: "SINGLES") {
                                TextField("e.g. 3.20", text: $singlesText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                            }
                        }
                        Divider().background(Brand.sportBorder)
                        Text("Ratings must be between 2.000 and 8.000, with exactly 3 decimal places.")
                            .font(.caption).foregroundStyle(Brand.secondaryText)
                            .padding(.horizontal, 14).padding(.bottom, 12)
                    }

                    if let err = errorMessage, !err.isEmpty {
                        Text(err).font(.caption).foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("DUPR")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            AutoSavePill(saving: isSavingPill, saved: showSavedPill && !isSavingPill)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .animation(.spring(duration: 0.25), value: isSavingPill || showSavedPill)
        }
        .onAppear {
            populate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isReady = true }
        }
        .onChange(of: duprID) { _, _ in scheduleSave() }
        .onChange(of: doublesText) { _, _ in scheduleSave() }
        .onChange(of: singlesText) { _, _ in scheduleSave() }
    }

    private func populate() {
        duprID = appState.duprID ?? ""
        // %.3f ensures loaded rating displays as "4.250" not "4.25", so the 3dp
        // requirement is met when the auto-save re-validates the pre-filled text.
        doublesText = appState.duprDoublesRating.map { String(format: "%.3f", $0) } ?? ""
        singlesText = storedSingles > 0 ? String(format: "%.3f", storedSingles) : ""
        errorMessage = nil
    }

    private func scheduleSave() {
        guard isReady else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        await MainActor.run { errorMessage = nil; isSavingPill = true; showSavedPill = false }

        let rawID = duprID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawID.isEmpty {
            if let err = appState.saveCurrentUserDUPRID(rawID) {
                await MainActor.run { errorMessage = err; isSavingPill = false }
                return
            }
        }

        let doublesVal = doublesText.trimmingCharacters(in: .whitespaces)
        let singlesVal = singlesText.trimmingCharacters(in: .whitespaces)

        if !doublesVal.isEmpty {
            let parts = doublesVal.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count != 2 || parts[1].count != 3 {
                await MainActor.run { errorMessage = "Doubles rating must have exactly 3 decimal places (e.g. 3.524)."; isSavingPill = false }
                return
            }
        }
        if !singlesVal.isEmpty {
            let parts = singlesVal.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count != 2 || parts[1].count != 3 {
                await MainActor.run { errorMessage = "Singles rating must have exactly 3 decimal places (e.g. 3.524)."; isSavingPill = false }
                return
            }
        }

        let doubles = doublesVal.isEmpty ? nil : Double(doublesVal)
        let singles = singlesVal.isEmpty ? nil : Double(singlesVal)

        if let s = singles, s < 2.0 || s > 8.0 {
            await MainActor.run { errorMessage = "Singles rating must be between 2.000 and 8.000."; isSavingPill = false }
            return
        }

        if let err = appState.saveDUPRRatings(doubles: doubles, singles: singles) {
            await MainActor.run { errorMessage = err; isSavingPill = false }
            return
        }
        await MainActor.run { storedSingles = singles ?? 0 }

        let p = appState.profile
        await appState.saveProfilePersonalInfo(
            fullName: p?.fullName ?? "",
            phone: p?.phone,
            dateOfBirth: p?.dateOfBirth,
            duprRating: doubles
        )

        await MainActor.run {
            isSavingPill = false
            if appState.profileSaveErrorMessage == nil {
                showSavedPill = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    await MainActor.run { showSavedPill = false }
                }
            } else {
                errorMessage = appState.profileSaveErrorMessage
            }
        }
    }
}

// MARK: - Contact

private struct ProfileContactView: View {
    @EnvironmentObject private var appState: AppState
    @State private var phone = ""
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isSavingPill = false
    @State private var showSavedPill = false
    @State private var isReady = false

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    sportFormSection(header: "EMAIL") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("EMAIL ADDRESS")
                                .font(.system(size: 11, weight: .bold)).kerning(0.6)
                                .foregroundStyle(Brand.secondaryText)
                            Text(appState.profile?.email ?? appState.authEmail ?? "—")
                                .font(.system(size: 16))
                                .foregroundStyle(Brand.sportStatement)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Brand.sportBgAlt)
                        Divider().background(Brand.sportBorder)
                        Text("Email is linked to your sign-in and cannot be changed here.")
                            .font(.caption).foregroundStyle(Brand.secondaryText)
                            .padding(.horizontal, 14).padding(.bottom, 12)
                    }

                    sportFormSection(header: "PHONE") {
                        sportFieldRow(label: "PHONE NUMBER") {
                            TextField("e.g. 0412 345 678", text: $phone)
                                .keyboardType(.phonePad)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                    }

                    if let error = appState.profileSaveErrorMessage, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            AutoSavePill(saving: isSavingPill, saved: showSavedPill && !isSavingPill)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .animation(.spring(duration: 0.25), value: isSavingPill || showSavedPill)
        }
        .onAppear {
            populate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isReady = true }
        }
        .onChange(of: phone) { _, _ in scheduleSave() }
    }

    private func populate() {
        phone = appState.profile?.phone ?? ""
        appState.profileSaveErrorMessage = nil
    }

    private func scheduleSave() {
        guard isReady else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        let p = appState.profile
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { isSavingPill = true; showSavedPill = false }
        await appState.saveProfilePersonalInfo(
            fullName: p?.fullName ?? "",
            phone: trimmed.isEmpty ? nil : trimmed,
            dateOfBirth: p?.dateOfBirth,
            duprRating: p?.duprRating
        )
        await MainActor.run {
            isSavingPill = false
            if appState.profileSaveErrorMessage == nil {
                showSavedPill = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    await MainActor.run { showSavedPill = false }
                }
            }
        }
    }
}

// MARK: - Appearance

private struct ProfileAppearanceView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedKey: String? = nil
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isSavingPill = false
    @State private var showSavedPill = false
    @State private var isReady = false

    private var initials: String {
        guard let name = appState.profile?.fullName else { return "?" }
        return name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    private let paletteEntries: [AvatarGradients.Entry] =
        AvatarGradients.neonAccent + AvatarGradients.softLuxury

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    // Avatar preview
                    ZStack {
                        Circle().fill(Brand.sportPop).frame(width: 94, height: 94)
                        ProfileAvatarBadge(initials: initials, colorKey: selectedKey)
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    }
                    .shadow(color: Brand.sportStatement.opacity(0.12), radius: 12, y: 4)

                    sportFormSection(header: "AVATAR COLOUR") {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6),
                            spacing: 14
                        ) {
                            ForEach(paletteEntries) { entry in
                                Button {
                                    selectedKey = selectedKey == entry.key ? nil : entry.key
                                } label: {
                                    Circle()
                                        .fill(entry.gradient)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    selectedKey == entry.key ? Brand.sportStatement : Color.clear,
                                                    lineWidth: 3
                                                )
                                        )
                                        .overlay(
                                            selectedKey == entry.key
                                                ? Image(systemName: "checkmark")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.white)
                                                : nil
                                        )
                                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            AutoSavePill(saving: isSavingPill, saved: showSavedPill && !isSavingPill)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .animation(.spring(duration: 0.25), value: isSavingPill || showSavedPill)
        }
        .onAppear {
            selectedKey = appState.profile?.avatarColorKey
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isReady = true }
        }
        .onChange(of: selectedKey) { _, _ in scheduleSave() }
    }

    private func scheduleSave() {
        guard isReady else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        await MainActor.run { isSavingPill = true; showSavedPill = false }
        await appState.saveAvatarColorKey(selectedKey)
        await MainActor.run {
            isSavingPill = false
            if appState.profileSaveErrorMessage == nil {
                showSavedPill = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    await MainActor.run { showSavedPill = false }
                }
            }
        }
    }
}

// MARK: - Emergency Contact

private struct ProfileEmergencyContactView: View {
    @EnvironmentObject private var appState: AppState
    @State private var name = ""
    @State private var phone = ""
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var isSavingPill = false
    @State private var showSavedPill = false
    @State private var isReady = false

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    sportFormSection(header: "EMERGENCY CONTACT") {
                        sportFieldRow(label: "CONTACT NAME") {
                            TextField("Contact name", text: $name)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                        Divider().background(Brand.sportBorder)
                        sportFieldRow(label: "CONTACT PHONE") {
                            TextField("e.g. 0412 345 678", text: $phone)
                                .keyboardType(.phonePad)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                        Divider().background(Brand.sportBorder)
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.caption).foregroundStyle(Brand.secondaryText)
                            Text("Available to club admins in case of an emergency.")
                                .font(.caption).foregroundStyle(Brand.secondaryText)
                        }
                        .padding(.horizontal, 14).padding(.bottom, 12)
                    }

                    if let error = appState.profileSaveErrorMessage, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(Brand.errorRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Emergency Contact")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            AutoSavePill(saving: isSavingPill, saved: showSavedPill && !isSavingPill)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .animation(.spring(duration: 0.25), value: isSavingPill || showSavedPill)
        }
        .onAppear {
            populate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isReady = true }
        }
        .onChange(of: name) { _, _ in scheduleSave() }
        .onChange(of: phone) { _, _ in scheduleSave() }
    }

    private func populate() {
        name = appState.profile?.emergencyContactName ?? ""
        phone = appState.profile?.emergencyContactPhone ?? ""
        appState.profileSaveErrorMessage = nil
    }

    private func scheduleSave() {
        guard isReady else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ph = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { isSavingPill = true; showSavedPill = false }
        await appState.saveEmergencyContact(
            name: n.isEmpty ? nil : n,
            phone: ph.isEmpty ? nil : ph
        )
        await MainActor.run {
            isSavingPill = false
            if appState.profileSaveErrorMessage == nil {
                showSavedPill = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    await MainActor.run { showSavedPill = false }
                }
            }
        }
    }
}

// MARK: - Password & Security

private struct ProfileSecurityView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    sportFormSection(header: "NEW PASSWORD") {
                        sportFieldRow(label: "NEW PASSWORD") {
                            SecureField("At least 8 characters", text: $newPassword)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                        Divider().background(Brand.sportBorder)
                        sportFieldRow(label: "CONFIRM PASSWORD") {
                            SecureField("Repeat new password", text: $confirmPassword)
                                .font(.system(size: 16)).foregroundStyle(Brand.sportStatement)
                        }
                    }

                    if let msg = appState.passwordUpdateMessage {
                        HStack(spacing: 8) {
                            Image(systemName: msg.contains("successfully") ? "checkmark.circle" : "exclamationmark.circle")
                            Text(msg)
                        }
                        .font(.caption)
                        .foregroundStyle(msg.contains("successfully") ? Brand.emeraldAction : Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }

                    Button {
                        Task {
                            await appState.updatePassword(newPassword: newPassword, confirmPassword: confirmPassword)
                            if appState.passwordUpdateMessage?.contains("successfully") == true {
                                newPassword = ""
                                confirmPassword = ""
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if appState.isUpdatingPassword {
                                ProgressView().tint(Brand.sportPop).scaleEffect(0.8)
                            }
                            Text("UPDATE PASSWORD")
                                .font(.system(size: 14, weight: .bold))
                                .kerning(0.5)
                                .foregroundStyle(Brand.sportPop)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Brand.sportStatement, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isUpdatingPassword)
                    .opacity(appState.isUpdatingPassword ? 0.65 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Password & Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { appState.passwordUpdateMessage = nil }
    }
}

// MARK: - Notifications

private struct ProfileNotificationsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pushStatus: UNAuthorizationStatus = .notDetermined
    @State private var prefs: NotificationPreferences = .init()

    private var isPushAuthorized: Bool {
        pushStatus == .authorized || pushStatus == .provisional || pushStatus == .ephemeral
    }

    // Pause = all push toggles off
    private var allPaused: Bool {
        !prefs.bookingConfirmedPush && !prefs.newGamePush && !prefs.waitlistPush && !prefs.chatPush
    }

    var body: some View {
        ZStack {
            Brand.sportBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    // Pause hero
                    pauseHero

                    // iOS push settings link
                    if !isPushAuthorized {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "gear")
                                    .font(.system(size: 15, weight: .medium))
                                Text("Enable push in iOS Settings")
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Brand.sportStatement)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.sportBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    // Category section header
                    Text("NOTIFY ME ABOUT")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Brand.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    // Category cards
                    VStack(spacing: 10) {
                        notifCategoryCard(
                            icon: "calendar",
                            label: "Bookings",
                            subtitle: "Confirmations, cancellations, and reminders",
                            push: $prefs.bookingConfirmedPush,
                            email: $prefs.bookingConfirmedEmail
                        )
                        notifCategoryCard(
                            icon: "figure.pickleball",
                            label: "New Games",
                            subtitle: "When clubs you've joined post new sessions",
                            push: $prefs.newGamePush,
                            email: $prefs.newGameEmail
                        )
                        notifCategoryCard(
                            icon: "sparkle",
                            label: "Waitlist",
                            subtitle: "Spot available, hold expiry, position updates",
                            push: $prefs.waitlistPush,
                            email: $prefs.waitlistEmail
                        )
                        notifCategoryCard(
                            icon: "bubble.left.and.bubble.right",
                            label: "Chat & Posts",
                            subtitle: "Club news posts, comments, and reactions",
                            push: $prefs.chatPush,
                            email: nil   // no email toggle — push only
                        )
                    }
                    .opacity(allPaused ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.2), value: allPaused)

                    // Footer disclaimer
                    Text("Club announcements and critical account emails (password reset, security alerts) are always delivered regardless of these settings.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.secondaryText.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                pushStatus = settings.authorizationStatus
                prefs = appState.notificationPreferences
            }
        }
        .onChange(of: prefs) { _, newPrefs in
            appState.notificationPreferences = newPrefs
            Task { await appState.saveNotificationPreferences() }
        }
    }

    // MARK: Pause Hero

    private var pauseHero: some View {
        HStack(spacing: 14) {
            // Icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: allPaused ? "bell.slash.fill" : "bell.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(allPaused ? Color.white : Brand.sportPop)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(allPaused ? "Notifications paused" : "You're in the loop")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                Text(allPaused ? "Tap to resume all push alerts" : "All push notifications are active")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            Spacer()

            // Master pause toggle
            Toggle("", isOn: Binding(
                get: { !allPaused },
                set: { isOn in
                    prefs.bookingConfirmedPush = isOn
                    prefs.newGamePush = isOn
                    prefs.waitlistPush = isOn
                    prefs.chatPush = isOn
                }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Brand.sportPop))
            .labelsHidden()
        }
        .padding(18)
        .background(allPaused ? Brand.sportWarn : Brand.sportStatement)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: allPaused)
    }

    // MARK: Category Card

    private func notifCategoryCard(
        icon: String,
        label: String,
        subtitle: String,
        push: Binding<Bool>,
        email: Binding<Bool>?
    ) -> some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Brand.sportBgAlt)
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.sportStatement)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Brand.sportStatement)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(Brand.sportBorder)

            // Chip row
            HStack(spacing: 8) {
                notifChip(label: "PUSH", isOn: push, disabled: !isPushAuthorized)
                if let emailBinding = email {
                    notifChip(label: "EMAIL", isOn: emailBinding, disabled: false)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.sportBorder, lineWidth: 1))
        .allowsHitTesting(!allPaused)
    }

    private func notifChip(label: String, isOn: Binding<Bool>, disabled: Bool) -> some View {
        Button {
            guard !disabled else { return }
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                if isOn.wrappedValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Brand.sportCream)
                }
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(isOn.wrappedValue ? Brand.sportCream : Brand.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isOn.wrappedValue
                    ? AnyShapeStyle(Brand.sportStatement)
                    : AnyShapeStyle(Color.clear),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isOn.wrappedValue ? Color.clear : Brand.sportBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
    }
}
