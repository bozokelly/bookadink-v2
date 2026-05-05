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

- **PL/pgSQL `RETURNS TABLE` — qualify every column reference inside the function body.** When a function uses `RETURNS TABLE(... user_id UUID, game_id UUID, status TEXT, waitlist_position INT ...)`, those names become OUT variables in the function's PL/pgSQL scope. Any unqualified column reference with the same name throws `42702 column reference "X" is ambiguous` at the moment execution reaches that path — and only at that moment, so the bug ships silently if the path isn't exercised in test (e.g. a members-only gate that never fired in dev).
  - **Rule:** every `SELECT` / `WHERE` / `UPDATE` / `DELETE` clause inside a function whose `RETURNS TABLE(...)` includes a column named `X` must qualify references to `X` with a table alias: `b.user_id`, `cm.user_id`, `g.game_id` etc. The INSERT column list (`INSERT INTO bookings (id, game_id, ...)`) is unambiguous and does not need qualification.
  - **History:** `book_game` shipped with unqualified `user_id` in the members-only gate (members-only path was rare, so the 42702 went unnoticed for weeks). Reference fix: migration `20260501020000_book_game_qualify_user_id.sql`. The same shadowing exists for any column name in `RETURNS TABLE` — `game_id`, `status`, `waitlist_position`, `payment_method` etc.
  - **Pattern to follow:** alias every table on declaration (`FROM bookings b`, `FROM club_members cm`, `FROM games g`, `FROM clubs c`, `FROM club_admins ca`, `FROM profiles p`). Use the alias on every column reference. Do this even for "obvious" tables — consistency stops the next person from leaving a single unqualified reference.
- `profiles` RLS UPDATE policy **must** include `WITH CHECK (auth.uid() = id)` — without it PostgREST upserts silently fail (no error returned)
- All club text fields must be sanitised at decode time: length caps + URL scheme validation
- `skill_level` enum values: `all`, `beginner`, `intermediate`, `advanced` — no `tournament`
- **Never introduce client-only `SkillLevel` enum cases.** The Swift `SkillLevel` enum rawValues must exactly match DB values (`all`, `beginner`, `intermediate`, `advanced`). `tournament` was removed — do not reintroduce it or any other non-DB case. `SkillLevel.label` is the display string; `SkillLevel.rawValue` is the DB/wire value. Migration `20260428040000_normalize_skill_level_tournament.sql` normalizes any legacy rows.
- **`ClubAdminRole` enum** — canonical admin role type. DB `club_admins.role` values are `owner` and `admin` only. Swift `ClubAdminRole` rawValues match exactly. **Never use raw string comparisons for role checks** (`role == "owner"` / `role == "admin"` are banned). Use `role == .owner` / `role == .admin`. `ClubAdminRole.label` is the display string. `clubAdminRoleByClubID: [UUID: ClubAdminRole]` in `AppState` is the in-memory cache — server-side RLS remains authoritative.
- **Club SELECT strings** — PostgREST only returns columns you enumerate. `latitude` and `longitude` **must** appear in all 5 club `select=` query strings in `SupabaseService.swift` (`fetchClubs`, `fetchClubDetail`, `createClub`, `updateClubOwnerFields`, delete helper). Removing them silently decodes as `nil` and breaks `NearbyDiscoveryView`. Any new column added to `Club` / `ClubRow` needs the same treatment.
- **Subscription plan pricing is server-authoritative** — Stripe price IDs and display prices live in the `subscription_plans` table, fetched via `get_subscription_plans()` RPC at bootstrap. **Never hardcode a Stripe price ID or display price string** (`A$19/mo`, `A$49/mo`, `price_...`) in Swift source, Android source, or any client config file. Use `AppState.subscriptionPriceID(for:)` and `AppState.subscriptionDisplayPrice(for:)` helpers. Updating prices requires only a DB row update — no app release. Migration: `20260428050000_subscription_plans.sql`.
- **Feature entitlements are server-authoritative** — `derive_club_entitlements()` (PostgreSQL) is the ONLY place where plan_type → feature mapping happens. iOS reads `ClubEntitlements` fields via `FeatureGateService`; Android/web read the `locked_features TEXT[]` array from `get_club_entitlements(UUID)` RPC. **Never reimplement tier→feature logic on any client.** Never branch on `planTier` string to decide feature access — use the individual boolean fields (`canAcceptPayments`, `analyticsAccess`, `canUseRecurringGames`, `canUseDelayedPublishing`) or the `lockedFeatures` array. Migration: `20260429040000_entitlement_locked_features_rpc.sql`.
  - `locked_features` key contract (stable API): `"payments"`, `"analytics"`, `"recurring_games"`, `"delayed_publishing"`.
  - Paywall display strings (plan bullets, success highlights) must derive from `planTierLimits` (server-fetched via `get_plan_tier_limits()`) — no hardcoded limit numbers or plan feature lists in Swift.
  - `FeatureGateService` is deny-by-default: every method returns `.blocked` when `entitlements` is `nil`. Never add a fallback that grants access on missing/failed entitlement data.
  - `upgradablePlans` in `ClubUpgradePaywallView` may switch on `entitlements.planTier` to compute which plans are upgrades — this is the only permitted local use of `planTier`.
- **`game_format` canonical values** — `game_format` is a `TEXT` column with a CHECK constraint (migration `20260429060000_normalize_game_format.sql`). Allowed values: `open_play`, `random`, `round_robin`, `king_of_court`, `dupr_king_of_court`. The legacy value `ladder` was an alias for `king_of_court` and has been normalized out — **never reintroduce `ladder` as a raw value or client-side alias**. Display labels live in the UI layer only (`compactFormatLabel`, `prettify`, `formatDescription`); `gameFormatRaw` is always the DB/wire value. Android and web must use the same canonical set.
- **Field length limits are DB-authoritative** — Migration `20260429050000_field_length_constraints.sql` adds CHECK constraints to all tables. Clients may trim/validate for UX, but must never define different limits. The DB is the single source of truth. Never add client-only length caps that diverge from the table below.

  | Table | Column | Max (chars) | Notes |
  |-------|--------|------------|-------|
  | `clubs` | `name` | 120 | required |
  | `clubs` | `description` | 2000 | |
  | `clubs` | `contact_email` | 320 | |
  | `clubs` | `contact_phone` | 30 | |
  | `clubs` | `website` | 260 | |
  | `clubs` | `manager_name` | 160 | |
  | `clubs` | `suburb` | 80 | |
  | `clubs` | `state` | 80 | |
  | `clubs` | `venue_name` | 260 | |
  | `club_venues` | `venue_name` | 260 | |
  | `club_venues` | `suburb` | 80 | |
  | `club_venues` | `state` | 80 | |
  | `games` | `title` | 200 | required non-empty |
  | `games` | `max_spots` | — | 2–64 (range check) |
  | `games` | `court_count` | — | 1–50 (range check) |
  | `profiles` | `full_name` | 200 | |
  | `profiles` | `phone` | 30 | |
  | `profiles` | `emergency_contact_name` | 160 | |
  | `profiles` | `emergency_contact_phone` | 30 | |
  | `profiles` | `dupr_id` | 24 | min 6, format `^[A-Z0-9-]+$` + digit required |
  | `profiles` | `dupr_rating` | — | 2.000–8.000, exactly 3 decimal places (NUMERIC(5,3), nullable) |

- **DUPR field validation is server-authoritative** — Migrations `20260429030000_dupr_validation_constraints.sql` and `20260429020000_dupr_rating_3dp_precision.sql`. iOS client validates for UX only; the DB is the final gate. **Never define different validation rules on any client.**
  - `profiles.dupr_id`: nullable; when set — length 6–24, uppercase alphanumeric + hyphen only (`^[A-Z0-9-]+$`), must contain at least one digit. Migration constraints: `profiles_dupr_id_length_check` + `profiles_dupr_id_format_check`.
  - `profiles.dupr_rating`: nullable; column type `NUMERIC(5,3)` — stores exactly 3 decimal places always. Range `[2.000, 8.000]` (DUPR system minimum is 2.000). Constraint: `profiles_dupr_rating_precision_range_check`. Migration: `20260429020000_dupr_rating_3dp_precision.sql`.
    - `4.25` stored as `4.250` — trailing zero normalization, no data loss. Approved.
    - Values with more than 3dp are rounded by `NUMERIC(5,3)` — clients must send exactly 3dp to avoid unintended rounding.
    - iOS clients display rating as `String(format: "%.3f", rating)`. Loaded values pre-fill text fields with `"%.3f"` format so 3dp validation passes on auto-save.
    - **Required for DUPR API integration** — external API expects canonical 3dp format.
  - `book_game()` DUPR gate validates format + digit requirement, not just length ≥ 6.
  - iOS `normalizeDUPRID` strips invalid chars and uppercases before saving — the value reaching the DB should always pass the format constraint. `patchDuprID` errors are surfaced via `profileSaveErrorMessage` rather than silently swallowed.
  - Do NOT silently rewrite invalid `dupr_rating` values — surface the error and let the user correct.
  - Android must handle HTTP 400 / check constraint violation from `profiles` PATCH and map to user-facing messages: "DUPR ID must be uppercase alphanumeric (6–24 chars) and contain a number." / "DUPR rating must be between 2.000 and 8.000 with exactly 3 decimal places."

## Club Image Uploads (implemented 2026-03-31)

