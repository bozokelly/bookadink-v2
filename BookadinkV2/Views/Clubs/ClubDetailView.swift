import CoreLocation
import MapKit
import SwiftUI
import UIKit
import os

// MARK: - Content Tab Kind

enum ContentTabKind: String, CaseIterable { case games = "Games", chat = "Chat" }

// MARK: - Club Hero View
//
// Renders the club banner image (custom upload, then preset). Sized via the
// shared `bannerAspectRatio` so the crop preview in ClubOwnerSheets matches
// the rendered banner here exactly. The dark gradient/scrim/stripes and all
// overlay chrome live in ClubDetailView's hero foreground — this struct is
// only the underlying image layer.

struct ClubHeroView: View {
    /// Single source of truth: banner width ÷ height.
    /// This ratio is shared with ImageCropSheet so the crop preview
    /// matches exactly what renders in the club header (WYSIWYG).
    static let bannerAspectRatio: CGFloat = 1.5

    let club: Club

    var body: some View {
        GeometryReader { geo in
            if let customURL = club.customBannerURL {
                AsyncImage(url: customURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        // AsyncImage failure → fall back to the curated
                        // HeroSurface for this club rather than a stale
                        // preset image. Same surface the no-banner path
                        // would render, so the visual identity is stable.
                        HeroSurface.forClub(
                            club,
                            lighting: .topRight,
                            vignette: .none,
                            direction: .diagonal
                        )
                    default:
                        Color.black.opacity(0.6)
                    }
                }
                // Force AsyncImage to rebuild when the URL changes so the old
                // cached image does not flash briefly before the new one loads.
                .id(customURL)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            } else {
                HeroSurface.forClub(
                    club,
                    lighting: .topRight,
                    vignette: .none,
                    direction: .diagonal
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        }
    }
}

// MARK: - Club Detail View

struct ClubDetailView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BookadinkV2", category: "ClubDetailView")
    private static let maxRenderableDetailTextLength = 1600
    private static let maxDisplayNameLength = 120
    private static let maxAddressLength = 260
    private static let maxDescriptionLength = 2000
    private static let maxContactLength = 320
    private static let maxWebsiteLength = 260
    private static let maxManagerLength = 160
    private static let maxTagLength = 40

    /// Hero block height — anchors the parallax background and the
    /// position the bridge avatar straddles. Trimmed from the original
    /// 340pt to ~280pt so first-fold content (Upcoming Games) is visible
    /// sooner. The bridge composition (avatar size, overlap ratio, font
    /// weights) is preserved at the same metrics — only the empty
    /// atmospheric region above the avatar is reduced.
    private static let heroHeight: CGFloat = 280

    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let club: Club

    @State private var isShowingInviteSheet = false
    @State private var isDashboardPresented = false
    @State private var editingOwnerGame: Game?
    @State private var ownerDeleteGameCandidate: Game?
    @State private var duplicatingGame: Game?

    @State private var aboutExpanded = false
    @State private var showBookGame = false
    @State private var reviewsExpanded = false
    @State private var shakeBookGame = false
    @State private var navigateToChat = false
    @State private var showLeaveClubConfirm = false
    @State private var showCancelRequestConfirm = false
    @State private var showPinCapAlert = false
    @State private var showConductSheet = false
    @State private var showCancellationPolicySheet = false
    @State private var pendingConductDate: Date? = nil
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Raw scroll offset captured from the underlying UIScrollView:
    ///   + N → user scrolled up by N (collapse / parallax region)
    ///   − N → user pulled past rest by N (pull-to-refresh region)
    ///     0 → at rest
    /// Single source of truth — all derived values below
    /// (`collapseProgress`, `heroParallaxOffset`, `pullDownAmount`)
    /// are pure functions of this. The reader writes are dispatched
    /// async to main so the assignment cannot land during a SwiftUI
    /// view update (KVO `.initial` can fire mid-render commit).
    @State private var scrollOffset: CGFloat = 0

    /// Normalised hero collapse progress driven by scroll offset.
    /// 0 = fully expanded, 1 = fully collapsed. Every animation curve
    /// below is derived from this value via `interp(_:start:end:)`. No
    /// threshold booleans, no separate expanded/collapsed state.
    private var collapseProgress: CGFloat {
        let upward = max(scrollOffset, 0)
        return min(upward / Self.collapseDistance, 1)
    }

    /// Vertical offset applied to `fixedHeroBackground` for parallax.
    /// Locked in lockstep with `collapseProgress` from the same scroll
    /// reading, so the hero drifts upward at ~30% of scroll speed (capped
    /// at `heroHeight`) — feels attached to the page, never pinned to
    /// the screen, never bouncy on pull-to-refresh (clamps to 0).
    private var heroParallaxOffset: CGFloat {
        let upward = max(scrollOffset, 0)
        return -min(upward, Self.heroHeight) * 0.30
    }

    /// Positive distance the user has pulled the ScrollView down past
    /// its rest position (pull-to-refresh region). Drives two coordinated
    /// counter-translations so the bridge identity / sheet edge feel
    /// anchored rather than dragged 1:1 with the pull:
    ///   • `scrollColumn` is offset upward by 80% of the pull (so the
    ///     bridge + sheet only appear to move at 20% of finger speed)
    ///   • `fixedHeroBackground` stretches downward by the matching 20%
    ///     so the hero ↔ sheet seam stays continuous (no appBackground
    ///     gap opens between the hero bottom and the sheet top).
    private var pullDownAmount: CGFloat {
        max(-scrollOffset, 0)
    }

    /// Transient acknowledgement shown briefly after a pull-to-refresh
    /// completes. Drives the "Games up-to-date" pill in the upcoming
    /// games section so the user gets positive confirmation that their
    /// pull resolved (regardless of whether new games actually arrived).
    /// Auto-dismissed by `refreshAckToken` after ~1.8s.
    @State private var refreshAckVisible: Bool = false
    /// Token used to invalidate older auto-dismiss tasks if the user
    /// pulls again before the previous ack has timed out — only the
    /// most recent pull's ack should hide itself.
    @State private var refreshAckToken: UUID = UUID()

    /// Visual movement ratio applied during pull-to-refresh. The hero
    /// stretches by this fraction; the sheet/bridge moves by this same
    /// fraction (counter-offset is `1 - pullDampening`). At 0.20 the pull
    /// felt over-anchored — fingers moved much faster than content. At
    /// 0.35 the seam still travels less than the finger (so it doesn't
    /// read as a 1:1 drag), but the resistance feels native rather than
    /// stiff.
    private static let pullDampening: CGFloat = 0.35

    /// Pixels of upward scroll over which the hero collapses into the
    /// compact header. Scales with `heroHeight` (~65% of it) so the
    /// transition completes well before the hero fully scrolls off.
    private static let collapseDistance: CGFloat = 180

    /// Linear interpolation helper. Returns 0 below `start`, 1 above `end`,
    /// linear in-between. Used to drive every choreographed curve from a
    /// single `collapseProgress` value with explicit start/end keyframes.
    private func interp(_ progress: CGFloat, start: CGFloat, end: CGFloat) -> CGFloat {
        guard end > start else { return progress >= end ? 1 : 0 }
        return min(max((progress - start) / (end - start), 0), 1)
    }

    // MARK: Choreography curves
    //
    // The expanded title and compact title are spatially far apart (hero
    // position vs. nav position) so a brief crossfade reads as one
    // continuous identity handoff. The avatar, by contrast, is the same
    // identity element drawn twice — its handoff must not overlap, or
    // the user briefly sees two avatars at slightly different sizes/
    // positions. So the avatar curves are sequenced (bridge fades all
    // the way out before the compact one fades in), while the title
    // curves overlap a little. Timing keyframes:
    //
    //   bridge title opacity    : 1 → 0   on 0.00 … 0.48   (commits early so
    //                                                       it never appears
    //                                                       outside the
    //                                                       compact bar)
    //   bridge title scale      : 1 → 0.94 on 0.00 … 0.65
    //   bridge title yOffset    : 0 → -16pt on 0.00 … 0.65
    //   bridge avatar opacity   : 1 → 0   on 0.00 … 0.75   (avatar handoff
    //                                                       intentionally
    //                                                       slower — Phase 9
    //                                                       sequencing)
    //   compact avatar opacity  : 0 → 1   on 0.70 … 1.00   (≥0.70 — bridge ~gone)
    //   compact title opacity   : 0 → 1   on 0.42 … 0.85   (small 0.42…0.48
    //                                                       overlap with
    //                                                       bridge fade)
    //   compact identity scale  : 0.92 → 1 on 0.42 … 0.85
    //   compact material        : 0 → 1   on 0.30 … 0.70   (commits with the
    //                                                       title so the bar
    //                                                       isn't a floating
    //                                                       label)

