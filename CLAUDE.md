# CLAUDE.md — Book A Dink

Constraints and guidance for Claude Code sessions on this repo.

## Hard Constraints — ClubDetailView

These caused a production freeze. **Never reintroduce:**

- NO `confirmationDialog("Club Actions", ...)` in `ClubDetailView`
- NO `containerRelativeFrame` / forced clipping in club navigation containers
- NO automatic network tasks on `ClubDetailView` open — load on tab change only
- NO unbounded Supabase text fields passed directly into UI models (length caps required)
- NO `bookadink-preset` URL scheme handling

## Supabase

- `profiles` RLS UPDATE policy **must** include `WITH CHECK (auth.uid() = id)` — without it PostgREST upserts silently fail (no error returned)
- All club text fields must be sanitised at decode time: length caps + URL scheme validation
- `skill_level` enum values: `all`, `beginner`, `intermediate`, `advanced` — no `tournament`
- **Club SELECT strings** — PostgREST only returns columns you enumerate. `latitude` and `longitude` **must** appear in all 5 club `select=` query strings in `SupabaseService.swift` (`fetchClubs`, `fetchClubDetail`, `createClub`, `updateClubOwnerFields`, delete helper). Removing them silently decodes as `nil` and breaks `NearbyDiscoveryView`. Any new column added to `Club` / `ClubRow` needs the same treatment.

## Xcode Target Membership

Any new `.swift` file created on disk **must** be manually added in Xcode → File Inspector → Target Membership before it will compile. This has caused cascade "Cannot find type X in scope" errors on: `GameScheduleStore.swift`, `ClubOwnerSheets.swift`, `ClubGameRow.swift`, and others.

## Stability Rules

- Run `./scripts/smoke_check.sh` before committing any change to `ClubDetailView` or `AppState`
- Manual smoke test after club changes:
  1. Tap into/out of `Sunset Pickleball Club` 3 times
  2. Force close, relaunch, open multiple clubs
  3. Switch Info / Games / Members / Club Chat tabs
  4. Open Club Settings, save, verify success feedback

## Do Not Reintroduce (UI)

- "Win Rate" stat pill in `GamesPlayedCard` — no data to back it
- `fullScreenCover(isPresented: .constant(appState.isAuthenticating))` in `AuthWelcomeView` — fires on token refresh and overlays `MainTabView`
- `.blendMode(.screen)` on the app logo is only needed for PNG assets with dark/white backgrounds — the current SVG has a transparent background and does not need it

## Architecture Notes

- Auth bootstrap guard in `RootView`: `authState != .signedOut && !isInitialBootstrapComplete && profile == nil`
- `isMemberOrAdmin` in `ClubDetailView` must handle `.approved`, `.unknown` (club owner case), and `isClubAdminUser`
- `String.normalizedAddress()` is the canonical way to display club addresses — trim, collapse whitespace, title-case, truncate at 40 chars
- DUPR ratings stored in `UserDefaults` keyed by `StorageKeys.duprRatingsByUserID` as `[userIDString: {d: Double, s: Double}]` — see DUPR section below for sync details

## Stripe Payments

- Stripe iOS SDK (`StripePaymentSheet`) is installed and wired into `GameDetailView`
- `StripeAPI.defaultPublishableKey` set in `BookADinkApp.init()` from `SupabaseConfig.stripePublishableKey`
- `create-payment-intent` Edge Function at `supabase/functions/create-payment-intent/index.ts` — accepts `{ amount, currency, metadata }`, returns `{ client_secret }`
- Apple Pay configured with `merchantId: "merchant.com.bookadink"`, `merchantCountryCode: "AU"` — requires Apple Pay capability + merchant ID in Xcode and domain verification in Stripe Dashboard
- Currently in **test mode** (`pk_test_`, `sk_test_`). Switch to `pk_live_`/`sk_live_` for production
- Edge Functions called from iOS use the **anon key** (not user JWT) for `apikey` and `Authorization` headers — user JWT is only valid for PostgREST/DB calls

## Push Notifications & Email