- `clubs.custom_banner_url TEXT NULL` column — stores URL of owner-uploaded banner image
- **Required DB migration**: `ALTER TABLE clubs ADD COLUMN IF NOT EXISTS custom_banner_url TEXT NULL;`
- **Required Supabase Storage**: create a public bucket named `club-images` (Dashboard → Storage → New bucket, enable Public)
- `SupabaseConfig.clubImageBucket = "club-images"` — bucket name for avatar + banner uploads
- Avatar uploads: path `club-avatars/{clubID}/{uuid}.jpg` — stored in `clubs.image_url` (same column as presets, custom URL wins)
- Banner uploads: path `club-banners/{clubID}/{uuid}.jpg` — stored in `clubs.custom_banner_url`
- `ClubOwnerEditDraft.uploadedAvatarURL` / `uploadedBannerURL` — set after upload completes; cleared on "Remove"
- `imageURLStringForSave` checks `uploadedAvatarURL` first, then preset, then existing URL
- `customBannerURLStringForSave` checks `uploadedBannerURL` first, then existing `customBannerURL`
- `ClubDetailView` hero renders `AsyncImage` for custom banner when `club.customBannerURL != nil`; falls back to preset key
- `ClubImageBadge.isAllowedRemoteImageURL` allows the configured Supabase host (derived from `SupabaseConfig.urlString`)
- Upload is disabled in create mode (club ID needed for storage path) — user sees "Save the club first" hint
- Dimension hints shown in UI: avatar 400×400 px square, banner 1500×500 px (3:1 ratio)

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

## Waitlist & Hold System (hardened 2026-04-26)

### Architecture contract
The waitlist system is fully server-authoritative. iOS, Android, and web are UI layers only. No client ever decides queue order, hold creation, expiry timing, confirmation eligibility, or promotion order.

### Booking status flow
`waitlisted` → (trigger on confirmed→cancelled) → `pending_payment` (paid game) or `confirmed` (free game) → `confirmed` (after payment) or back to `waitlisted` (if hold expires)