    private var expandedIdentityScale: CGFloat {
        1 - 0.06 * interp(collapseProgress, start: 0, end: 0.65)
    }
    private var expandedIdentityYOffset: CGFloat {
        -16 * interp(collapseProgress, start: 0, end: 0.65)
    }
    /// Bridge title block (name + descriptor + meta + role chip). Fades
    /// out early (by progress 0.48) so it has fully committed to invisible
    /// before the compact bar's title commits to visible — eliminates the
    /// "title appears outside / below the compact header" perception. The
    /// avatar handoff is deliberately slower (see `bridgeAvatarOpacity`).
    private var bridgeTitleOpacity: Double {
        Double(1 - interp(collapseProgress, start: 0, end: 0.48))
    }
    /// Bridge avatar — fades all the way out by 0.75 so it has fully
    /// vanished before the compact avatar starts fading in at 0.70 (the
    /// 0.05 overlap is below visual perception threshold for two
    /// adjacent avatars, in practice the user only ever sees one).
    private var bridgeAvatarOpacity: Double {
        Double(1 - interp(collapseProgress, start: 0, end: 0.75))
    }

    /// Compact avatar — held off until 0.70 so the bridge avatar is
    /// nearly invisible before this one starts to commit. Avoids the
    /// "two avatars on screen at once" perception that triggered the
    /// Phase 9 fix.
    private var compactAvatarOpacity: Double {
        Double(interp(collapseProgress, start: 0.70, end: 1.0))
    }
    /// Compact title (and the back / gear chrome). Overlaps the bridge
    /// title fadeout very briefly (0.42…0.48) — small enough that the
    /// titles don't read as two duelling labels, but enough that the
    /// transition isn't a hard cut.
    private var compactTitleOpacity: Double {
        Double(interp(collapseProgress, start: 0.42, end: 0.85))
    }
    private var compactIdentityScale: CGFloat {
        0.92 + 0.08 * interp(collapseProgress, start: 0.42, end: 0.85)
    }
    private var compactBackgroundOpacity: Double {
        // Reaches full opacity by progress 0.55 — well before the bridge
        // title finishes fading (0.48) so by the time anything is
        // scrolling under the bar zone, the bar is already opaque enough
        // to fully hide it. No more "title visible inside compact bar".
        Double(interp(collapseProgress, start: 0.18, end: 0.55))
    }

    // MARK: - Body decomposition
    //
    // The view body is intentionally split into small computed properties
    // so the Swift type-checker can resolve each piece independently. A
    // single monolithic body containing the ScrollView, all its modifiers,
    // the overlay, and the bottom `floatingCTABar` exceeded the
    // type-checker's reasonable-time budget.