- APNs push notifications are **live** — secrets (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`, `APNS_USE_SANDBOX`) set in Supabase
- Email notifications via Resend — `send-notification-email` Edge Function triggered by DB trigger `send_notification_email` on `notifications` table (uses `net.http_post`)
- DB trigger uses anon key for Authorization when calling the Edge Function
- **If Edge Functions return "Unregistered API key" on the internal Supabase client**: redeploy the function (`supabase functions deploy <name> --no-verify-jwt --project-ref <ref>`) to refresh the auto-injected `SUPABASE_SERVICE_ROLE_KEY`
- `notify` Edge Function at `supabase/functions/notify/index.ts` — inserts into `notifications` table (fires email trigger) and optionally sends APNs push. Called directly from iOS via `triggerNotify()`

## Club Chat Performance

- `commentDraft` state **must** live inside `ClubNewsPostCard` as `@State private var commentDraft: String = ""` — lifting it to the parent view (as `[UUID: String]`) causes full re-render of all cards on every keystroke, making the keyboard feel laggy
- Club news comments and reactions fetched concurrently via `async let` in `fetchClubNewsPosts`
- Like/comment updates use optimistic UI — mutate local cache immediately, revert on failure — do NOT call `refreshClubNews` after every interaction

## DUPR

- DUPR ratings have two storage paths: Supabase `profiles.dupr_rating` and UserDefaults (`StorageKeys.duprRatingsByUserID` as `[userIDString: {d: Double, s: Double}]`)
- `loadProfileFromBackendIfAvailable` syncs Supabase → UserDefaults after every profile fetch to keep them in sync (fixes admin DUPR updates not reflecting on member profile)
- `DUPRHistoryCard` chart: black line, black dots with white border, Y-axis DUPR values, X-axis DD/MM dates as `.annotation(position: .bottom)` on each PointMark (not `chartXAxis` renderer — avoids last label clipping)

## New Services & Views (unstaged)

- `LocationManager.swift` / `LocationService.swift` — location services
- `ClubBookGameView.swift` — book-a-game flow from club context
- `NearbyGamesView.swift` — nearby games discovery
- `SplashView.swift` — splash/loading screen
- `Views/Home/` — home tab views
- `supabase/functions/archive-old-games/` — Edge Function to archive old games

## Payment Tracking (implemented 2026-03-27)

- `bookings.payment_method TEXT NULL` column added — values: `"stripe"` (paid via card/Apple Pay), `"admin"` (owner-added, no charge), `nil` (self-booked free game or unpaid)
- `bookings.fee_paid BOOL` and `bookings.stripe_payment_intent_id TEXT` already existed — now populated on Stripe completion
- Payment intent ID extracted from client secret in `GameDetailView.preparePaymentSheet` via `clientSecret.components(separatedBy: "_secret_").first`
- On Stripe `.completed`, `requestBooking(for:stripePaymentIntentID:)` is called — writes `fee_paid=true`, `payment_method="stripe"`, `stripe_payment_intent_id` to DB in the same insert
- `ownerCreateBooking` always inserts `payment_method="admin"` via `BookingAdminInsertBody` — admin-added players are visually shown as "Comp" badge (grey), not "Unpaid"
- Payment badge in attendee list is **admin/owner only** — inside the `isClubAdminUser` block
- Upcoming games: read-only badge from `booking.paymentMethod` via `bookingPaymentBadge()` — "Card" (blue), "Comp" (grey), "Unpaid" (orange)
- Past games: existing tappable menu to manually set cash/stripe/unpaid on check-in remains unchanged
- All booking SELECT strings must include `payment_method` — omitting it silently returns nil and shows everyone as "Unpaid"
- **Required DB migration**: `ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_method TEXT NULL;`

## Notifications (implemented 2026-03-27)

- `NotificationsView` uses its own `NavigationStack` — club notifications push inline via `navigationDestination(item: $selectedClub)` so Back returns to Notifications (not Home tab)
- Game notifications open as `.sheet(item: $selectedGame)` — dismiss returns to Notifications
- Removed `appState.pendingDeepLink` routing from notification taps (was switching to Clubs tab)
- "Clear All" button in action row calls `appState.clearAllNotifications()` → `SupabaseService.deleteAllNotifications(userID:)` — hard DELETE on `notifications` table filtered by `user_id`
- Chevron indicator on `NotificationRow` only shown when `hasDestination: true` — review notifications are ALWAYS tappable (no game-in-memory requirement; see Reviews section)
- **Required RLS policy**: users must be able to DELETE their own notification rows: `CREATE POLICY "Users can delete own notifications" ON notifications FOR DELETE USING (auth.uid() = user_id);`

## Delayed Game Publishing (implemented 2026-03-27)

- `games.publish_at TIMESTAMPTZ NULL` column — NULL = publish immediately, future timestamp = scheduled/hidden
- **Required DB migration**: `ALTER TABLE games ADD COLUMN IF NOT EXISTS publish_at TIMESTAMPTZ NULL;`
- `Game.isScheduled: Bool` computed from `publishAt > Date()`
- All 8 game SELECT strings in `SupabaseService` must include `publish_at`
- `fetchUpcomingGames()` filters with PostgREST OR: `(publish_at.is.null,publish_at.lte.<now>)` — scheduled games excluded from public feed
- `AppState.mergeIntoAllUpcomingGames()` also filters client-side: `$0.publishAt == nil || $0.publishAt! <= now`
- Club games tab: `filteredClubGames` shows scheduled games to admins only, dimmed at 55% opacity with orange "Not visible to the public · Goes live in Xd Yh Zm" banner; uses `Timer.publish(every: 60)` to keep countdown live
- Recurring games: publish offset is computed as `startDate.timeIntervalSince(publishAt)` on the template, then applied to each occurrence: `instanceDraft.publishAt = instanceDraft.startDate.addingTimeInterval(-offset)`
- Validation guard in `createGameForClub` and `updateGameForClub`: publish time must be in the future — returns early with error message if `publishAt <= Date()`
- Toggle default initialises publish time to `startDate - 48h`; DatePicker enforces `in: Date()...` to block past selection

## Club Chat Images (fixed 2026-03-27)

- `ClubNewsImageGrid` uses `scaledToFit()` (not `scaledToFill`) — full image shown without cropping
- Frame: `maxWidth: .infinity, maxHeight: 500` (single image) / `maxHeight: 200` (multi-image grid)
- Previous `scaledToFill` with height-only constraint caused the image button's layout frame to expand unconstrained, overlapping the post "..." menu button's tap area above it

## Club Tools Menu Order (standardised 2026-03-27)

Order in both the toolbar `Menu` and `ownerToolsPanel` card:
1. View / Edit Games
2. Create Game
3. `Divider()`
4. Club Settings
5. `Divider()`
6. Join Requests
7. Manage Members

## Reviews (implemented 2026-03-28)

- **Flow**: 24h after a game ends, `send-review-prompts` Edge Function (runs hourly via pg_cron) inserts a `game_review_request` notification for each confirmed attendee → notification appears in app → tap opens `ReviewGameSheet` → user submits star rating + optional comment → success state shows "View [Club Name]" button
- **Review is about the club** (using the game as context), not the game itself — the game title appears as the sheet header, but the review is associated with the club
- **Notification tap**: uses `PendingReview(id: gameID, gameTitle: String)` — always tappable, does NOT require the game to be in memory. Game title is extracted from `notification.title` ("How was {title}?" → strips prefix/suffix). Club is resolved inside `ReviewGameSheet` via `appState.clubForGame(gameID:)` (checks `gamesByClubID` → `bookings` cache → DB fetch as last resort)
- **`DeepLink.review(gameID: UUID)`** — added case; handled in `MainTabView.handleDeepLink` as no-op (review prompts only come via notifications, not deep links)
- **Duplicate prevention**: `reviews` table has `UNIQUE (game_id, user_id)`. Submitting a second review returns HTTP 409 → caught specifically in `ReviewGameSheet.submit()` → shows "You have already left a review for this session." Generic errors still show "Couldn't submit your review. Please try again."
- **`ReviewGameSheet`** accepts `gameID: UUID` + `gameTitle: String` (not a `Game` object). Club resolved on `.task`. "View Club" button uses callback `onViewClub: ((Club) -> Void)?` — dismisses sheet first, then caller opens club via its own navigation
- **Viewing reviews on club page**: `ClubDetailView.reviewsSection` fetches from Supabase via `appState.fetchReviews(for: clubID)` on appear + pull-to-refresh. Shows aggregate star average with count, reviewer initials, game title context, and comment. Section hidden until at least one real review exists. Expand/collapse for more than 2 reviews
- **`GameReview` model**: `id, gameID, userID, rating, comment, createdAt, reviewerName, gameTitle`. Initials computed from `reviewerName`
- **`AppState.reviewsByClubID: [UUID: [GameReview]]`** + `loadingReviewsClubIDs: Set<UUID>`
- **Date decoding**: `ReviewRow.createdAtRaw: String?` decoded via `SupabaseDateParser.parse` — same pattern as all other rows. Using `Date?` directly causes silent decode failure (JSONDecoder can't parse ISO8601 strings by default)
- **`SupabaseService.fetchClubReviews(clubID:)`**: POSTs to `rpc/get_club_reviews` (PostgreSQL `SECURITY DEFINER` function) — bypasses RLS on `profiles` so reviewer names resolve for all users (without SECURITY DEFINER, profiles RLS makes reviewer names null for other users' reviews)
- **`SupabaseService.fetchGameClubID(gameID:)`**: lightweight query (`games?select=club_id&id=eq.{id}`) used as fallback in `AppState.clubForGame(gameID:)` when the game isn't in any memory cache
- **Required DB setup** (run once in Supabase SQL Editor):
  ```sql
  CREATE TABLE IF NOT EXISTS reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (game_id, user_id)
  );
  ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
  -- INSERT: users submit their own reviews
  CREATE POLICY "Users can insert own reviews" ON reviews FOR INSERT WITH CHECK (auth.uid() = user_id);
  -- SELECT: all authenticated users (members, admins, owners)
  CREATE POLICY "Authenticated users can read reviews" ON reviews FOR SELECT USING (auth.role() = 'authenticated');
  -- Function for iOS fetch (SECURITY DEFINER bypasses profiles RLS)
  CREATE OR REPLACE FUNCTION get_club_reviews(p_club_id UUID)
  RETURNS TABLE(id UUID, game_id UUID, user_id UUID, rating INT, comment TEXT, created_at TIMESTAMPTZ, reviewer_name TEXT, game_title TEXT)
  LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT r.id, r.game_id, r.user_id, r.rating, r.comment, r.created_at,
           p.full_name AS reviewer_name, g.title AS game_title
    FROM reviews r JOIN games g ON g.id = r.game_id AND g.club_id = p_club_id
    LEFT JOIN profiles p ON p.id = r.user_id ORDER BY r.created_at DESC LIMIT 50;
  $$;
  GRANT EXECUTE ON FUNCTION get_club_reviews(UUID) TO authenticated;
  ```
- **`send-review-prompts` Edge Function**: deployed at `supabase/functions/send-review-prompts/`. Schedule hourly via pg_cron: `SELECT cron.schedule('send-review-prompts', '0 * * * *', $$ SELECT net.http_post(url := 'https://<ref>.supabase.co/functions/v1/send-review-prompts', headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb) $$);`
- **`games_ending_between(window_start, window_end)`** PostgreSQL RPC required by the Edge Function — finds games where `date_time + duration_minutes` falls in the window (PostgREST can't do column arithmetic in filters)
- **`notification_type` enum**: must include `'game_review_request'` — add with `ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'game_review_request';`

---

## Roadmap / To-Do

- **Android version** — plan native Android app (Kotlin/Jetpack Compose) or cross-platform (Flutter/React Native) once iOS is stable
- **Reviews admin dashboard** — club owner/admin view of all reviews; ability to respond to reviews; flag/hide inappropriate reviews; consider App Store review prompt tied to 4–5 star submissions
- **Club name tappable on game booking card** — tapping the club name in a game card (discovery/bookings list) should navigate to that club's detail page *(partially implemented — `UnifiedGameCard.onClubTap` closure exists)*
- **Pickleball news feed on Home tab** — RSS or curated API feed of pickleball news/content for engagement; posts shareable directly to any club chat the user is a member of
- **Subscription & payment tiers** — define free vs paid club tiers (e.g. max games, max members, analytics access); Stripe subscription products; in-app paywall for premium features; grace period + downgrade handling; admin billing portal
- **User notification preferences** — per-type opt-in/out for email and push (booking confirmations, club news, waitlist promotions, review prompts, etc.); `notification_preferences` table per user
- **APNs per-club mute suppression** — suppress push for clubs the user has muted at server side, not just client side
- **Stripe test → live mode** — swap `pk_test_`/`sk_test_` for `pk_live_`/`sk_live_`; verify Apple Pay domain with Stripe Dashboard