### Hold lifecycle — server-side only
- `bookings.hold_expires_at TIMESTAMPTZ NULL` — set to `now() + waitlist_hold_minutes` when promoted to `pending_payment` or when `book_game(p_hold_for_payment=TRUE)` reserves a paid fresh booking.
- **Hold duration is server-controlled via `app_config`.** The single source of truth is the row `app_config.key = 'waitlist_hold_minutes'` (seeded at `'2'` for testing; production ship value `'30'`). The `get_waitlist_hold_minutes() RETURNS INT STABLE SECURITY DEFINER` helper reads the row, parses + clamps to `[1, 1440]`, and falls back to `2` only if the row is missing or unparseable. All four hold-setting functions read from this helper: `book_game`, `promote_top_waitlisted` (trigger), `promote_waitlist_player`, and `revert_expired_holds_and_repromote` (cron). **To change the hold duration:** `UPDATE app_config SET value = 'N' WHERE key = 'waitlist_hold_minutes';` — the next call to any of the four functions sees the new value. **Never hardcode a hold-minutes constant in any function** or reintroduce parallel constants in iOS / Android. Migrations: `20260504060000_app_config_waitlist_hold_helper.sql` (additive: app_config row + helper), `20260504070000_waitlist_functions_use_hold_helper.sql` (surgical: each function's hardcoded constant replaced by the helper, no other logic changed).
- **Cron job** `revert_expired_holds_and_repromote` runs every minute (pg_cron) — cancels expired holds and (currently) inline-promotes the next eligible waitlister. Migrations: `20260426100000_waitlist_hold_expiry_cron.sql` (initial), `20260501050000_revert_holds_forfeit_policy.sql` (forfeit policy + infinite-loop fix). NOTE: migration `20260502030000_promote_on_pending_payment_cancel.sql` is on disk but has NOT been applied to production; the broadened trigger / simplified cron design it describes is not yet live (see "Pending architectural fixes" below).
- **Missed-hold rule (decided 2026-05-01)**: expired hold → booking is `cancelled` (forfeit). The user does NOT return to the waitlist; the spot is freed. The user receives a one-shot "Your hold expired — tap to rejoin" push via `promote-top-waitlisted-push` with payload `type: "hold_expired_forfeit"`. **Do not** change this back to "move to bottom of waitlist" without rethinking the single-waitlister case — the previous policy infinite-looped (expired user was put at position 1 of 1, then immediately re-promoted with a fresh hold every minute).

### Server-side hold validation (defence-in-depth)
`confirmPendingBooking` PATCH in `SupabaseService.swift` adds a third filter `hold_expires_at=gt.{now}` — if 0 rows match, throws `SupabaseServiceError.holdExpired`. This ensures an expired hold cannot be confirmed even in the <1-minute window before the cron job runs.

### Client-side hold validation (fast-fail, not authoritative)
`AppState.confirmPendingBooking` checks `holdExpiresAt <= Date()` client-side before hitting the server — gives instant feedback without a network round trip. Server enforces the rule regardless.

### Promotion trigger
`promote_top_waitlisted()` DB trigger (`trg_promote_top_waitlisted` on `bookings AFTER UPDATE OF status`) fires on `OLD.status = 'confirmed' AND NEW.status = 'cancelled'`. Picks the top waitlister with `FOR UPDATE SKIP LOCKED` and promotes via `pending_payment` (paid game, with hold) or `confirmed` (free game). Calls `net.http_post` → `promote-top-waitlisted-push` Edge Function (NOT `notify`, which would 401). Migration: `20260407070000_promote_top_waitlisted_push.sql`; hold value sourced from `get_waitlist_hold_minutes()` since `20260504070000_waitlist_functions_use_hold_helper.sql`. NOTE: migration `20260502030000_promote_on_pending_payment_cancel.sql` (intended to broaden the trigger to fire on `pending_payment → cancelled` as well, plus add a capacity check) is on disk but NOT applied — see "Pending architectural fixes" below.

### PaymentIntent hold gate (Gate 0.5)
The `create-payment-intent` Edge Function validates hold state **before** calling Stripe. When `game_id` is in metadata:
1. Looks up the caller's `pending_payment` booking for that game (by `user_id + game_id + status`)
2. If found with `hold_expires_at <= now()`: returns HTTP 409 `hold_expired` — no Stripe call is made
3. If found with valid hold: uses `pi-{booking_id}-{amount}` as idempotency key (scoped per player, not per game — prevents successive promoted players sharing a Stripe PI)
4. If no `pending_payment` booking (fresh booking): passes through, uses `pi-{game_id}-{amount}` key
5. If the DB query itself errors: returns HTTP 503 "Unable to verify your booking hold. Please try again." — **fail-closed**: no Stripe PI is created, avoiding orphaned payment state that would need manual reconciliation

iOS handles 409 by resetting promoted state and calling `refreshBookings` so the expired UI appears without a manual refresh. 503 is caught by the existing "temporarily unavailable" handler.

### Defence-in-depth chain for expired holds
1. **Cron job** (`revert_expired_holds_and_repromote`, every minute): reverts expired holds to cancelled (forfeit) and inline-promotes the next eligible waitlister.
2. **PaymentIntent gate** (Edge Function Gate 0.5): blocks Stripe call for expired hold — no charge created
3. **confirmPendingBooking filter** (`hold_expires_at=gt.{now}` PATCH filter): blocks confirmation even within the cron window
4. **Client fast-fail** (AppState pre-flight): instant feedback from cached state before network call

### Pending architectural fixes (NOT live in production)
The following migration files are recorded as applied in `supabase_migrations.schema_migrations` (the version row exists) but their DDL effects are absent from the live function bodies — likely because someone hand-edited the functions back to the older design via SQL Editor after the migration was registered. **The migration table is not a reliable indicator of live behaviour for these functions.** Always verify with `pg_get_functiondef` before relying on the described behaviour.
- `20260502030000_promote_on_pending_payment_cancel.sql` — would broaden the `promote_top_waitlisted` trigger to fire on `pending_payment → cancelled` (in addition to `confirmed → cancelled`), add a capacity check, and simultaneously remove inline promotion from the cron. Live `promote_top_waitlisted` body still has the narrow condition (`OLD.status IS DISTINCT FROM 'confirmed'` early-return) and live `revert_expired_holds_and_repromote` still does inline promotion. **Consequence:** when a user declines a hold mid-window via `cancel_booking_with_credit` (`pending_payment → cancelled`), the next waitlister is **not** promoted and is stranded on the waitlist forever — the seat is permanently lost from circulation. Known production bug. Applying the trigger broadening **without** simultaneously removing cron inline promotion would create double-promotion (the 5/4 over-booking class). The two changes must land together.
- `20260501020000_book_game_qualify_user_id.sql` — would add the members-only club gate and `auth.uid() = p_user_id` check to `book_game`, plus column-qualify references. Live `book_game` body has neither gate (DECLARE block omits `v_members_only`, `v_club_id`, `v_is_member`; no `auth.uid()` check; no `JOIN clubs c ON c.id = g.club_id`). Production `book_game` currently has no members-only enforcement at the booking RPC and no `auth.uid()` check — RLS provides the security boundary, but the gate behaviour intended by the migration is absent. Separate decision, out of scope for the hold-value centralization.

### Booking creation — server-authoritative (implemented 2026-04-26, paid flow hardened 2026-04-27, admin path hardened 2026-05-01)
`AppState.requestBooking` calls `SupabaseService.bookGame` → `rpc/book_game` PostgreSQL `SECURITY DEFINER` function. The RPC locks the `games` row with `SELECT ... FOR UPDATE`, counts `confirmed + pending_payment` seats inside that lock, and inserts with the server-determined status (`confirmed` or `waitlisted`). The client never decides booking status — `isFull` is display-only. Migrations: `20260426060000_book_game_rpc.sql`, `20260427030000_book_game_hold_for_payment.sql`.

**Admin add-player path** (`AppState.ownerAddPlayerToGame` → `SupabaseService.ownerCreateBooking` → `rpc/owner_create_booking`) follows the same invariant. Migration: `20260501030000_owner_create_booking_rpc.sql`. The RPC takes the same `FOR UPDATE` lock on the games row and counts `confirmed + pending_payment` before deciding confirmed vs waitlisted. Caller must be club owner (`clubs.created_by`) or row in `club_admins`. DUPR is bypassed (intentional admin privilege). The legacy direct PostgREST INSERT into `bookings` is removed — never reintroduce it; it ignored `pending_payment` seats and allowed `confirmed + pending_payment > max_spots`.

- `liveGameIsFull` is still read client-side as a **hint only** for the payment pre-flight guard — skips the "payment required" fast-fail when the game appears full so waitlist joins on paid games are not blocked. This is not authoritative; the server determines confirmed vs waitlisted.

### Paid fresh booking flow (hardened 2026-04-27 — fixes paymentIntentInTerminalState)
**Root cause of the bug:** `create-payment-intent` used a game-scoped Stripe idempotency key for fresh bookings. Stripe returned the same already-charged PI on rebook → `paymentIntentInTerminalState` on PaymentSheet load.

**Fixed flow** — fresh paid bookings now use the same `pending_payment` → `confirmPendingBooking` path as waitlist promotions:
1. `preparePaymentSheet` calls `appState.reservePaidBooking(for:creditsAppliedCents:)` → `book_game(p_hold_for_payment=TRUE)` → DB creates `pending_payment` booking with `hold_expires_at = now() + get_waitlist_hold_minutes()` (currently sourced from `app_config('waitlist_hold_minutes')`).
2. `create-payment-intent` Gate 0.5 finds the `pending_payment` booking → uses `pi-{booking_id}-{amount}` as idempotency key → always creates a **fresh** PI
3. PaymentSheet loads; on `.completed` → `confirmPendingBooking(bookingID)` → `confirmed`

- `reservePaidBooking` is skipped when `isPendingPaymentCompletion = true` (booking_id already set by "Complete Booking" button or cancel+retry path)
- If `book_game` returns `waitlisted` (game filled between client check and DB lock) → payment aborted, waitlist message shown
- If `book_game` returns 409 (existing `pending_payment` from a previous attempt) → refresh, reuse existing booking_id
- `p_hold_for_payment = FALSE` by default — free games, `requestBooking` direct path, and admin bookings are unchanged

### Waitlist position compaction (implemented 2026-04-27)
Waitlist positions are always sequential (1, 2, 3 …). Gaps are healed automatically by the `trg_compact_waitlist_on_leave` AFTER UPDATE trigger on `bookings`, which fires whenever a booking transitions FROM `waitlisted` to any other status and calls `recompact_waitlist_positions(game_id)`. Migration: `20260427080000_waitlist_compaction.sql`.

- `recompact_waitlist_positions(p_game_id)` acquires `SELECT games FOR UPDATE` before rewriting positions — the same lock `book_game` holds when reading `MAX(waitlist_position)`. This serialises concurrent inserts against compaction so no gap can form between the two operations.
- **Admin drag-reorder is preserved**: `ownerUpdateBooking` keeps both bookings in status `waitlisted` (only position integers swap). The trigger condition `OLD.status = 'waitlisted' AND NEW.status != 'waitlisted'` is FALSE → compaction does not fire.
- **No infinite loop**: the compaction UPDATE only changes `waitlist_position`, not `status`. The trigger condition is FALSE for position-only updates.
- All five leave events are covered by the single trigger: self-cancel, admin-cancel, `promote_top_waitlisted`, `promote_waitlist_player` RPC, and `revert_expired_holds_and_repromote` re-promotion step.

### Do not reintroduce
- **Hold-minutes value is centralized in `app_config('waitlist_hold_minutes')` — verified live 2026-05-04. DO NOT TOUCH.** All four hold-setting functions (`book_game`, `promote_top_waitlisted`, `revert_expired_holds_and_repromote`, `promote_waitlist_player`) read `get_waitlist_hold_minutes()`, which reads the `app_config` row. This is the SINGLE source of truth for hold duration across every waitlist path. To change the hold value end-to-end: `UPDATE app_config SET value = 'N' WHERE key = 'waitlist_hold_minutes';` — no function recreation, no migration, takes effect on the next call. **Never reintroduce a hardcoded hold-minutes constant in any of these four functions** (`v_hold_mins CONSTANT INT := N`, `p_hold_minutes INT DEFAULT N`, or any other literal source). Reverting any one of them to a literal will silently re-introduce the cross-path drift that produced the original 30-vs-2 mismatch. Migrations: `20260504060000_app_config_waitlist_hold_helper.sql` (additive: row + helper) and `20260504070000_waitlist_functions_use_hold_helper.sql` (surgical: each function's CONSTANT replaced by helper, no other logic changed). **Live verification log (2026-05-04):** end-to-end test on a paid game at 8/8 capacity confirmed: trigger-driven promotion sets a 30-min hold (helper → 30); cron-driven re-promotion after hold expiry sets a 30-min hold (helper → 30); admin-add to a 7-confirmed + 1-pending_payment game correctly waitlists the new player at the bottom of the queue (capacity invariant `confirmed + pending_payment <= max_spots` honoured by `owner_create_booking`).
- **The `promote_top_waitlisted` trigger condition is currently narrow** (`OLD.status = 'confirmed' AND NEW.status = 'cancelled'` only — verified live 2026-05-04). The known W1-decline-strands-W2 bug (a user declining a hold via `cancel_booking_with_credit` does not promote the next waitlister) exists because of this narrow condition. The fix is migration `20260502030000_promote_on_pending_payment_cancel.sql`, which broadens the trigger to also fire on `pending_payment → cancelled` AND simultaneously removes inline promotion from the cron. **Those two changes are coupled** — applying the trigger broadening alone would create double-promotion (5/4 over-booking class) because both the broadened trigger and the cron's inline path would promote on every hold expiry. When you eventually apply the fix, both changes must land in the same migration. See "Pending architectural fixes" above.
- **The cron `revert_expired_holds_and_repromote` currently does inline promotion** (verified live 2026-05-04: forfeit + push + re-pick next waitlister + promote inline). This is the LIVE behaviour; the next waitlister gets promoted from inside the cron loop, not from a fan-out trigger. **Do not remove the cron's inline promotion in isolation** — until the trigger is broadened (paired migration), removing the cron's inline path leaves a forfeited hold with no promotion of the next waitlister. The two changes are coupled. See "Pending architectural fixes" above.
- **Never wire two triggers to `promote_top_waitlisted()` on `bookings`.** Only one trigger may fan promotion off a single status change. **History (2026-05-02):** an older hand-created trigger `auto_promote_waitlist` (AFTER UPDATE) and the migration-managed `trg_promote_top_waitlisted` (AFTER UPDATE OF status) coexisted; both called the same function. Every confirmed→cancelled fired the function twice → two waitlisters promoted per freed seat → 5/4. Reference fix: migration `20260502020000_drop_duplicate_promote_trigger.sql`. Before adding any new trigger to `bookings`, run `SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid='bookings'::regclass AND NOT tgisinternal` and confirm no existing trigger calls the same function. Prefer one canonical migration-managed trigger; never create one via SQL Editor without dropping any prior version first.
- **Never let a client promote a waitlister** — promotion (waitlisted → pending_payment / confirmed) is decided exclusively by the `promote_top_waitlisted` trigger (on `confirmed → cancelled`) and the `revert_expired_holds_and_repromote` cron (on hold expiry). Both lock the games row, count `confirmed + pending_payment`, and promote a single waitlister atomically. Do not reintroduce `autoPromoteWaitlistIfPossible`, `promoteWaitlistPlayerForPaidGame`, or any iOS/Android/web direct PATCH that flips `bookings.status` from `waitlisted` to `pending_payment` or `confirmed`. **History (2026-05-02):** an iOS admin-only auto-promote ran *after* the trigger had already promoted waitlister #1 to `pending_payment`. The client counted only `confirmed` for openSlots, computed 1 free seat, and PATCHed waitlister #2 to `pending_payment` with no server check. Both paid → game ended at 5/4 confirmed for max=4. The fix is removal, not "make the count smarter" — server triggers already do this correctly and racing the trigger is fundamentally unsound. The `promote_waitlist_player` RPC (migration `20260501040000_promote_waitlist_player_active_seats.sql`) remains as a manual admin/SQL safety net; it locks the games row and counts active seats — never call it from a client without that lock pattern.
- **Never let a client assign booking status** — `book_game` (player path) and `owner_create_booking` (admin path) are the only places `confirmed` vs `waitlisted` is decided. Do not reintroduce `createBooking` calls with a client-computed `status` in `AppState.requestBooking`, and do not reintroduce direct `POST /bookings` from `ownerCreateBooking`.
- **Never count only `confirmed` for capacity** — `pending_payment` physically holds a seat. The invariant is `confirmed + pending_payment <= max_spots` everywhere it matters (server: `book_game`, `owner_create_booking`, `promote_waitlist_player`, `revert_expired_holds_and_repromote`; client: any UI hint or "spots remaining" display, including any `openSlots = maxSpots - confirmedCount` calculation).
- **Never re-promote a user who just forfeited** — when a hold expires and `revert_expired_holds_and_repromote` cancels the booking, the cancelled row is excluded from the next-waitlister query (`WHERE status = 'waitlisted'`). Keep that filter; do not fall back to "any non-confirmed" or you'll re-introduce the infinite loop.
- **Never let a client set `hold_expires_at` directly** — `book_game(p_hold_for_payment=TRUE)` and `promote_waitlist_player` compute `hold_expires_at = now() + get_waitlist_hold_minutes()` server-side. The client passes only a boolean flag; the server is authoritative on the expiry value. The duration itself is read from `app_config('waitlist_hold_minutes')` — never reintroduce a hardcoded constant in any function or any client.
- **Never trust client-side `isFull` for booking decisions** — it is display-only; server RLS and the trigger enforce correctness
- **Never remove the games row lock from `recompact_waitlist_positions`** — without it a concurrent `book_game MAX(waitlist_position)` read can race with a position rewrite, leaving a gap
- **Never remove the `hold_expires_at=gt.{now}` filter** from `confirmPendingBooking` — it is the correctness backstop if the cron job is delayed
- **Never call `confirmPendingBooking` on a free game** — free game promotions go directly to `confirmed`; there is no hold to complete
- **Never remove Gate 0.5 from `create-payment-intent`** — without it an expired hold can charge the user via Stripe even though `confirmPendingBooking` will then block them

## Stripe Payments

- Stripe iOS SDK (`StripePaymentSheet`) is installed and wired into `GameDetailView`
- `StripeAPI.defaultPublishableKey` set in `BookADinkApp.init()` from `SupabaseConfig.stripePublishableKey`
- `create-payment-intent` Edge Function at `supabase/functions/create-payment-intent/index.ts` — accepts `{ amount, currency, metadata }`, returns `{ client_secret }`
- Apple Pay configured with `merchantId: "merchant.com.bookadink"`, `merchantCountryCode: "AU"` — requires Apple Pay capability + merchant ID in Xcode and domain verification in Stripe Dashboard
- Currently in **test mode** (`pk_test_`, `sk_test_`). Switch to `pk_live_`/`sk_live_` for production
- Edge Functions called from iOS use the **anon key** (not user JWT) for `apikey` and `Authorization` headers — user JWT is only valid for PostgREST/DB calls

## Club Subscription Upgrade UI (hardened 2026-05-03)

`ClubUpgradePaywallView` is the single source of truth for plan selection, Stripe `PaymentSheet` presentation, post-payment polling, and entitlement refresh. Every upgrade entry point in the app routes here.

- **All upgrade CTAs must present `ClubUpgradePaywallView`.** Never call `appState.createClubSubscription` directly from a button. Never construct `PaymentSheet` for a subscription anywhere outside `ClubUpgradePaywallView`. The pattern is `@State paywallFeature: LockedFeature?` + `.sheet(item: $paywallFeature) { ... ClubUpgradePaywallView(club:, lockedFeature:) }`.
  - **History (2026-05-03):** `ClubFormBody` and `ClubPlanBillingSettingsView` each duplicated the Stripe + polling logic. The duplicate in `ClubFormBody` polled only ~6s, while the canonical paywall polls ~31s — webhooks routinely landed after the 6s window so upgrades silently appeared to fail. Both duplicates were deleted; both views now route to the paywall via `LockedFeature.managePlan`. Reference: this file's `subscriptionUpgradeButton` helpers (now thin wrappers).
- **Polling window is `[2, 3, 4, 5, 7, 10]s` (≈31s)** in `ClubUpgradePaywallView.presentPaymentSheet`. Do not shorten it; Stripe webhook delivery routinely takes 5–15s in production. After the loop exits, `fetchClubEntitlements` is called **regardless of poll outcome** so a slow-but-arrived webhook still unlocks the UI on the next view re-render.
- **All gated screens must refresh entitlements on appearance.** Any view whose body branches on `FeatureGateService.canUse...` (delayed publishing, recurring games, payments, game limit, member limit, analytics) must call `await appState.fetchClubEntitlements(for: club.id)` inside its top-level `.task`. This closes the race where a webhook lands after the paywall's polling window but before the user navigates to a gated screen. Currently wired in `OwnerCreateGameSheet`, `OwnerEditGameSheet`, `ClubPlanBillingSettingsView`, `ClubFormBody` Plan & Billing section, `ClubDashboardView`, and `GameDetailView`. Always append to an existing `.task` rather than adding a second one.
- **Feature gates are deny-by-default.** `FeatureGateService` returns `.blocked` whenever `entitlements` is `nil`. Never add a fallback that grants access on missing data. Both `OwnerCreateGameSheet` and `OwnerEditGameSheet` must wrap any gated toggle in `if case .blocked = <gate> { ProLockedRow { paywallFeature = .<feature> } } else { … real toggle … }`. Asymmetry between Create and Edit (one gated, the other not) is a bug, not a UX choice.
- **`LockedFeature.managePlan`** is the generic billing-context paywall payload — used from Settings → Plan & Billing where the entry isn't tied to a specific locked feature. The contextual cases (`.payments`, `.scheduledPublishing`, etc.) drive the paywall header copy and highlight bullets via `lockedFeature.highlights(limits:)` — pick the case that matches what the user just bumped into.
- **Never reintroduce `presentSubscriptionPaymentSheet` or any inline Stripe upgrade flow.** The `subscriptionUpgradeButton` helpers in `ClubFormBody` and `ClubPlanBillingSettingsView` are intentionally thin wrappers that only set `paywallFeature = .managePlan`; their `priceID` parameter is ignored.

## Club Role Lifecycle (server-authoritative, implemented 2026-05-04)

Three-table model (unchanged): `clubs.created_by` is the immutable historical creator; `club_admins (club_id, user_id, role)` holds `'owner'`/`'admin'` rows; `club_members (... status)` holds membership lifecycle. Owner is dual-source — `clubs.created_by` AND a `club_admins` row with `role='owner'` — and the two are kept in sync by triggers (see below). Migrations:
- `20260504010000_club_role_lifecycle.sql` — RPCs, sync triggers, last-owner protection, `delete_club` patch
- `20260504020000_club_admins_lock_writes.sql` — RLS lock-down on direct writes
- `20260504025000_notification_type_role_changed.sql` — adds `'role_changed'` enum value
- `20260504030000_role_audit_and_logging.sql` — `club_role_audit` table, RPC instrumentation (audit insert + `RAISE LOG`), push trigger

- **Role mutations are SECURITY DEFINER RPCs only.** Three RPCs are the single write path: `promote_club_member_to_admin(p_club_id, p_user_id)`, `demote_club_admin_to_member(p_club_id, p_user_id)`, `transfer_club_ownership(p_club_id, p_new_owner_id, p_old_owner_new_role)`. All take `SELECT clubs FOR UPDATE` so concurrent transfers/promotions cannot race. Errors: `authentication_required`, `club_not_found`, `forbidden_owner_only`, `cannot_modify_self`, `cannot_demote_owner`, `target_not_approved_member`, `new_owner_not_approved_member`, `invalid_old_owner_role`, `cannot_remove_last_owner`.
- **Direct INSERT/UPDATE/DELETE on `club_admins` is denied by RLS.** The "Club owner can insert/update/delete club admins" policies were dropped in `20260504020000`. The only retained client-write policy is "Users can delete own admin record" (self-relinquish), and even that is guarded by the `protect_last_owner` BEFORE DELETE trigger. **Never reintroduce client-side `INSERT`/`UPDATE`/`DELETE` against `club_admins`** — use the RPCs.
- **iOS write surface is a single method**: `SupabaseService.setClubAdminAccess(clubID:userID:makeAdmin:)` dispatches to the promote/demote RPC. `transferClubOwnership(clubID:newOwnerID:oldOwnerNewRole:)` is the second method. Both surfaced on `ClubDataProviding`. **Never call PostgREST `club_admins` directly from a new view or service** — it will fail silently (`try?`) or surface as 401/403.
- **Owner-row sync is automatic via triggers** (`20260504010000`):
  - `trg_ensure_club_admins_owner_on_insert` (AFTER INSERT ON clubs) — every new club gets a `club_admins(role='owner')` row for its creator.
  - `trg_sync_club_admins_owner_on_update` (AFTER UPDATE OF created_by ON clubs) — when `transfer_club_ownership` updates `clubs.created_by`, the new owner's `club_admins` row is upserted to `role='owner'`.
  - `trg_cascade_club_admins_on_member_removal` (AFTER DELETE ON club_members) — removing a member also strips their admin row.
  - The legacy iOS `try?` writes at `SupabaseService.swift:1711` (createClub owner row) and `:2185` (removeMembership admin cascade) became dead code post-migration; they may be deleted in a follow-up cleanup but are harmless as-is.
- **Last-owner protection** is enforced at three layers: (1) the `transfer_club_ownership` RPC requires `p_new_owner_id` to be an approved member and updates `created_by` before demoting the old owner; (2) `protect_last_owner` BEFORE DELETE trigger on `club_admins` rejects deletion of the only `role='owner'` row while the parent club still exists; (3) `delete_club()` sets a transaction-local config flag (`app.role_bypass_delete_club_id`) that the trigger recognises as a teardown context — without that flag, club deletion would self-deadlock on its own owner row.
- **Never compute or cache role mutations optimistically.** After any role mutation, AppState calls `refreshClubAdminRole(for: club)` AND `refreshOwnerMembers(for: club)` and writes server truth into both `clubAdminRoleByClubID` (current-user role cache) and `ownerMembersByClubID` (member list). The previous optimistic-update pattern silently lied across 15+ UI sites that branched on `appState.isClubAdmin(for:)` / `isClubOwner(for:)` — the demoted user's local cache stayed admin until next bootstrap. **History (2026-05-04):** the demote bug was reproducible on the demoting device itself when an admin self-demoted; the network call succeeded, but the `clubAdminRoleByClubID` entry persisted because the optimistic path only updated `ownerMembersByClubID`.
- **Cross-device push is server-driven** (since 2026-05-04). Every role change inserts an audit row in `club_role_audit`; the `trg_enqueue_role_change_push` AFTER INSERT trigger calls the `role-change-push` Edge Function (`--no-verify-jwt`) which inserts a `notification_type='role_changed'` row and sends APNs. The actor of the change is excluded from the push (no self-notify). The Edge Function uses hard-coded project URL + anon key per the "Server-Side Push Triggers" pattern — placeholders in the migration must be replaced before applying. **Never add a client-side `triggerNotify` for `admin_promoted` / `ownership_transferred` / role-change events** — it duplicates the server-side push. The legacy iOS calls were removed when this landed.
- **Audit trail** lives in `club_role_audit` (id, club_id, target_user_id, actor_user_id, change_type, old_role, new_role, reason, created_at). `change_type` ∈ `'promoted_to_admin'`, `'demoted_to_member'`, `'transferred_in'`, `'transferred_out_to_admin'`, `'transferred_out_to_member'`, `'club_created'`, `'member_removed_cascade'`, `'self_relinquished'`. RLS: club owner reads all rows for their club; target user reads their own. **Never write directly from a client** — only the SECURITY DEFINER RPCs and the `ensure_club_admins_owner_on_club_insert` / `cascade_club_admins_on_member_removal` triggers insert. **Never DELETE or UPDATE rows** — append-only by design (no client policy exists for those).
- **`RAISE LOG` inside RPCs** emits structured lines in Postgres logs (Supabase → Logs → Postgres) for production tracing: `club_role: promote club=… target=… actor=…`, `club_role: demote …`, `club_role: transfer …`. Search for `club_role:` to filter. These are at LOG level so they appear without enabling DEBUG.
- **Rate limiting** (since `20260504040000`): each role-mutation RPC counts the caller's `club_role_audit` rows for the target club in the last 60 seconds and rejects with `'rate_limited'` once 10 events have been written in that window. `transfer_club_ownership` writes 2 audit rows per call so it costs 2× of the budget — intentional weighting (transfers are heavier user-facing events). iOS surfaces this as `SupabaseServiceError.rateLimited` → "Too many role changes in a short time. Please wait a minute and try again." The constant `v_max_per_minute` is duplicated across all three RPCs; if you tune it, change all three.
- **Role History UI** is a club-owner-only sheet (`OwnerRoleHistorySheet`) opened from the Manage section of `ClubDashboardView` via `OwnerToolSheet.roleHistory`. The nav card is gated on `appState.isClubOwner(for: club)` — admins read their own audit rows via the table directly (RLS), but the aggregated club-wide history view is owner-only by RPC (`get_club_role_history` rejects non-owner non-admin callers with `forbidden_owner_or_admin_only`). Storage: `AppState.roleHistoryByClubID: [UUID: [ClubRoleAuditEntry]]`. Loaded via `refreshClubRoleHistory(for:)`. Pull-to-refresh + `.task` on appearance.
- **Lightweight analytics**: view `v_club_role_change_summary` (per-club, per-month, per-change_type counts) and RPC `get_club_role_change_summary(p_club_id, p_days)` for the last-N-days breakdown. Both rely on `club_role_audit` RLS so they degrade safely. Not yet surfaced in any iOS view — wire into the existing `AnalyticsSheet` if the metric is ever requested for the dashboard.
- **`ClubAdminRole` enum** stays at `.owner` / `.admin`. There is intentionally no `.member` case — non-admin members simply have no `club_admins` row. The third "role" passed to `transfer_club_ownership` (`'admin'` / `'member'`) is wire-only — it does not need a Swift enum case. `transferClubOwnership(...oldOwnerNewRole: String)` validates the string at the call site.

## Push Notifications & Email

- APNs push notifications are **live** — secrets (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`, `APNS_USE_SANDBOX`) set in Supabase
- Email notifications via Resend — `send-notification-email` Edge Function triggered by DB trigger `send_notification_email` on `notifications` table (uses `net.http_post`)
- DB trigger uses anon key for Authorization when calling the Edge Function
- **If Edge Functions return "Unregistered API key" on the internal Supabase client**: redeploy the function (`supabase functions deploy <name> --no-verify-jwt --project-ref <ref>`) to refresh the auto-injected `SUPABASE_SERVICE_ROLE_KEY`
- `notify` Edge Function at `supabase/functions/notify/index.ts` — inserts into `notifications` table (fires email trigger) and optionally sends APNs push. Called directly from iOS via `triggerNotify()`. **Requires a valid user JWT** (calls `getCallerID`); returns 401 for anon-key callers. **Never call `notify` from a DB trigger or pg_cron job** — use the purpose-built `--no-verify-jwt` functions instead (see below).

## Server-Side Push Triggers — Critical Setup (hardened 2026-04-30)

DB triggers and pg_cron jobs that fan out push notifications via `net.http_post` have two failure modes that all silently produce 0 pushes while logging nothing user-visible. Both have bitten this project. Read this section before adding or editing any trigger/cron that sends push notifications.

### Failure mode 1: `current_setting('app.supabase_url', true)` returns NULL on Supabase hosted

The pattern `current_setting('app.supabase_url', true) || '/functions/v1/...'` from older migrations (`20260407070000_promote_top_waitlisted_push.sql`, `20260426100000_waitlist_hold_expiry_cron.sql`, `20260430030000_release_scheduled_games_rpc.sql`) **does not work** on Supabase hosted. `ALTER DATABASE postgres SET app.supabase_url = '...'` returns `ERROR: 42501: permission denied to set parameter`, so the GUC stays unset and `current_setting(..., true)` returns NULL. Every cron tick then fails with `null value in column "url" of relation "http_request_queue" violates not-null constraint` and no push is sent. The `IF v_supabase_url IS NOT NULL` guard pattern silently no-ops the push from inside trigger functions.

**Fix:** hard-code the project URL and anon key as `CONSTANT TEXT` literals in the function body / cron command. The anon key is already public (embedded in the iOS app binary) so this is no incremental risk. RLS — not the anon key — is what protects data. Service role key must NOT be used here; `--no-verify-jwt` Edge Functions accept anon Bearer fine, and using service role would unnecessarily expose elevated credentials to anyone with `pg_proc` read access.

Reference fix: `supabase/migrations/20260430040000_waitlist_push_hardcode_credentials.sql` and the cron schedule in `20260430030000_release_scheduled_games_rpc.sql`.

### Failure mode 2: routing DB triggers at `/functions/v1/notify`

`notify` runs `getCallerID` and rejects anon-key callers with 401 "Authentication required". The migration history of `promote_top_waitlisted` originally pointed at `/functions/v1/notify`; the live trigger had been hand-edited to call `promote-top-waitlisted-push` but the migration file was never updated. Re-applying the original migration silently re-broke push notifications.

**Rule:** DB triggers and pg_cron functions must call **purpose-built `--no-verify-jwt` Edge Functions only**. These are deployed without auth gates and use `SUPABASE_SERVICE_ROLE_KEY` from env for DB ops. Do NOT call `notify`, `triggerGamePublishedNotify`, or any function that runs `getCallerID` from server-side code.

| Server-side caller | Target Edge Function | Payload shape |
|---|---|---|
| `promote_top_waitlisted` trigger (paid) | `promote-top-waitlisted-push` | `{ booking_id, user_id, game_id, type: "waitlist_promoted_pending_payment" }` |
| `promote_top_waitlisted` trigger (free) | `promote-top-waitlisted-push` | `{ booking_id, user_id, game_id, type: "waitlist_promoted" }` |
| `revert_expired_holds_and_repromote` cron (paid re-promotion) | `promote-top-waitlisted-push` | same as above (paid variant) |
| `revert_expired_holds_and_repromote` cron (free re-promotion) | `promote-top-waitlisted-push` | same as above (free variant) |
| `game-publish-release` cron (delayed publish) | calls `release_scheduled_games()` RPC, then fans out via `_shared/notify-new-game.ts` internally | n/a — fan-out happens inside the Edge Function |

### Rule: when migration source disagrees with live function source, the live one is the truth

Before rewriting any trigger or RPC from a migration file, run `SELECT prosrc FROM pg_proc WHERE proname = '<function_name>'` and audit the live body. If it diverges from the migration, someone hand-edited it via SQL Editor to fix something the migration got wrong. Inheriting the migration's URL/auth pattern without checking will silently re-break the path.

### Diagnostic playbook — when a push isn't arriving

Run these in order. Each query narrows the failure to one layer of the chain:

```sql
-- 1. Is the cron / trigger function source what you expect?
SELECT prosrc FROM pg_proc WHERE proname = '<function_name>';
-- Look for: hard-coded https://… URL, correct /functions/v1/<name>, anon key in Bearer.

-- 2. Did the cron fire? (cron path only)
SELECT status, return_message, start_time
  FROM cron.job_run_details
 WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = '<job>')
 ORDER BY start_time DESC LIMIT 5;
-- "succeeded" = http_post enqueued. "failed" with null url = current_setting() returns NULL.

-- 3. What did the Edge Function return?
SELECT id, status_code, content::text, created
  FROM net._http_response ORDER BY created DESC LIMIT 10;
-- 200 with expected body = push pipeline worked.
-- 401 "Authentication required" = trigger pointed at notify (or another auth-gated function).
-- 500 "structure of query does not match" = RPC return type mismatch (cast string columns ::text).

-- 4. Did the in-app notification row land?
SELECT user_id, title, body, type, created_at
  FROM notifications WHERE type = '<expected_type>' ORDER BY created_at DESC LIMIT 5;
-- Independent of APNs delivery. If row exists but no push arrived, it's a token / APNs issue.

-- 5. Does the target user have a push token?
SELECT id, push_token IS NOT NULL AS has_token FROM profiles WHERE id = '<user_id>';
```

### Things that look like bugs but aren't

- The fan-out filters out `created_by` for `new_game` notifications — the creator of a game does NOT receive their own publish push. Test from a different account.
- `promote-top-waitlisted-push` short-circuits when `notification_preferences.waitlist_push = false` (returns `{notified: true, pushed: false, reason: "user_pref_off"}`). The in-app notification row still inserts.
- 410 from APNs auto-clears `profiles.push_token` and returns `reason: "stale_token_cleared"`. User must re-launch the iOS app to re-register the token.

## Multi-device APNs fan-out (in progress 2026-05-05)

iOS has always written each device's APNs token to two places: `profiles.push_token` (single TEXT column) and `push_tokens` (multi-row table, one row per device). Until 2026-05-05 every Edge Function read only the single column, so the most-recently-registered device overwrote the others and only one device per user received pushes — most often visible as "iPhone gets push, iPad does not" once a user signed in on both.

**Single read path:** `supabase/functions/_shared/push-tokens.ts` exports `getPushTokensForUser(supabase, userID)` which returns `{ tokens: string[]; fallbackUsed: boolean }`. It reads `push_tokens` first, falls back to `profiles.push_token` only when the table has zero rows for the user, de-dupes case-insensitively, and drops empty strings. Senders fan out APNs to every returned token. Per-token failures are swallowed so one dead token never aborts the rest.

**Stale-token handling (410 from APNs):** the helper exports `clearStaleToken(supabase, userID, token)` which DELETEs the matching `push_tokens` row and NULLs `profiles.push_token` only when it equals the stale token (preserves a still-valid legacy token on the profile row).

**Required unique index:** migration `20260505070000_push_tokens_unique_index.sql` adds `push_tokens_user_token_unique ON push_tokens(user_id, token)`. Without it iOS's `Prefer: resolution=merge-duplicates` upsert had no constraint to merge against, so duplicate rows accumulated and PostgREST returned 409. The migration also dedups any pre-existing duplicates (keeps the lowest-ctid row per `(user_id, token)`).

**Migration status — only one Edge Function uses the helper so far:**
- ✅ `promote-top-waitlisted-push` — fan-out + per-token logging deployed.
- ⏸ Remaining (still read `profiles.push_token` only — unchanged behaviour, single-device users unaffected):
  `booking-confirmed`, `replacement-credit-issued-push`, `notify`, `club-chat-push`, `game-reminder-2h`, `game-reminder-24h`, `game-updated-notify`, `game-cancelled-notify`, `send-review-prompts`, `_shared/notify-new-game.ts`.

When migrating the remaining functions, use the same shape as `promote-top-waitlisted-push` (resolve tokens → loop send → on `StaleTokenError` call `clearStaleToken` and continue → return `{ token_count, pushed_count, stale_count, error_count, fallback_used }`). Keep the in-app `notifications` insert unchanged — one event still produces one row regardless of how many devices the user has.

**Hard constraints:**
- Never read `profiles.push_token` directly from a new sender — go through `getPushTokensForUser` so all senders share fallback semantics.
- Never short-circuit the fan-out loop on the first failure — one stale token must not block the others.
- Never NULL `profiles.push_token` for an arbitrary user when a 410 fires for a single device's token — only when the legacy column matches the stale value. Senders that previously did `update({ push_token: null }).eq('id', user_id)` unconditionally on 410 are bugs to fix when migrated.
- Never drop `push_tokens_user_token_unique` without first replacing the helper.

## Club Chat Performance

- `commentDraft` state **must** live inside `ClubNewsPostCard` as `@State private var commentDraft: String = ""` — lifting it to the parent view (as `[UUID: String]`) causes full re-render of all cards on every keystroke, making the keyboard feel laggy
- Club news comments and reactions fetched concurrently via `async let` in `fetchClubNewsPosts`
- Like/comment updates use optimistic UI — mutate local cache immediately, revert on failure — do NOT call `refreshClubNews` after every interaction

## DUPR

- DUPR ratings have two storage paths: Supabase `profiles.dupr_rating` and UserDefaults (`StorageKeys.duprRatingsByUserID` as `[userIDString: {d: Double, s: Double}]`)
- `loadProfileFromBackendIfAvailable` syncs Supabase → UserDefaults after every profile fetch to keep them in sync (fixes admin DUPR updates not reflecting on member profile)
- `DUPRHistoryCard` chart: black line, black dots with white border, Y-axis DUPR values, X-axis DD/MM dates as `.annotation(position: .bottom)` on each PointMark (not `chartXAxis` renderer — avoids last label clipping)

## DUPR Booking Gate (server-authoritative, implemented 2026-04-28)

- `games.requires_dupr = true` is now enforced by `book_game()` RPC server-side — not client-only. Client fast-fail in `AppState.requestBooking` remains as UX guidance only.
- `profiles.dupr_id TEXT NULL` — player's DUPR player ID string. This is the server's check field. Migration: `20260428020000_book_game_dupr_enforcement.sql`.
- **Required DB migration**: `ALTER TABLE profiles ADD COLUMN IF NOT EXISTS dupr_id TEXT NULL;`
- `book_game()` reads `requires_dupr` and `max_spots` in the same `FOR UPDATE` lock. If `requires_dupr = true` and `profiles.dupr_id IS NULL OR length(trim(dupr_id)) < 6`, raises `'dupr_required'` — applies to both confirmed spots and waitlist joins.
- `saveCurrentUserDUPRID` in AppState persists to UserDefaults and fires `dataProvider.patchDuprID(userID:duprID:)` as a background Task to sync to Supabase.
- `loadProfileFromBackendIfAvailable` syncs DB `dupr_id` → `duprIDByUserID` / `duprID` on bootstrap so devices that logged in on another device already have the ID loaded.
- `SupabaseServiceError.duprRequired` — mapped from `"dupr_required"` in response body in `bookGame()`. Message: "Add and confirm your DUPR ID before booking this game."
- **Admin bypass (intentional)**: `ownerCreateBooking` uses a direct PostgREST INSERT (bypasses `book_game()`). Club owners/admins can add players regardless of DUPR status.
- **Never enforce DUPR client-side only** — Android and web must rely on the `dupr_required` error code, not local state. The server is authoritative.

## New Services & Views (unstaged)

- `LocationManager.swift` / `LocationService.swift` — location services
- `ClubBookGameView.swift` — book-a-game flow from club context
- `NearbyGamesView.swift` — nearby games discovery
- `SplashView.swift` — splash/loading screen
- `Views/Home/` — home tab views
- `supabase/functions/archive-old-games/` — Edge Function to archive old games

## Credits & Cancellation Refunds (implemented 2026-04-13)

### Architecture
- Credits are **club-scoped** — a credit earned at Club A cannot be used at Club B
- `player_credits` table: `(user_id UUID, club_id UUID, amount_cents INT, currency TEXT)` with `UNIQUE (user_id, club_id, currency)` — one row per player per club
- `AppState.creditBalanceByClubID: [UUID: Int]` — in-memory cache keyed by club UUID; `creditBalance(for clubID:)` reads from it
- `creditBalanceByClubID` is `@Published` — all views that call `appState.creditBalance(for:)` re-render automatically when it changes

### Credit Issuance (cancellation refunds) — server-authoritative, replacement-aware (hardened 2026-05-05)
The credit model has two issuance paths and one idempotency guard:

- **Cutoff path** (immediate): `cancel_booking_with_credit(p_booking_id UUID)` SECURITY DEFINER RPC. On call: validates ownership, cancels the booking (which fires `promote_top_waitlisted`), re-reads `bookings.was_replaced`, and issues credit IFF eligible. Returns `(credit_issued_cents INT, was_eligible BOOL, new_balance_cents INT)` — return shape unchanged across migrations. Migrations: `20260427040000_cancel_booking_with_credit.sql` (initial), `20260502010000_cancel_booking_credit_balance_null_fix.sql` (NULL balance fix), `20260505020000_cancellation_policy_functions.sql` (per-club policy + replacement marker), `20260505040000_deferred_credit_and_replacement_tracking.sql` (current, replacement-aware).
- **Deferred path** (later): `credit_on_replacement_confirmed()` trigger fires `AFTER UPDATE OF status, fee_paid ON bookings` when a booking transitions INTO `confirmed`. It looks up the original cancelled booking via `replacement_booking_id` and issues credit using identical refund math.
- **Idempotency guard**: `bookings.replacement_credit_issued_at TIMESTAMPTZ NULL`. Stamped non-NULL the moment ANY credit is issued (cutoff path or deferred path). The deferred trigger's filter requires `replacement_credit_issued_at IS NULL`, so credit can be issued at most once per booking. Append-only.

Eligibility (managed-policy clubs only — `club_managed` clubs never issue credit, ever):
- **Outside cutoff** (`now() <= game.date_time - cancellation_cutoff_hours`) → cutoff path issues credit immediately, regardless of replacement.
- **Inside cutoff, free game with waitlister** → `promote_top_waitlisted` (free path) sets `was_replaced=TRUE` inline; cutoff path's post-cancel re-read sees TRUE and credits immediately.
- **Inside cutoff, paid game with waitlister** → `promote_top_waitlisted` (paid path) sets only `replacement_booking_id` (the held replacement is not yet "real"). Cutoff path returns 0. When the held waitlister actually confirms+pays (`status='confirmed' AND fee_paid=TRUE`), the deferred trigger fires, finds the original cancelled booking via `replacement_booking_id=NEW.id`, and credits.
- **Inside cutoff, no waitlister** → no credit at cancel time. If a waitlister later joins the queue and gets promoted via a separate cancellation event chain, they fill someone *else*'s freed seat — they do NOT fill the original cancelled booking's seat (which is unrelated to any later promotion). The original booking stays uncredited. This is intentional.
- **Hold expiry on the held replacement** → cron forfeits the held booking and re-points the original cancelled booking's `replacement_booking_id` to the next promoted waitlister (or NULLs it if no candidate). Forfeits do NOT issue credit and do NOT mark `was_replaced` on either booking. The deferred path can still credit the original if a later replacement actually confirms+pays.

Replacement tracking columns (added by `20260505030000_replacement_tracking_columns.sql`):
- **`bookings.replacement_booking_id UUID NULL REFERENCES bookings(id)`** — set on a CANCELLED booking by `promote_top_waitlisted` when it picks a waitlister. Re-pointed by `revert_expired_holds_and_repromote` when a held replacement forfeits; NULLed when no next candidate exists. **Set ONLY by server-side promotion paths.**
- **`bookings.replacement_confirmed_at TIMESTAMPTZ NULL`** — audit timestamp set when the replacement actually confirms (paid: confirmed AND fee_paid=TRUE; free: confirmed). Read by no decision logic.
- **`bookings.replacement_credit_issued_at TIMESTAMPTZ NULL`** — idempotency guard (see above).
- **`bookings.was_replaced BOOLEAN NOT NULL DEFAULT FALSE`** — set TRUE only when the freed seat is filled by a CONFIRMED replacement: free games inline (`promote_top_waitlisted` free path), paid games deferred (`credit_on_replacement_confirmed` trigger when `fee_paid=TRUE`). **Never** set on `pending_payment` promotion. **Never** set on a forfeit booking. Append-only.

Per-club cancellation policy (added by `20260505010000_cancellation_policy_columns.sql`):
- `clubs.cancellation_policy_type TEXT NOT NULL DEFAULT 'managed' CHECK ('managed','club_managed')`
- `clubs.cancellation_cutoff_hours INTEGER NOT NULL DEFAULT 12 CHECK (1..48)`
- To change either: `UPDATE clubs SET cancellation_policy_type = 'managed', cancellation_cutoff_hours = N WHERE id = …;` — next call to the RPC / next deferred-trigger fire sees the new value, no function recreation.
- **club_managed clubs**: cancel_booking_with_credit cancels but issues no credit; deferred trigger marks `was_replaced` + `replacement_confirmed_at` for audit but issues no credit. Refunds are handled off-platform.

Other invariants:
- Returns shape: `(credit_issued_cents INT, was_eligible BOOL, new_balance_cents INT)` — unchanged.
- Status cast: `v_booking.status::text NOT IN (...)` — **must cast to `::text`**; `booking_status` is a PG enum (see CLAUDE.md constraint).
- Refund math (identical in both paths): `fee_paid=true` → `platform_fee + club_payout + credits_applied`; credit-only → `credits_applied`; free/admin → 0.
- iOS: `AppState.cancelBooking(for:)` calls `dataProvider.cancelBookingWithCredit(bookingID:)` — single call, no client-side refund math, no client-side cutoff check, no client-side replacement detection.
- `creditBalanceByClubID[clubID]` is set directly from `result.newBalanceCents` (no second fetch).
- `lastCancellationCredit: CancellationCreditResult?` is a `@Published` signal — `GameDetailView`, `ClubDetailView`, and `BookingsListView` all observe it with `.onChange` to refresh immediately. This fires on the cutoff path (synchronous return). The deferred path notifies asynchronously via in-app notification + APNs push (see "Deferred-credit push" below).

### Deferred-credit push (`replacement_credit_issued`)
When the `credit_on_replacement_confirmed` trigger issues credit to the original cancelling user, it calls the `replacement-credit-issued-push` Edge Function via `net.http_post`. The function inserts a `notifications` row (type=`replacement_credit_issued`, reference_id=club_id) and sends an APNs push titled "Spot filled — credit issued" with body "Your cancelled spot was filled, so we've credited your account." The user's `creditBalanceByClubID[clubID]` will reflect the new balance on next `refreshCreditBalance(clubID:)`; the in-app notification cell deep-links to the club where the credit lives.

The push is suppressed for: `club_managed` clubs (no credit ever), zero-amount refunds (free/admin bookings with no credits applied), and outside-cutoff immediate credits (those flow through `cancel_booking_with_credit`'s synchronous return → `lastCancellationCredit` half-sheet, not through this trigger). Idempotency is guaranteed by `bookings.replacement_credit_issued_at IS NULL` in the trigger's filter — the column is stamped before the `net.http_post` call, so re-triggering the same UPDATE chain cannot produce a duplicate push. Migrations: `20260505050000_notification_type_replacement_credit_issued.sql` (enum value), `20260505060000_credit_on_replacement_confirmed_push.sql` (trigger body adds the http_post). Edge Function: `supabase/functions/replacement-credit-issued-push/index.ts` — deploy with `supabase functions deploy replacement-credit-issued-push --no-verify-jwt --project-ref <ref>`.

Notification preferences: the function tries to honour `notification_preferences.booking_confirmed_push` (closest existing column for booking-outcome events) and falls back to ON if the column or row is missing. No new column was added; if a dedicated `credit_push` preference is later introduced, the function's preference query is the single place to update.

### Credit Deduction (booking)
- **Do NOT use `use_credits` RPC via PostgREST** — PostgREST's schema cache on Supabase hosted does not reliably pick up newly created functions (`NOTIFY pgrst, 'reload schema'` is unreliable). The function exists in the DB but PostgREST returns PGRST202.
- `applyCredits` is implemented as a **direct PATCH on `player_credits`** via PostgREST:
  1. Fetch live balance with `fetchCreditBalance`
  2. Guard `currentBalance >= amountCents`
  3. PATCH with `amount_cents = currentBalance - amountCents` filtered by `user_id`, `club_id`, `currency`, and `amount_cents=gte.{amountCents}` (atomic safety net)
- Requires **UPDATE RLS policy** on `player_credits`: `USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id AND amount_cents >= 0)` — see migration `20260413100000_player_credits_update_policy.sql`
- **Optimistic update**: `creditBalanceByClubID[clubID]` is decremented immediately on the Main actor before the background Task fires, so the UI drops instantly. The Task then confirms with the authoritative DB value via `refreshCreditBalance`.
- All UUID filter values passed to PostgREST must be **lowercased** (`uuidString.lowercased()`) for consistent matching

### Credit Issuance (cancellation refunds)
- Handled entirely by `cancel_booking_with_credit` RPC — see section above. No separate credit-issuance step exists.
- Requires **INSERT + UPDATE RLS policies** on `player_credits` — `cancel_booking_with_credit` is SECURITY DEFINER so the upsert runs as the function owner, but the INSERT/UPDATE RLS policies remain for direct PostgREST access from other paths (e.g. `applyCredits`). See migrations `20260413090000_player_credits_insert_policy.sql` and `20260413100000_player_credits_update_policy.sql`.

### Credit display
- `GameDetailView`: credit toggle row shown when `fee > 0 && creditBalance(for: game.clubID) > 0 && canBook`. CTA button label computes net price inline: `min(balance, totalCents)` subtracted from fee. Cancellation success shows half-sheet with credited amount and new balance.
- `ClubDetailView`: credit banner between membership section and club info; loaded on `.onAppear` and `.refreshable`
- `BookingsListView`: one pill per club with positive balance; all balances refreshed concurrently via `withTaskGroup` on `.task`
- `GameDetailView.task`: uses `currentGame.feeAmount` (not `game.feeAmount`) so credit balance loads correctly even if the game was edited from free → paid before the view appeared. `onChange(of: currentGame.feeAmount)` triggers a re-load when fee changes while the view is open.

### Required DB setup (all migrations in `supabase/migrations/`)
- `20260413050000_credits_bootstrap.sql` — creates `player_credits` table, unique constraint, RLS SELECT policy, `issue_cancellation_credit` RPC, `use_credits` RPC (both kept in DB but not called from iOS)
- `20260413100000_player_credits_update_policy.sql` — adds UPDATE RLS policy required for the PATCH deduction path
- `20260413090000_player_credits_insert_policy.sql` — adds INSERT RLS policy required for first-time credit issuance (new row)
- `bookings.credit_refund_issued_at TIMESTAMPTZ NULL` — added by bootstrap migration (no longer checked client-side; idempotency is best-effort)
- `bookings.credits_applied_cents INT NULL` — must exist (used by both booking insert and refund computation)

### Hard constraints — do not reintroduce
- **Never compute cancellation refund amounts on the client** — `cancel_booking_with_credit` RPC and the `credit_on_replacement_confirmed` trigger are the only places the cutoff window, fee breakdown, and credit amount are computed. Do not reintroduce client-side cutoff checks or `platformFeeCents + clubPayoutCents + creditsAppliedCents` math in `AppState`.
- **Never hardcode the cancellation cutoff in `cancel_booking_with_credit`** — the cutoff is `clubs.cancellation_cutoff_hours` (per-club, default 12, range 1..48). The previous 6-hour literal was replaced 2026-05-05. Reverting to a hardcoded constant would re-introduce the cross-club drift problem (different clubs need different windows). Reconfigure with `UPDATE clubs SET cancellation_cutoff_hours = N WHERE id = …;` — no migration needed.
- **Never bypass `clubs.cancellation_policy_type`** — `'club_managed'` clubs MUST never receive credit from EITHER path (cutoff or deferred), regardless of cutoff timing or replacement. Both `cancel_booking_with_credit` and `credit_on_replacement_confirmed` have an early `club_managed` branch that returns/skips before any `player_credits` write. Do not collapse those into the managed branch.
- **Never set `bookings.was_replaced` from a client** — only the server-side promotion paths and the deferred-credit trigger write the flag. Specifically: `promote_top_waitlisted` (FREE path only — sets inline since the replacement is confirmed atomically), `credit_on_replacement_confirmed` (paid path — sets when the replacement actually confirms+pays), and historically `promote_waitlist_player` admin RPC. **Never set `was_replaced=TRUE` on a `pending_payment` promotion** — the replacement is held, not yet confirmed; setting the flag would falsely trigger immediate credit and re-introduce the bug fixed in `20260505040000`. **Never set `was_replaced=TRUE` on a forfeit booking** — forfeits are not replacements.
- **Never set `bookings.replacement_booking_id` from a client** — set only by `promote_top_waitlisted` (on the cancelled booking, pointing to the new waitlister) and re-pointed by `revert_expired_holds_and_repromote` when a held replacement forfeits. Cleared to NULL by the cron when no next candidate exists. RLS isn't relevant here (these are SECURITY DEFINER triggers/cron) but no client write surface exists for these columns and none should be added.
- **Never let the deferred trigger fire credit for a paid game without `fee_paid=TRUE`** — `credit_on_replacement_confirmed` checks `IF v_is_paid AND NOT NEW.fee_paid THEN RETURN NEW;` early. Without this, an admin manually flipping a paid booking to `confirmed` (with fee_paid still FALSE) would incorrectly credit the original cancelling user. Keep the gate.
- **`replacement_credit_issued_at IS NULL` is the SINGLE idempotency guard** — both paths must set it on credit issuance, both paths must check it before issuing. Never weaken or remove the partial index `idx_bookings_pending_replacement` — it's how the deferred trigger finds candidates without scanning the full bookings table.
- **The cutoff path (`cancel_booking_with_credit`) is still atomic** — cancel + (conditional) credit happen in one transaction. The deferred path is a SEPARATE atomic event that fires when a paid replacement actually confirms. **Never split the cutoff path itself into two calls** — splitting creates a window where the booking is cancelled but the cutoff credit is never issued. The deferred path is by design; the cutoff path is not.
- **Never remove the unique constraint** `player_credits_user_club_currency_key` — prevents duplicate rows on concurrent inserts. Both paths rely on `INSERT ... ON CONFLICT DO UPDATE` for atomic upsert.
- **Never use a global (non-club-scoped) credit balance** — `creditBalanceCents: Int` was the old global design; it has been replaced by `creditBalanceByClubID: [UUID: Int]` throughout.
- **Never pass `creditsAppliedCents` as `0` to `requestBooking`** — the guard is `credits > 0`; pass `nil` when no credits are applied so the deduction path is skipped entirely.
- **Never call `confirmPendingBooking` without `clubID`** — both call sites in `GameDetailView.preparePaymentSheet` must include `clubID: game.clubID`.
- **Never break the `promote_top_waitlisted` ordering for the FREE path** — the cancelled-booking marks (`was_replaced`, `replacement_booking_id`, `replacement_confirmed_at`) MUST be set AFTER the waitlister UPDATE, not before. With the marks set after, the deferred-credit trigger fires on the waitlister's confirmed-transition while the cancelled booking still has `replacement_booking_id=NULL` and finds nothing — leaving credit issuance to the wrapping `cancel_booking_with_credit` (which re-reads `was_replaced=TRUE` and credits inline). Reversing the order would cause double-credit on free games.
- **Never break the `revert_expired_holds_and_repromote` ordering** — the cancelled-booking re-point of `replacement_booking_id` MUST happen BEFORE the waitlister UPDATE in the cron's free-game edge branch. The deferred-credit trigger needs the new pointer set when it fires on the waitlister's confirmed-transition.

## Payment Tracking (implemented 2026-03-27)

- `bookings.payment_method TEXT NULL` column — canonical values enforced by DB CHECK constraint (`20260430010000_bookings_payment_method_constraint.sql`):
  - `"stripe"` — paid via card/Apple Pay (`confirmPendingBooking`, `updateBookingPaymentMethod`)
  - `"admin"` — owner/admin manually added player (`ownerCreateBooking`, `updateBookingPaymentMethod`)
  - `"cash"` — admin-recorded cash payment at check-in (`updateBookingPaymentMethod`)
  - `"credits"` — credits-only booking confirmation (`confirmPendingBooking` when no Stripe PI)
  - `NULL` — free game, no payment collected
  - **Never write any other value** — the DB constraint will reject it. The legacy value `"free"` was normalised to `NULL` in the same migration.
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

## Avatar Palettes (implemented 2026-04-26)

- `avatar_palettes` table — canonical gradient definitions. Clients resolve gradients by `palette_key` only; no local colour computation.
- 18 palettes across 3 categories: `premium_dark`, `neon_accent`, `soft_luxury`.
- Default fallback: `midnight_navy` (`is_default = TRUE`) — used when no `palette_key` is stored.
- `profiles.avatar_color_key TEXT NULL` column — replaces legacy hex-based assignment. Migration: `20260426080000_profiles_avatar_color_key.sql`.
- RLS: authenticated users can SELECT active palettes; writes are service-role only.
- **Do not** fall back to local hash-based colour assignment. Always read `palette_key` from the DB row; use `midnight_navy` only when the key is absent or not found in the cached palette list.

## Game Reminders & App Config (implemented 2026-04-27)

- `app_config` table — server-authoritative key/value store for cross-platform runtime constants. Migration: `20260427010000_app_config.sql`.
- `game_reminder_offset_minutes = 120` — canonical T-2h reminder offset. Changing this row takes effect on the next cron tick and next iOS app launch.
- `game-reminder-2h` Edge Function — runs hourly via pg_cron, finds games in a ±15 min window around the offset, notifies confirmed players via APNs + in-app notification. Type: `game_reminder_2h`.
- `game_reminder_24h` enum value is **kept** for backward compatibility but no new payloads use it. Do not remove it.
- `notification_type` enum additions (migration `20260427060000_notification_type_game_reminder_2h.sql`): `game_reminder_2h`, `club_new_post`, `club_new_comment`.
- iOS: `AppState.gameReminderOffsetMinutes` loaded at bootstrap via `fetchAppConfig()`. If nil (load failed), the reminder toggle shows a "config hasn't loaded" message — do not hardcode a numeric fallback.
- pg_cron setup: unschedule `game-reminder-24h`; schedule `game-reminder-2h` at `'0 * * * *'`.

## Analytics Architecture

- `get_club_analytics_kpis(p_club_id, p_days, p_start_date, p_end_date)` — primary KPI RPC. Returns revenue, bookings, fill rate, active players, and revenue breakdown. Latest migration: `20260429010000_analytics_fix_refunded_label.sql`.
- **No Stripe cash refund flow exists.** When a player cancels an eligible booking, they receive **club credits** — no Stripe reversal is made. The analytics `curr_credits_returned_cents` column captures the gross of Stripe-paid bookings that triggered a credit return. **Never rename or relabel this as "Refunded" or "Cash Refunded"** — it is credit exposure, not a cash refund.
  - `curr_credits_returned_cents` — sum of `platform_fee + club_payout` for `status='cancelled' AND fee_paid=true AND payment_method='stripe'` bookings
  - `curr_credit_return_count` — count of cancellations that triggered a credit return
  - iOS model: `ClubAnalyticsKPIs.currCreditsReturnedCents` / `currCreditReturnCount`
  - UI label: **"Credits Returned"** (not "Refunded")
  - If a true Stripe cash refund flow is added in the future, it must use a separate DB column (e.g. `stripe_refund_amount_cents` from a Stripe webhook table) and a new `curr_cash_refunded_cents` KPI column — never reuse `curr_credits_returned_cents` for that purpose.
- Revenue taxonomy in `get_club_analytics_kpis`:
  - `curr_revenue_cents` — club net: Stripe club_payout + cash (primary KPI)
  - `curr_gross_revenue_cents` — player-facing: Stripe platform_fee+payout + cash
  - `curr_platform_fee_cents` — Stripe-only platform cut (no fee on cash)
  - `curr_credits_used_cents` — credits_applied across all confirmed bookings
  - `curr_credits_returned_cents` — club credits issued on eligible cancellations
  - `curr_manual_revenue_cents` — cash-only revenue (separable from Stripe)

## Roadmap / To-Do

- **Android version** — plan native Android app (Kotlin/Jetpack Compose) or cross-platform (Flutter/React Native) once iOS is stable
- **Reviews admin dashboard** — club owner/admin view of all reviews; ability to respond to reviews; flag/hide inappropriate reviews; consider App Store review prompt tied to 4–5 star submissions
- **Club name tappable on game booking card** — tapping the club name in a game card (discovery/bookings list) should navigate to that club's detail page *(partially implemented — `UnifiedGameCard.onClubTap` closure exists)*
- **Pickleball news feed on Home tab** — RSS or curated API feed of pickleball news/content for engagement; posts shareable directly to any club chat the user is a member of *(implemented — The Dink RSS feed, up to 5 articles, in-app Safari viewer)*
- **Custom club profile picture & banner upload** — allow club owners/admins to upload their own club avatar and banner image instead of selecting from presets; display recommended dimensions in the banner selection UI so uploaded images conform correctly (e.g. banner: 1500×500px, avatar: 400×400px)
- **Subscription & payment tiers** — define free vs paid club tiers (e.g. max games, max members, analytics access); Stripe subscription products; in-app paywall for premium features; grace period + downgrade handling; admin billing portal
- **User notification preferences** — per-type opt-in/out for email and push (booking confirmations, club news, waitlist promotions, review prompts, etc.); `notification_preferences` table per user
- **APNs per-club mute suppression** — suppress push for clubs the user has muted at server side, not just client side
- **Stripe test → live mode** — swap `pk_test_`/`sk_test_` for `pk_live_`/`sk_live_`; verify Apple Pay domain with Stripe Dashboard

## Apple App Store Compliance

BookaDink qualifies for the **B2B enterprise exception** under App Store Review Guideline **3.1.3(c)**.

Club subscriptions (Starter, Pro) are purchased by **club owners on behalf of their club/organisation**, not by individual consumers. Apple's guideline explicitly permits external payment (Stripe) for organisational/enterprise accounts.

**StoreKit IAP is NOT required** for club plan subscriptions.

### Before App Store submission — add to App Store Connect Review Notes:
> "This app is a B2B club management platform for sports club owners and administrators. Subscription plans (Starter, Pro) are purchased by club owners on behalf of their organisations, not by individual consumers, per Guideline 3.1.3(c) (Enterprise Services). Subscription management is handled via an external billing portal (Stripe). Individual players/members do not purchase subscriptions — they pay game session fees handled via Stripe Connect for club payouts."

### Stripe account separation — must remain:
- `create-club-subscription` / `stripe-webhook` / `cancel-club-subscription` → **Stripe platform account** — club owner plan billing
- `create-payment-intent` / Stripe Connect → **Connected accounts** — game booking player payments and club payouts
- Never merge these two flows. They use different Stripe account types by design.

### If Apple requests IAP:
Cite Guideline 3.1.3(c) and provide evidence that subscriptions are purchased by the club entity (org), not consumers. If Apple still rejects, implement StoreKit 2 with server-side receipt verification and Supabase as the entitlement source of truth — do not change the entitlement pipeline, only add an Apple transaction verification Edge Function.