    /// The scrolling column (hero + banners + sections) wrapped in a
    /// ScrollView with the named coordinate space, refreshable, and the
    /// compact-header overlay. Lives in its own property so the body
    /// stays trivially typed.
    private var scrollableContent: some View {
        ScrollView {
            // Scroll-offset probe — must live inside the ScrollView so
            // its UIView lands as a descendant of the underlying
            // UIScrollView and can KVO-observe its `contentOffset`. The
            // iOS-18 `.onScrollGeometryChange` modifier would be cleaner
            // but it's gated by deployment target; the named-
            // coordinate-space + PreferenceKey reader couldn't see
            // pull-to-refresh translation, which is what we need here.
            ScrollOffsetReader { offset in
                // `offset` is contentOffset.y + adjustedContentInset.top,
                // i.e. logical position relative to the natural rest:
                //   + N → user scrolled up by N (collapse / parallax)
                //   − N → user pulled past rest by N (pull-to-refresh)
                //     0 → at rest
                //
                // The KVO observation inside `ScrollOffsetReader` can fire
                // synchronously during the UIView's `didMoveToSuperview` /
                // `didMoveToWindow` callbacks (notably with `options: .initial`),
                // which happen during SwiftUI's render commit. Writing
                // @State synchronously here would land mid-render and
                // produce "Modifying state during view update" warnings.
                // Dispatching async to main pushes the write past the
                // current render pass; subsequent scroll-driven firings are
                // already off the render pass so the dispatch is a one-tick
                // no-op for the common case. The equality guard prevents
                // redundant publishes when the KVO observer reports the
                // same value (e.g. settling at rest).
                DispatchQueue.main.async {
                    if scrollOffset != offset {
                        scrollOffset = offset
                    }
                }
            }
            .frame(height: 0)

            scrollColumn
        }
        .refreshable {
            // `refreshClubs()` internally awaits `refreshMemberships()` once
            // it's done (see AppState), so we don't call it explicitly here
            // — doing both runs the membership fetch twice in quick
            // succession, which can flap `membershipStatesByClubID` mid-
            // pull and cancel in-flight URLSession tasks belonging to the
            // sibling refreshes (which surfaces as the "Upcoming Games"
            // network error). One source of truth for memberships per pull.
            await appState.refreshClubs()
            await appState.refreshClubAdminRole(for: club)
            await appState.refreshGames(for: club)
            await appState.fetchReviews(for: club.id)
            await appState.refreshCreditBalance(for: club.id)

            // Positive acknowledgement — show "Games up-to-date" briefly so
            // the pull feels resolved even when nothing new arrived. The
            // token guards against a stale auto-dismiss firing after the
            // user pulls again before the previous ack times out.
            let token = UUID()
            refreshAckToken = token
            withAnimation(.easeInOut(duration: 0.18)) {
                refreshAckVisible = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if refreshAckToken == token {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            refreshAckVisible = false
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        // The ScrollView itself is transparent so `fixedHeroBackground`
        // shows through behind the hero-foreground placeholder. Sections
        // below the hero carry their own solid background (see
        // `scrollContentCard`) so they mask the fixed hero as they rise.
        // Compact sticky identity header — pinned to the top of the
        // ScrollView's overlay area so it stays in place as the hero
        // scrolls underneath it.
        .overlay(alignment: .top) {
            // The bar carries its own internal opacity curves (material
            // backdrop, avatar, title, and chrome buttons fade
            // independently) — no outer opacity here, just a hit-test
            // gate that opens once the title is past 50% visible
            // (midpoint of the 0.42…0.85 title curve ≈ 0.64). Below
            // that, taps fall through to the expanded hero so the
            // sticky bar can't intercept gestures while it's still
            // mostly invisible.
            compactCollapsedHeader
                .allowsHitTesting(collapseProgress > 0.64)
        }
    }

    /// The vertical content stack inside the ScrollView. The first child
    /// is the hero foreground placeholder (transparent, sized to the
    /// hero) — its background carries the only geometry probe. The
    /// second child is the content card (banners + sections) on a solid
    /// background so it visually covers the fixed hero as it rises.
    @ViewBuilder
    private var scrollColumn: some View {
        VStack(spacing: 0) {
            heroForeground

            scrollContentCard
                // 1pt negative top inset preserves the original
                // hero-to-content overlap and removes any sub-pixel seam
                // between the fixed hero and the rising content card.
                .padding(.top, -1)
        }
        .padding(.bottom, 130)
        // Pull-to-refresh dampening — counter-translates the entire
        // scroll column upward by (1 - pullDampening) × pull distance,
        // so the bridge identity, sheet edge, and content beneath it
        // appear anchored (moving only at `pullDampening` × finger
        // speed) instead of being dragged 1:1 with the gesture. Render
        // transform only — does not affect layout, so the underlying
        // scroll offset (and therefore `collapseProgress`) is unchanged.
        .offset(y: -pullDownAmount * (1 - Self.pullDampening))
    }

    /// Solid-background content card that sits below the hero foreground
    /// and visually rises over the fixed hero as the user scrolls. The
    /// rounded top corners + subtle lifted shadow give the card a sheet
    /// feel — content reads as continuous with the hero, not as a flat
    /// list slapped underneath. `Brand.appBackground` is applied via a
    /// rounded background shape (not as a clip) so the section content
    /// inside isn't clipped at the corners.
    private static let contentSheetCornerRadius: CGFloat = 22

    @ViewBuilder
    private var scrollContentCard: some View {
        VStack(spacing: 0) {
            // Bridge identity — the first child on the sheet. Avatar
            // straddles the hero / sheet seam (drawn outside the sheet's
            // top edge via a transform) and the title + descriptor +
            // meta + role chip read against the sheet rather than the
            // hero. This is what makes the hero ↔ content transition
            // feel like one connected surface.
            bridgeIdentityBlock

            // Membership feedback banner — real state, kept above the fold.
            if let msg = membershipFeedbackMessage {
                membershipBanner(msg: msg)
            }

            // Credit balance banner — only when the user holds credits at this club.
            let clubCredit = appState.creditBalance(for: club.id)
            if clubCredit > 0 {
                creditBanner(amountCents: clubCredit)
            }

            upcomingGamesSection
            aboutCardSection
            reviewsCardSection
            locationCardSection

            Color.clear.frame(height: 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: Self.contentSheetCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Self.contentSheetCornerRadius,
                style: .continuous
            )
            .fill(Brand.appBackground)
            // Subtle lift shadow above the sheet edge — gives the
            // hero-to-content transition a defined seam without a hard
            // line. Below the visible cutoff in any direction, the
            // shadow disappears under content.
            .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: -2)
        )
    }

    /// Always reads the latest in-memory version of this club so fields like
    /// codeOfConduct reflect the most recent fetch, not the navigation-time snapshot.
    private var liveClub: Club {
        appState.clubs.first(where: { $0.id == club.id }) ?? club
    }

    private var allClubGames: [Game] {
        appState.games(for: club)
    }

    private var safeClubName: String {
        cappedDisplayText(club.name, maxLength: Self.maxDisplayNameLength)
    }

    private var safeAddress: String {
        let full = club.formattedAddressFull
        return cappedDisplayText(full.isEmpty ? club.address : full, maxLength: Self.maxAddressLength)
    }

    /// Primary ClubVenue for the contact section — used for venue name, structured address, and map navigation.
    private var primaryVenueForContact: ClubVenue? {
        appState.clubVenuesByClubID[club.id]?.first(where: { $0.isPrimary })
    }

    /// Best available coordinate for map navigation: primary venue → club → nil.
    private var clubMapCoordinate: CLLocationCoordinate2D? {
        if let v = primaryVenueForContact, let lat = v.latitude, let lng = v.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        if let lat = club.latitude, let lng = club.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        return nil
    }

    /// Apple Maps URL: coordinate-based when available, string-address fallback.
    private var clubMapURL: URL? {
        if let coord = clubMapCoordinate {
            return MapNavigationURL.directions(to: coord)
        }
        return MapNavigationURL.directions(to: safeAddress)
    }

    private var safeDescription: String {
        cappedDisplayText(club.description, maxLength: Self.maxDescriptionLength)
    }

    private var safeContactEmail: String {
        cappedDisplayText(club.contactEmail, maxLength: Self.maxContactLength)
    }

    private var safeContactPhone: String? {
        trimmedOptional(cappedDisplayText(club.contactPhone ?? "", maxLength: 30))
    }

    private var safeManagerName: String? {
        trimmedOptional(cappedDisplayText(club.managerName ?? "", maxLength: Self.maxManagerLength))
    }

    private var filteredClubGames: [Game] {
        allClubGames
            .filter { $0.status != "cancelled" }
            .filter { $0.dateTime >= now }
            .filter { isClubAdminUser || ($0.publishAt == nil || $0.publishAt! <= now) }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var isClubAdminUser: Bool {
        appState.isClubAdmin(for: club)
    }

    private var isMemberOrAdmin: Bool {
        if isClubAdminUser { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown: return true
        default: return false
        }
    }

    /// Hero descriptor: prefer the primary venue's suburb, then club's suburb /
    /// city, then the legacy display string. Returns "" when nothing is set so
    /// the row hides cleanly.
    private var heroDescriptor: String {
        if let venue = primaryVenueForContact {
            if let suburb = venue.suburb?.trimmingCharacters(in: .whitespacesAndNewlines), !suburb.isEmpty {
                return suburb
            }
        }
        if let suburb = club.suburb?.trimmingCharacters(in: .whitespacesAndNewlines), !suburb.isEmpty {
            return suburb
        }
        let city = club.city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty { return city }
        let region = club.region.trimmingCharacters(in: .whitespacesAndNewlines)
        return region
    }

    /// Reviews sorted with highest-rated first (most recent breaks ties).
    private var sortedReviews: [GameReview] {
        let reviews = appState.reviewsByClubID[club.id] ?? []
        return reviews.sorted { lhs, rhs in
            if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            let l = lhs.createdAt ?? .distantPast
            let r = rhs.createdAt ?? .distantPast
            return l > r
        }
    }

    private var avgRating: Double? {
        let reviews = appState.reviewsByClubID[club.id] ?? []
        guard !reviews.isEmpty else { return nil }
        return Double(reviews.reduce(0) { $0 + $1.rating }) / Double(reviews.count)
    }

    /// Stable per-club hue 0...360 used for the gradient fallback when the
    /// club has no custom banner. Derived deterministically from the UUID so
    /// the same club always paints the same colour across launches.
    private var clubHue: Double {
        let bytes = withUnsafeBytes(of: club.id.uuid) { Array($0) }
        let seed = bytes.reduce(0) { Int($0) &+ Int($1) }
        return Double(seed % 360)
    }

    private var pendingJoinRequestCount: Int {
        appState.ownerJoinRequests(for: club).count
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Layer 1: the hero surface itself — fixed at the top of the
            // screen, never scrolls. The scrolling content layer above
            // covers it as the user pulls content up. This is the
            // Facebook-style parallax structure: hero is *behind* the
            // ScrollView, not part of it.
            fixedHeroBackground

            // Layer 2: scrolling content. Starts with the hero foreground
            // (chrome + title + role badge) as a transparent placeholder
            // sized to the hero height — through which `fixedHeroBackground`
            // is visible — then continues with banners + sections on a
            // solid background card so they mask the hero as they rise.
            scrollableContent

            // Layer 3: existing bottom action bar — unchanged.
            floatingCTABar
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $isDashboardPresented) {
            ClubDashboardView(club: club)
                .environmentObject(appState)
        }
        .sheet(item: $editingOwnerGame) { game in
            OwnerEditGameSheet(club: club, game: game, initialVenues: appState.venues(for: club)).environmentObject(appState)
        }
        .sheet(item: $duplicatingGame) { game in
            OwnerCreateGameSheet(club: club, initialDraft: nextWeekDraft(from: game)).environmentObject(appState)
        }
        .sheet(isPresented: $showBookGame) {
            ClubBookGameView(club: club).environmentObject(appState)
        }
        .sheet(isPresented: $showConductSheet) {
            ConductAcceptanceSheet(club: liveClub) {
                let conductDate = Date()
                if liveClub.cancellationPolicy?.isEmpty == false {
                    pendingConductDate = conductDate
                    showCancellationPolicySheet = true
                } else {
                    Task { await appState.requestMembership(for: club, conductAcceptedAt: conductDate) }
                }
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showCancellationPolicySheet) {
            CancellationPolicyAcceptanceSheet(club: liveClub) {
                let conductDate = pendingConductDate
                pendingConductDate = nil
                Task { await appState.requestMembership(for: club, conductAcceptedAt: conductDate, cancellationPolicyAcceptedAt: Date()) }
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete Game?",
            isPresented: Binding(
                get: { ownerDeleteGameCandidate != nil },
                set: { if !$0 { ownerDeleteGameCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let game = ownerDeleteGameCandidate {
                if game.recurrenceGroupID != nil {
                    Button("Delete This Event", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .singleEvent)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                    Button("Delete This & Future", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .thisAndFuture)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                    Button("Delete Entire Series", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .entireSeries)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                } else {
                    Button("Delete Game", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .singleEvent)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { ownerDeleteGameCandidate = nil }
        } message: {
            // Append a credit-issuance warning when the visible instance has
            // paid bookings. For series-scope deletes the server cancels each
            // target idempotently — paid players in any affected instance get
            // refunded regardless of which scope the admin picks.
            if let game = ownerDeleteGameCandidate {
                let paid = (appState.attendeesByGameID[game.id] ?? []).filter { attendee in
                    guard case .confirmed = attendee.booking.state else { return false }
                    return attendee.booking.feePaid && attendee.booking.paymentMethod == "stripe"
                }.count
                if paid > 0 {
                    Text("\(game.title)\nPaid players will be issued club credit.")
                } else {
                    Text(game.title)
                }
            } else {
                Text("This cannot be undone.")
            }
        }
        .confirmationDialog("Leave club?", isPresented: $showLeaveClubConfirm, titleVisibility: .visible) {
            Button("Leave Club", role: .destructive) {
                Task { await appState.removeMembership(for: club) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Cancel membership request?", isPresented: $showCancelRequestConfirm, titleVisibility: .visible) {
            Button("Cancel Request", role: .destructive) {
                Task { await appState.removeMembership(for: club) }
            }
            Button("Keep", role: .cancel) {}
        }
        .alert("Pinned Clubs Full", isPresented: $showPinCapAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can pin up to 3 clubs. Unpin one to add this club.")
        }
        .onAppear {
            Self.logger.info("open_club_detail club_id=\(club.id.uuidString, privacy: .public) name=\(safeClubName, privacy: .public)")
            Task { await appState.refreshMemberships() }
            Task { await appState.refreshClubAdminRole(for: club) }
            Task { await appState.refreshGames(for: club) }
            Task { await appState.fetchReviews(for: club.id) }
            Task { await appState.refreshCreditBalance(for: club.id) }
            // If we already know the user is an admin (cached from a prior session), fetch requests now.
            if appState.isClubAdmin(for: club) {
                Task { await appState.refreshOwnerJoinRequests(for: club) }
            }
        }
        .onChange(of: appState.lastCancellationCredit) { _, result in
            // When a credit is issued for this club, refresh the balance immediately
            // so the banner updates without the user having to pull-to-refresh.
            guard result?.clubID == club.id else { return }
            Task { await appState.refreshCreditBalance(for: club.id) }
        }
        .onChange(of: isClubAdminUser) { _, newValue in
            // Fires when the admin role resolves asynchronously on first open.
            if newValue {
                Task { await appState.refreshOwnerJoinRequests(for: club) }
            }
        }
        .onReceive(minuteTick) { now = $0 }
        .onDisappear {
            Self.logger.info("close_club_detail club_id=\(club.id.uuidString, privacy: .public)")
        }
        .onChange(of: appState.clubs) { _, newClubs in
            if !newClubs.contains(where: { $0.id == club.id }) { dismiss() }
        }
        // Game push destinations are resolved centrally in MainTabView's
        // `.navigationDestination(for: AppRoute.self)`. Pushing here is done
        // via `appState.navigate(to: .game(...))`, never via a per-view
        // navigationDestination — that's how the Game ↔ Club ping-pong loop
        // used to form (each ClubDetailView added another destination handler
        // and each push grew the implicit stack).
        .navigationDestination(isPresented: $navigateToChat) {
            ClubNewsView(club: club, isClubModerator: appState.isClubAdmin(for: club))
                .environmentObject(appState)
                .navigationBarBackButtonHidden(true)
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { navigateToChat = false } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }

    // MARK: - Hero (split into fixed back layer + scrolling foreground)
    //
    // `fixedHeroBackground` is the bottom layer of the body's outer
    // ZStack — it never scrolls. `heroForeground` is the FIRST item in
    // the scrolling content tree — a transparent placeholder sized to
    // the hero, on which the chrome (back / settings) and identity
    // content (title, descriptor, meta, role badge) ride. As the user
    // scrolls upward the foreground rises off the fixed background and
    // is replaced from below by the solid-background `scrollContentCard`.

    /// Fixed hero surface (uploaded banner image OR curated HeroSurface).
    /// Pinned to the top of the body's ZStack at exactly `heroHeight` and
    /// hit-test disabled so taps on this region pass through to the
    /// chrome buttons living in `heroForeground` above it.
    private var fixedHeroBackground: some View {
        heroBackground
            // Height stretches downward during pull-to-refresh by
            // exactly `pullDampening` × pull, so the hero's bottom edge
            // tracks the bridge/sheet's dampened movement and there's
            // no gap at the seam. At rest (and during upward scroll)
            // pullDownAmount = 0 so this collapses to the static
            // `heroHeight`.
            .frame(height: Self.heroHeight + pullDownAmount * Self.pullDampening)
            // Parallax — drifts upward at 30% of scroll speed (clamped).
            // Applied before the alignment-fill frame so the offset
            // interpolates the visual position of the hero, not the
            // outer container.
            .offset(y: heroParallaxOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    /// Scrolling hero foreground — just the chrome (back / settings)
    /// over a transparent placeholder sized to the hero. The expanded
    /// identity (avatar, title, descriptor, meta, role chip) lives in
    /// `bridgeIdentityBlock` instead, where it can hug the sheet edge
    /// and have the avatar straddle the hero / sheet seam — that's what
    /// makes the transition feel like one connected surface rather than
    /// two stacked elements.
    private var heroForeground: some View {
        ZStack(alignment: .topLeading) {
            // Transparent placeholder — sized so the ScrollView's first
            // item occupies the hero region exactly. Lets the fixed
            // background layer below show through.
            Color.clear

            // Top chrome — back button + settings menu.
            VStack {
                HStack {
                    glassNavButton(systemName: "chevron.left", action: { dismiss() })
                        .accessibilityLabel("Back")
                    Spacer()
                    settingsMenu
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                Spacer()
            }
            .padding(.top, safeAreaTopPad)
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bridge identity block
    //
    // The "bridge" is the identity composition that ties hero ↔ sheet:
    //
    //   ┌──────── hero region ────────┐
    //   │                             │
    //   │            ┌──────┐         │
    //   │            │      │ ← avatar straddles the seam (half on hero,
    //   │            │  ⌂   │   half on sheet) so the visual surface feels
    //   │            │      │   continuous instead of two stacked layers.
    //   ├────────────└──────┘─────────┤  ← rounded sheet edge
    //   │  Club Name                  │
    //   │  SUBURB                     │
    //   │  ★ 4.6 (12) · 87 members    │
    //   │  ───────────────────────    │
    //   │  Upcoming Games …           │
    //
    // The identity content scrolls with the sheet (it's at the top of
    // `scrollContentCard`), and the same choreographed opacity / scale /
    // y-offset curves now apply to the *bridge* — anchored to its top-
    // leading corner so it shrinks toward the avatar's position, which
    // is where the compact bar's identity row continues from.

    /// Avatar size used by the bridge block. The avatar straddles the
    /// hero / sheet seam — `bridgeAvatarOverlap` is how far it visually
    /// rises above the sheet's top edge into the hero region.
    private static let bridgeAvatarSize: CGFloat = 76
    private static let bridgeAvatarOverlap: CGFloat = 38

    private var bridgeIdentityBlock: some View {
        ZStack(alignment: .topLeading) {
            // Identity column — sits on the sheet. The top padding
            // reserves vertical space for the avatar to drop into; the
            // avatar itself is offset upward via a transform below so
            // half of it overlaps the hero region.
            //
            // The title column carries its own opacity curve (faster
            // fadeout than the avatar) so the avatar can stay anchored
            // on the seam slightly longer — mirroring how the compact
            // avatar is the last identity element to commit on the way
            // in. Using a single outer opacity here would force the
            // avatar to vanish on the same curve as the title and
            // re-introduce the duplicate-avatar overlap during the
            // 0.55 … 0.85 window where both compact and bridge avatars
            // would otherwise be partially visible.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(safeClubName)
                        .font(.system(size: 26, weight: .heavy))
                        .kerning(-0.4)
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)

                    if let roleLabel = roleBadgeLabel {
                        roleBadgeChip(label: roleLabel)
                            .alignmentGuide(.firstTextBaseline) { d in
                                d[VerticalAlignment.center]
                            }
                    }
                }

                if !heroDescriptor.isEmpty {
                    Text(heroDescriptor.uppercased())
                        .font(.system(size: 11.5, weight: .heavy))
                        .kerning(1.0)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }

                bridgeMetaRow
                    .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            // Reserve room above the title for the avatar's visible half
            // (everything below the seam) plus a tighter gap — the
            // empty atmospheric region above the identity is reduced so
            // first-fold content surfaces sooner without compressing
            // the bridge composition itself.
            .padding(.top, Self.bridgeAvatarSize - Self.bridgeAvatarOverlap + 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(bridgeTitleOpacity)

            // Avatar — sits at the top-leading of the ZStack and is
            // visually offset upward so half of it crosses into the
            // hero. Drawn with a thick `Brand.appBackground` border so
            // there's a clean halo where it overlaps the hero, plus a
            // soft drop-shadow that reads on both the hero and the sheet.
            ClubImageBadge(club: liveClub)
                .frame(width: Self.bridgeAvatarSize, height: Self.bridgeAvatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Brand.appBackground, lineWidth: 4)
                )
                .shadow(color: .black.opacity(0.18), radius: 7, y: 2)
                .padding(.leading, 18)
                .offset(y: -Self.bridgeAvatarOverlap)
                .opacity(bridgeAvatarOpacity)
        }
        // Outer transform applies to the entire ZStack so the avatar +
        // title shrink and lift toward the leading edge as one unit,
        // pointing at the compact bar's identity row. No outer opacity
        // here — the per-element opacity curves above handle the
        // sequenced handoff.
        .scaleEffect(expandedIdentityScale, anchor: .topLeading)
        .offset(y: expandedIdentityYOffset)
    }

    /// Identity metadata row — uses `Brand.primaryText` /
    /// `Brand.secondaryText` so it reads against the light content sheet
    /// rather than against the hero. ★ rating · members count · pinned
    /// indicator (when applicable).
    private var bridgeMetaRow: some View {
        HStack(spacing: 8) {
            if let avg = avgRating {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "F5B70A"))
                    Text(String(format: "%.1f", avg))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                    let count = appState.reviewsByClubID[club.id]?.count ?? 0
                    Text("(\(count))")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.secondaryText)
                }
                Text("·").foregroundStyle(Brand.tertiaryText)
            }

            HStack(spacing: 5) {
                Text("\(club.memberCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                Text(club.memberCount == 1 ? "member" : "members")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
            }

            if appState.isClubPinned(club) {
                Text("·").foregroundStyle(Brand.tertiaryText)
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Pinned")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Brand.secondaryText)
            }
        }
    }

    /// Owner / Admin chip rendered next to the title in the bridge
    /// identity block. `Brand.primaryText` over `Brand.secondarySurface`
    /// so it reads on the light sheet rather than over the hero.
    private func roleBadgeChip(label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "crown.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Brand.sportPop)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .kerning(0.4)
                .foregroundStyle(Brand.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Brand.secondarySurface, in: Capsule())
        .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 0.5))
    }

    @ViewBuilder
    private var heroBackground: some View {
        // Read from `liveClub` (the in-memory cached copy in AppState),
        // not the navigation-time `club` snapshot. After an owner saves a
        // new palette / pattern / banner via the Appearance sheet,
        // `appState.clubs[index]` is patched in place — using `liveClub`
        // here means the hero re-renders immediately without requiring
        // the user to navigate away and back.
        let renderClub = liveClub
        if renderClub.customBannerURL != nil {
            // Uploaded photograph — heavy scrim preserved exactly as before
            // (clear → 0.55 mid → 0.78 bottom) so any bright image still
            // yields a readable title block. Behaviour intentionally
            // unchanged from the pre-HeroSurface era.
            ClubHeroView(club: renderClub)
                .overlay(Color.black.opacity(0.30))
                .overlay(uploadedBannerLegibilityScrim)
        } else {
            // Curated HeroSurface with `.bottomStrong` vignette baked in.
            // No additional global scrim — the surface's own lighting +
            // bottom fade handles legibility without darkening the upper
            // half of the hero. Pinned palette/pattern when the owner has
            // selected them, deterministic auto-rotation otherwise.
            HeroSurface.forClub(
                renderClub,
                lighting: .topRight,
                vignette: .bottomStrong,
                direction: .diagonal
            )
        }
    }

    /// Compact sticky identity header. Pinned at the top of the screen
    /// via `scrollableContent`'s `.overlay(alignment: .top)`. Splits its
    /// choreography across four independent curves so the handoff from
    /// the expanded hero reads as one continuous identity element
    /// rather than as two avatars / two titles briefly co-existing:
    ///
    ///   • material backdrop : fades in 0.45 … 0.85
    ///   • compact title +
    ///     back / gear chrome : fades + scales in 0.55 … 1.00
    ///   • compact avatar    : fades in 0.70 … 1.00 (held off so the
    ///                         bridge avatar is ~gone before this one
    ///                         starts to commit — no duplicate avatar)
    ///
    /// Action wiring is shared with the expanded hero via
    /// `settingsMenuContent` and a single `dismiss()` — no duplicate
    /// buttons exist in the view tree at the same time, since the
    /// expanded chrome scrolls off naturally and the compact chrome is
    /// hit-disabled until the title is past 50% visible.
    private var compactCollapsedHeader: some View {
        ZStack(alignment: .top) {
            // Solid backdrop + hairline divider. Brand.appBackground sits
            // beneath a thin material so once `compactBackgroundOpacity`
            // commits the bar is fully opaque — scroll content beneath
            // (upcoming-games carousel cards, bridge title, hero) can no
            // longer bleed through. A pure `.regularMaterial` was used
            // earlier and proved too translucent: at full collapse the
            // user could still read the carousel through the bar, which
            // gave the impression that the bridge title was floating
            // *inside* the compact header rather than being hidden by it.
            ZStack {
                Brand.appBackground
                Rectangle().fill(.regularMaterial).opacity(0.35)
            }
            .frame(height: safeAreaTopPad + 52)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Brand.softOutline.opacity(0.55))
                    .frame(height: 0.5)
            }
            .opacity(compactBackgroundOpacity)
            .ignoresSafeArea(edges: .top)

            // Bar content: back button | (avatar + title) | gear.
            // The avatar carries `compactAvatarOpacity` (held off until
            // 0.70) while the title + chrome share `compactTitleOpacity`
            // (overlaps the bridge fadeout at 0.55) — split because the
            // avatar is the same identity element drawn twice and must
            // not visually overlap with the bridge avatar, but the
            // titles are spatially distant and benefit from the brief
            // crossfade reading as one continuous title.
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .opacity(compactTitleOpacity)

                HStack(spacing: 10) {
                    ClubImageBadge(club: liveClub)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .opacity(compactAvatarOpacity)

                    Text(safeClubName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(compactTitleOpacity)
                }
                .scaleEffect(compactIdentityScale, anchor: .leading)

                Spacer(minLength: 8)

                compactSettingsMenu
                    .opacity(compactTitleOpacity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            // The overlay's coordinate origin already sits below the
            // status bar — only the Rectangle backdrop extends *up*
            // into the safe area via `.ignoresSafeArea(edges: .top)`.
            // Adding `padding(.top, safeAreaTopPad)` here was applying
            // safe-area inset a second time and pushing the chrome row
            // below the bar's bottom edge (avatar + title + back/gear
            // ended up sitting in the scroll content underneath the bar
            // instead of inside it). No padding needed — the ZStack's
            // top alignment puts the chrome at the correct y already.
        }
    }

    /// Legacy heavy scrim — only applied over uploaded photographic banners
    /// where the underlying image brightness is unknown. HeroSurface
    /// fallbacks render with their own `.bottomStrong` vignette instead.
    private var uploadedBannerLegibilityScrim: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.0),
                Color.black.opacity(0.55),
                Color.black.opacity(0.78),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func glassNavButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var roleBadgeLabel: String? {
        guard isClubAdminUser else { return nil }
        return appState.isClubOwner(for: club) ? "Owner" : "Admin"
    }

    private var safeAreaTopPad: CGFloat {
        // Bring the back/menu chrome below the status bar without using a
        // GeometryReader — the hero ignores safe area, so we offset manually.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 44
    }

    // MARK: - Settings Menu

    /// Menu contents (Manage Club / Share / Pin / Leave / Cancel Request).
    /// Extracted from `settingsMenu` so the compact collapsing header can
    /// reuse the same actions behind a different label without duplicating
    /// the action wiring or risking the two menus drifting apart.
    @ViewBuilder
    private var settingsMenuContent: some View {
        let pinned = appState.isClubPinned(club)
        let state = appState.membershipState(for: club)

        if isClubAdminUser {
            Button {
                isDashboardPresented = true
            } label: {
                Label("Manage Club", systemImage: "square.grid.2x2")
            }
            Divider()
        }

        if let shareURL = clubShareURL {
            ShareLink(item: shareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        Button {
            let success = appState.togglePinClub(club)
            if !success { showPinCapAlert = true }
        } label: {
            Label(pinned ? "Unpin from Home" : "Pin to Home",
                  systemImage: pinned ? "pin.slash" : "pin")
        }

        switch state {
        case .approved:
            Divider()
            Button(role: .destructive) {
                showLeaveClubConfirm = true
            } label: {
                Label("Leave Club", systemImage: "rectangle.portrait.and.arrow.right")
            }
        case .pending:
            Divider()
            Button(role: .destructive) {
                showCancelRequestConfirm = true
            } label: {
                Label("Cancel Request", systemImage: "xmark.circle")
            }
        default:
            EmptyView()
        }
    }

    /// Glass-style gear used inside the expanded hero (white-on-black-glass
    /// over the hero image / HeroSurface).
    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            settingsMenuContent
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                if isClubAdminUser, pendingJoinRequestCount > 0 {
                    Circle()
                        .fill(Brand.errorRed)
                        .frame(width: 9, height: 9)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
        }
        .accessibilityLabel("Club options")
    }

    /// Compact gear used inside the collapsed header (monochrome SF Symbol
    /// over the regular-material backdrop). Same actions as `settingsMenu`.
    @ViewBuilder
    private var compactSettingsMenu: some View {
        Menu {
            settingsMenuContent
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                if isClubAdminUser, pendingJoinRequestCount > 0 {
                    Circle()
                        .fill(Brand.errorRed)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                }
            }
        }
        .accessibilityLabel("Club options")
    }

    private var clubShareURL: URL? {
        URL(string: "https://bookadink.com/club/\(club.id.uuidString.lowercased())")
    }

    // MARK: - Banners (membership feedback / credit)

    private func membershipBanner(msg: (text: String, isError: Bool)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: msg.isError ? "exclamationmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(msg.isError ? Brand.errorRed : Brand.emeraldAction)
            Text(msg.isError ? AppCopy.friendlyError(msg.text) : msg.text)
                .font(.footnote.weight(msg.isError ? .regular : .semibold))
                .foregroundStyle(msg.isError ? Brand.errorRed : Brand.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(msg.isError ? Brand.errorRed.opacity(0.08) : Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(msg.isError ? Brand.errorRed.opacity(0.22) : Brand.softOutline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func creditBanner(amountCents: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.primaryText)
            HStack(spacing: 4) {
                Text(String(format: "$%.2f", Double(amountCents) / 100))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.primaryText)
                Text("credit available")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Section helpers

    private func sectionLabel(_ text: String, accent: Bool = false) -> some View {
        HStack(spacing: 7) {
            if accent {
                Circle()
                    .fill(Brand.sportPop)
                    .frame(width: 5, height: 5)
                    .shadow(color: Brand.sportPop.opacity(0.8), radius: 6)
            }
            Text(text.uppercased())
                .font(.system(size: 11.5, weight: .heavy))
                .kerning(1.4)
                .foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
            .padding(.horizontal, 16)
    }

    // MARK: - Upcoming Games

    private var upcomingGamesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Upcoming games", accent: true)
                .padding(.top, 22)

            // Non-destructive refresh UX:
            //
            //   1. We have games  → render the carousel (always wins).
            //                       After a successful pull-to-refresh,
            //                       the "Games up-to-date" pill appears
            //                       briefly above it. Refresh errors are
            //                       swallowed silently when cached games
            //                       are already on screen — the user
            //                       can pull again and the bar will
            //                       reappear with the same positive
            //                       confirmation when the network comes
            //                       back. Persistent errors still surface
            //                       in the empty state below.
            //   2. No games, error → full error card with Retry.
            //   3. No games, no error → loading spinner or empty state.
            if !filteredClubGames.isEmpty {
                if refreshAckVisible {
                    refreshAcknowledgementPill
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(filteredClubGames) { game in
                            let venues = appState.clubVenuesByClubID[game.clubID] ?? []
                            let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
                            Button {
                                appState.navigate(to: .game(game.id))
                            } label: {
                                UpcomingGameCarouselCard(
                                    game: game,
                                    resolvedVenue: resolvedVenue,
                                    isBooked: appState.bookingState(for: game) == .confirmed,
                                    isScheduled: game.isScheduled
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                }
                .scrollTargetBehavior(.viewAligned)
            } else if let error = appState.clubGamesError(for: club) {
                cardContainer {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Brand.errorRed)
                        Text(AppCopy.friendlyError(error))
                            .font(.footnote)
                            .foregroundStyle(Brand.errorRed)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Retry") {
                            Task { await appState.refreshGames(for: club) }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                    }
                    .padding(14)
                }
            } else if appState.isLoadingGames(for: club) {
                cardContainer {
                    HStack {
                        ProgressView().tint(Brand.secondaryText)
                        Text("Loading games…")
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(18)
                }
            } else {
                if refreshAckVisible {
                    refreshAcknowledgementPill
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                cardContainer {
                    Text("No upcoming games scheduled.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            }
        }
    }

    /// Transient positive confirmation shown briefly after a successful
    /// pull-to-refresh — replaces the previous "Couldn't refresh —
    /// showing latest" chip, which surfaced as a negative even when the
    /// refresh had actually completed (just with no new games to show).
    /// Auto-dismissed by the `refreshAckToken` task in `.refreshable`.
    private var refreshAcknowledgementPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.sportPop)
            Text("Games up to date")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Brand.secondarySurface, in: Capsule())
        .overlay(Capsule().stroke(Brand.softOutline.opacity(0.55), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .accessibilityLabel("Games up to date")
    }

    // MARK: - About Card

    private var aboutCardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("About")
                .padding(.top, 22)

            cardContainer {
                VStack(alignment: .leading, spacing: 8) {
                    if safeDescription.isEmpty {
                        Text("This club hasn't added a description yet.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(safeDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.ink.opacity(0.92))
                            .lineSpacing(2)
                            .lineLimit(aboutExpanded ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if safeDescription.count > 150 || aboutExpanded {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { aboutExpanded.toggle() }
                            } label: {
                                Text(aboutExpanded ? "Show less" : "Show more")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .underline(true, pattern: .solid)
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Reviews Card

    private var reviewsCardSection: some View {
        let reviews = sortedReviews
        let isLoading = appState.loadingReviewsClubIDs.contains(club.id)

        return Group {
            if isLoading && reviews.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Reviews").padding(.top, 22)
                    cardContainer {
                        HStack {
                            ProgressView().tint(Brand.secondaryText)
                            Text("Loading reviews…")
                                .font(.subheadline)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(18)
                    }
                }
            } else if reviews.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Reviews").padding(.top, 22)
                    cardContainer {
                        VStack(alignment: .leading, spacing: 0) {
                            // Header — average rating block.
                            HStack {
                                Text("Reviews")
                                    .font(.system(size: 11.5, weight: .heavy))
                                    .kerning(1.4)
                                    .foregroundStyle(Brand.tertiaryText)
                                Spacer()
                                if let avg = avgRating {
                                    HStack(spacing: 4) {
                                        starRow(value: avg, size: 12)
                                        Text(String(format: "%.1f", avg))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Brand.ink)
                                        Text("(\(reviews.count))")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(Brand.tertiaryText)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                            ForEach(reviewsExpanded ? reviews : Array(reviews.prefix(1))) { review in
                                reviewRow(review)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 14)
                                if review.id != (reviewsExpanded ? reviews.last?.id : reviews.first?.id) {
                                    Divider().overlay(Brand.softOutline)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 14)
                                }
                            }

                            if reviews.count > 1 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { reviewsExpanded.toggle() }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(reviewsExpanded ? "Show less" : "Show all \(reviews.count) reviews")
                                            .font(.system(size: 13.5, weight: .bold))
                                            .foregroundStyle(Brand.ink)
                                        Image(systemName: reviewsExpanded ? "chevron.up" : "chevron.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Brand.ink)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        Rectangle()
                                            .fill(Brand.softOutline)
                                            .frame(height: 1),
                                        alignment: .top
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reviewRow(_ review: GameReview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(AvatarGradients.resolveGradient(forKey: review.avatarColorKey))
                    .frame(width: 32, height: 32)
                Text(review.initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let name = review.reviewerName, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Brand.ink)
                    }
                    Spacer(minLength: 0)
                    if let date = review.createdAt {
                        Text(relativeReviewDate(date))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Brand.tertiaryText)
                    }
                }
                HStack(spacing: 6) {
                    starRow(value: Double(review.rating), size: 11)
                    if let title = review.gameTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Brand.tertiaryText)
                            .lineLimit(1)
                    }
                }
                if let comment = review.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Brand.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func starRow(value: Double, size: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: starImageName(star: star, avg: value))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color(hex: "F5B70A"))
            }
        }
    }

    private func starImageName(star: Int, avg: Double) -> String {
        if Double(star) <= avg { return "star.fill" }
        if Double(star) - avg < 1.0 { return "star.leadinghalf.filled" }
        return "star"
    }

    private func relativeReviewDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Location Card (Venue + Contact + Map)

    private var locationCardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Location").padding(.top, 22)

            // Resolve display fields. Hide rows whose data is missing.
            let venueName: String? = {
                if let v = primaryVenueForContact { return v.venueName }
                return club.venueName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }()
            let venueAddress: String? = {
                if let v = primaryVenueForContact, let a = LocationService.formattedAddress(for: v) { return a }
                let trimmed = club.formattedAddressFull.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()

            cardContainer {
                VStack(alignment: .leading, spacing: 0) {
                    if let coord = clubMapCoordinate {
                        Button {
                            if let url = clubMapURL { openURL(url) }
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Map(position: .constant(MapCameraPosition.region(
                                    MKCoordinateRegion(center: coord, latitudinalMeters: 600, longitudinalMeters: 600)
                                ))) {
                                    Marker("", coordinate: coord)
                                }
                                .frame(height: 150)
                                .allowsHitTesting(false)

                                openInMapsChip
                                    .padding(10)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if let name = venueName {
                            locationFieldHeader("Venue")
                            Text(name)
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(Brand.ink)
                                .lineLimit(2)
                        }

                        if let addr = venueAddress {
                            Text(addr)
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.secondaryText)
                                .padding(.top, 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Contact divider — only when we have any contact info to show.
                        let hasContact = (safeManagerName?.isEmpty == false)
                            || (safeContactPhone?.isEmpty == false)
                            || !safeContactEmail.isEmpty

                        if hasContact, venueName != nil || venueAddress != nil {
                            Divider().overlay(Brand.softOutline)
                                .padding(.vertical, 12)
                        }

                        if hasContact {
                            locationFieldHeader("Contact")
                        }

                        if let manager = safeManagerName, !manager.isEmpty {
                            Text(manager)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .padding(.top, 1)
                        }

                        if let phone = safeContactPhone, !phone.isEmpty {
                            contactRow(value: phone, action: {
                                let digits = phone.filter { $0.isNumber || $0 == "+" }
                                if let url = URL(string: "tel:\(digits)") { openURL(url) }
                            })
                            .padding(.top, 4)
                        }

                        if !safeContactEmail.isEmpty {
                            contactRow(value: safeContactEmail, action: {
                                if let url = URL(string: "mailto:\(safeContactEmail)") { openURL(url) }
                            })
                            .padding(.top, 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
        .task {
            // Load primary venue rows so the address/coordinates resolve.
            if appState.clubVenuesByClubID[club.id] == nil {
                await appState.refreshVenues(for: club)
            }
        }
    }

    private func locationFieldHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .heavy))
            .kerning(1.2)
            .foregroundStyle(Brand.tertiaryText)
            .padding(.bottom, 4)
    }

    private func contactRow(value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var openInMapsChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "map")
                .font(.system(size: 11, weight: .semibold))
            Text("Open in Maps")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Brand.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.95), in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }

    // MARK: - Floating CTA Bar

    private var floatingCTABar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Brand.appBackground.opacity(0),
                    Brand.appBackground.opacity(0.92),
                    Brand.appBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button {
                    navigateToChat = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .frame(width: 48, height: 48)
                        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Brand.softOutline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open club chat")

                primaryCTAButton
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
            .padding(.top, 6)
            .background(Brand.appBackground)
        }
    }

    @ViewBuilder
    private var primaryCTAButton: some View {
        let state = appState.membershipState(for: club)
        let isBusy = appState.isRequestingMembership(for: club) || appState.isRemovingMembership(for: club)

        if isMemberOrAdmin {
            Button {
                showBookGame = true
            } label: {
                ctaPill(label: "Book a game",
                        systemIcon: "bolt.fill",
                        background: Brand.sportPop,
                        foreground: Brand.ink,
                        iconTint: Brand.ink)
            }
            .buttonStyle(.plain)
            .modifier(ShakeEffect(animatableData: shakeBookGame ? 1 : 0))
        } else if case .pending = state {
            Button {
                showCancelRequestConfirm = true
            } label: {
                ctaPill(label: isBusy ? "Updating…" : "Request Pending",
                        systemIcon: "clock.fill",
                        background: Brand.secondarySurface,
                        foreground: Brand.secondaryText,
                        iconTint: Brand.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        } else {
            Button {
                let hasConduct = liveClub.codeOfConduct?.isEmpty == false
                let hasPolicy  = liveClub.cancellationPolicy?.isEmpty == false
                if hasConduct {
                    showConductSheet = true
                } else if hasPolicy {
                    showCancellationPolicySheet = true
                } else {
                    Task { await appState.requestMembership(for: club) }
                }
            } label: {
                ctaPill(label: isBusy ? "Joining…" : "Join Club",
                        systemIcon: "person.badge.plus",
                        background: Brand.primaryText,
                        foreground: .white,
                        iconTint: Brand.sportPop)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private func ctaPill(label: String, systemIcon: String, background: Color, foreground: Color, iconTint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemIcon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(iconTint)
            Text(label)
                .font(.system(size: 16, weight: .heavy))
                .kerning(-0.1)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: background.opacity(0.45), radius: 10, x: 0, y: 6)
    }

    // MARK: - Membership Feedback

    private var membershipFeedbackMessage: (text: String, isError: Bool)? {
        if let error = appState.membershipErrorMessage, !error.isEmpty {
            return (error, true)
        }
        if let info = appState.membershipInfoMessage, !info.isEmpty {
            return (info, false)
        }
        return nil
    }

    // MARK: - Game Helpers

    private func nextWeekDraft(from game: Game) -> ClubOwnerGameDraft {
        var draft = ClubOwnerGameDraft(game: game)
        draft.startDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: game.dateTime) ?? game.dateTime
        draft.repeatWeekly = false
        draft.repeatCount = 1
        return draft
    }

    private func goesLiveCountdown(_ publishAt: Date) -> String {
        let diff = max(publishAt.timeIntervalSince(now), 0)
        let totalMinutes = Int(diff / 60)
        let days  = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let mins  = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - Text Helpers

    private func cappedDisplayText(_ raw: String, maxLength: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    private func trimmedOptional(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Optional helpers

private extension String {
    var nilIfEmpty: String? { self.isEmpty ? nil : self }
}

// MARK: - Upcoming Game Carousel Card
//
// Compact 212pt-wide card for the horizontal Upcoming Games carousel on the
// club detail screen. Distinct from `UnifiedGameCard` (which is the full-width
// row used in Bookings / Game Detail / Home). This card is screen-specific
// and intentionally narrower so multiple games show at once with snap-paging.

private struct UpcomingGameCarouselCard: View {
    let game: Game
    let resolvedVenue: ClubVenue?
    let isBooked: Bool
    let isScheduled: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var dateLabel: String { Self.dateFormatter.string(from: game.dateTime).uppercased() }
    private var timeLabel: String { Self.timeFormatter.string(from: game.dateTime).uppercased() }
    private var confirmed: Int { game.confirmedCount ?? 0 }
    private var pct: Double {
        guard game.maxSpots > 0 else { return 0 }
        return min(1, Double(confirmed) / Double(game.maxSpots))
    }
    private var isFull: Bool { confirmed >= game.maxSpots && game.maxSpots > 0 }
    private var venueLabel: String? {
        if let v = resolvedVenue { return v.venueName }
        let trimmed = game.venueName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }
    private var costLabel: String { game.priceLabel }
    private var capacityColor: Color {
        if isFull { return Color(hex: "FF6B6B") }
        if pct >= 0.75 { return Color(hex: "FFC23A") }
        return Brand.sportPop
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroBlock
            bodyBlock
        }
        .frame(width: 212)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .opacity(isScheduled ? 0.55 : 1)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    private var heroBlock: some View {
        ZStack(alignment: .topTrailing) {
            // Same surface composition as the game detail hero — picks
            // up the admin's pinned palette + pattern (recurring games
            // inherit from the template) and falls back to the
            // deterministic auto rotation seeded from `game.id` on any
            // axis the admin hasn't pinned. Previously this card painted
            // a hue-hashed gradient + hardcoded diagonal stripes which
            // ignored both selections.
            HeroSurface.forGame(
                game,
                lighting: .topRight,
                vignette: .bottom,
                direction: .diagonal
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(dateLabel)
                        .font(.system(size: 10.5, weight: .heavy))
                        .kerning(1)
                    Text("·")
                        .font(.system(size: 10.5, weight: .heavy))
                        .opacity(0.4)
                    Text(timeLabel)
                        .font(.system(size: 10.5, weight: .heavy))
                        .kerning(1)
                }
                .foregroundStyle(Color.white.opacity(0.85))

                Spacer(minLength: 0)

                Text(game.title)
                    .font(.system(size: 16, weight: .heavy))
                    .kerning(-0.3)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isBooked {
                ZStack {
                    Circle()
                        .fill(Brand.sportPop)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                }
                .padding(8)
                .accessibilityLabel("You're in")
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let venue = venueLabel {
                HStack(spacing: 5) {
                    Image(systemName: "map")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.tertiaryText)
                    Text(venue)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }
            }

            // Capacity bar — single GeometryReader sized track + fill.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 99, style: .continuous)
                        .fill(Brand.softOutline)
                    RoundedRectangle(cornerRadius: 99, style: .continuous)
                        .fill(capacityColor)
                        .frame(width: max(0, geo.size.width * pct))
                }
            }
            .frame(height: 4)

            HStack {
                Text(isFull ? "Full" : "\(confirmed)/\(game.maxSpots) players")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isFull ? Color(hex: "E04848") : Brand.secondaryText)
                Spacer(minLength: 0)
                Text(costLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

}

// MARK: - Share Sheet

/// Wraps UIActivityViewController so sheets present correctly on iPad
/// (avoids the detached floating popover that ShareLink renders on iPad).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let angle = sin(animatableData * .pi * 4) * 8
        return ProjectionTransform(CGAffineTransform(translationX: angle, y: 0))
    }
}


#Preview {
    NavigationStack {
        ClubDetailView(club: MockData.clubs[0])
            .environmentObject({
                let state = AppState()
                state.signInPreview()
                let previewID = state.authUserID ?? UUID()
                state.profile = UserProfile(
                    id: previewID,
                    fullName: "Brayden Kelly",
                    email: "preview@bookadink.app",
                    favoriteClubName: nil,
                    skillLevel: .intermediate
                )
                return state
            }())
    }
}

// MARK: - Scroll offset reader (UIKit introspect)
//
// Reads the enclosing `UIScrollView`'s `contentOffset` directly via KVO,
// so callers see pull-to-refresh / overscroll translation that the
// SwiftUI-only `GeometryReader` + named coordinate space doesn't expose.
// The reported value is the **logical** offset relative to the natural
// rest position — i.e. `contentOffset.y + adjustedContentInset.top` —
// so `0` is rest regardless of any inset the refresh control applies,
// `+N` is upward scroll, and `−N` is a pull past rest.
//
// To use, place an instance inside the ScrollView's content with a
// 0-height frame:
//
//     ScrollView {
//         ScrollOffsetReader { offset in /* read */ }
//             .frame(height: 0)
//         <real content>
//     }
//
// iOS 18 callers can drop this in favour of `.onScrollGeometryChange` —
// the value is identical.

// File-scope so other views (e.g. GameDetailView) can reuse the same
// pull-tracking probe — the implementation is generic and reading
// scroll offset via UIKit introspection isn't ClubDetailView-specific.
struct ScrollOffsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ScrollOffsetProbeView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Refresh the captured closure on every body recompute so any
        // captured state setters point at the latest @State storage.
        (uiView as? ScrollOffsetProbeView)?.onChange = onChange
    }
}

/// Headless `UIView` whose only job is to find its enclosing
/// `UIScrollView` once it's in the hierarchy and KVO-observe
/// `contentOffset` on it. The KVO callback fires on the main thread
/// (since `UIScrollView` is a `UIView`), so it's safe to drive SwiftUI
/// `@State` from `onChange`.
private final class ScrollOffsetProbeView: UIView {
    var onChange: ((CGFloat) -> Void)?
    private var observation: NSKeyValueObservation?
    private weak var observedScrollView: UIScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // Detached from window — drop the observer to avoid leaks
            // and stale callbacks.
            observation?.invalidate()
            observation = nil
            observedScrollView = nil
        } else {
            attachObserverIfNeeded()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        // The enclosing UIScrollView may not be present at
        // `didMoveToWindow` time on every layout pass; re-checking on
        // superview changes covers SwiftUI's compositional shuffle.
        attachObserverIfNeeded()
    }

    private func attachObserverIfNeeded() {
        guard window != nil, observation == nil,
              let scrollView = enclosingScrollView() else { return }
        observedScrollView = scrollView
        observation = scrollView.observe(
            \.contentOffset,
            options: [.new, .initial]
        ) { [weak self] scroll, _ in
            let logical = scroll.contentOffset.y + scroll.adjustedContentInset.top
            self?.onChange?(logical)
        }
    }

    private func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = self.superview
        while let v = view {
            if let s = v as? UIScrollView { return s }
            view = v.superview
        }
        return nil
    }

    deinit {
        observation?.invalidate()
    }
}

