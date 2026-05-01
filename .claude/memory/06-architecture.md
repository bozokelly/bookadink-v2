# Architecture — Book A Dink

## AppState — Single Source of Truth
`@MainActor final class AppState: ObservableObject` injected as `@EnvironmentObject`.

All UI state, auth state, and cache lives here. Key published collections:
```swift
@Published var clubs: [Club]
@Published var gamesByClubID: [UUID: [Game]]
@Published var allUpcomingGames: [Game]          // 14-day window, powers Home/Nearby
@Published var bookings: [BookingWithGame]
@Published var attendeesByGameID: [UUID: [GameAttendee]]
@Published var membershipStatesByClubID: [UUID: ClubMembershipState]
@Published var clubAdminRoleByClubID: [UUID: String]
@Published var clubNewsPostsByClubID: [UUID: [ClubNewsPost]]
@Published var notifications: [AppNotification]
@Published var reviewsByClubID: [UUID: [GameReview]]
@Published var clubVenuesByClubID: [UUID: [ClubVenue]]
@Published var checkedInBookingIDs: Set<UUID>
@Published var attendancePaymentByBookingID: [UUID: String]
```

Loading state uses `Set<UUID>` keyed by entity ID (not boolean flags) to support concurrent operations:
```swift
loadingClubGameIDs, requestingBookingGameIDs, cancellingBookingIDs,
ownerSavingGameIDs, loadingAttendeeGameIDs, etc.
```

`scheduleStore: GameScheduleStore` — separate `@EnvironmentObject` for reminder/calendar state to limit re-render scope.

## ClubDataProviding Protocol
`SupabaseService` implements `ClubDataProviding`. The protocol is the abstraction boundary:
- All DB reads/writes go through `dataProvider: ClubDataProviding`
- Enables mock injection for tests/previews
- `SupabaseService` is a plain `final class` (not `actor`) — all network calls are `async throws`

## SupabaseService.send() Pattern
```swift
private func send<T: Decodable>(
    path: String,
    queryItems: [URLQueryItem],
    method: String,
    body: Data?,
    authBearerToken: String?,
    extraHeaders: [String: String] = [:]
) async throws -> T
```
- Builds PostgREST URL from `SupabaseConfig.urlString + "/rest/v1/" + path`
- Sets headers: `apikey: anonKey`, `Authorization: Bearer <token>`, `Accept: application/json`
- HTTP 4xx/5xx throws `SupabaseServiceError.httpStatus(code, body)`
- JSON decoded via `JSONDecoder()` (no special date strategy — dates handled manually via `SupabaseDateParser`)

## Auth Token Flow
- `storedAccessToken` on `SupabaseService` set via `setAccessToken(_:)`
- `AppState` calls `dataProvider.setAccessToken(authAccessToken)` after every auth event
- `resolvedAccessToken()` private func returns stored token
- `withAuthRetry { }` in `AppState` retries once on auth failure by silently refreshing token

## Date Parsing Strategy
All date columns stored as raw strings (`*Raw: String?`), converted lazily:
```swift
// Read (Decodable rows):
createdAt: createdAtRaw.flatMap(SupabaseDateParser.parse)  // tries fractional then standard ISO8601

// Write (Encodable bodies):
dateTime: SupabaseDateWriter.string(from: draft.startDate)  // ISO8601 with fractional seconds
```

## Deep Links (`DeepLink` enum + `DeepLinkRouter`)
```swift
enum DeepLink {
    case game(id: UUID)
    case club(id: UUID)
    case review(gameID: UUID)
}
```
- `AppState.pendingDeepLink: DeepLink?` — set by `DeepLinkRouter` on URL open
- URL scheme: `bookadink://` (NOT `bookadink-preset://`)
- `NotificationsView` uses `navigationDestination(item:)` for club nav (inline back); game notifications open as `.sheet`

## ClubDetailView Constraints (production freeze — never reintroduce)
- NO `confirmationDialog("Club Actions", ...)`
- NO `containerRelativeFrame` / forced clipping in club navigation containers
- NO automatic network tasks on view open — load on tab change only
- `isMemberOrAdmin` must handle `.approved`, `.unknown` (club owner), and `isClubAdminUser`

## RootView Auth Guard
```swift
// Shows loading/bootstrap spinner:
authState != .signedOut && !isInitialBootstrapComplete && profile == nil
```

## Supabase Edge Functions
Called from iOS using `anon key` (not user JWT) for `apikey` and `Authorization: Bearer` headers.
User JWT is ONLY valid for PostgREST/DB calls, not Edge Functions.

Functions:
- `notify` — inserts notification row + optional APNs push
- `booking-confirmed` — sends booking confirmation push
- `send-notification-email` — triggered by DB trigger, sends email via Resend
- `create-payment-intent` — creates Stripe PaymentIntent, returns `client_secret`
- `archive-old-games` — scheduled cleanup

If Edge Functions return "Unregistered API key": redeploy with `supabase functions deploy <name> --no-verify-jwt --project-ref <ref>` to refresh auto-injected `SUPABASE_SERVICE_ROLE_KEY`.

## Required DB Migrations (pending as of 2026-03-28)
```sql
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_method TEXT NULL;
ALTER TABLE games ADD COLUMN IF NOT EXISTS publish_at TIMESTAMPTZ NULL;
CREATE POLICY "Users can delete own notifications" ON notifications
  FOR DELETE USING (auth.uid() = user_id);
```

## Adding a New DB Column — Checklist
1. Add migration SQL to Supabase
2. Add Swift property to domain model in `Models.swift`
3. Add to `*Row: Decodable` struct + `CodingKeys`
4. Add to `*InsertRow`/`*UpdateRow` Encodable structs + `CodingKeys`
5. Add column name to ALL relevant `select=` query strings in `SupabaseService.swift`
   - clubs: 5 queries (`fetchClubs`, `fetchClubDetail`, `createClub`, `updateClubOwnerFields`, delete helper)
   - games: 8+ queries
   - bookings: all booking queries must include `payment_method`
6. Add new `.swift` files to Xcode target membership (manual step in Xcode)

## Stripe Configuration
```swift
StripeAPI.defaultPublishableKey = SupabaseConfig.stripePublishableKey  // set in BookADinkApp.init()
```
Currently test mode (`pk_test_` / `sk_test_`). Apple Pay: `merchantId: "merchant.com.bookadink"`, `merchantCountryCode: "AU"`.

## Smoke Check
Run `./scripts/smoke_check.sh` before committing changes to `ClubDetailView` or `AppState`.
Manual smoke test: tap into/out of a club 3×, force close + relaunch, switch all tabs, open Club Settings + save.
