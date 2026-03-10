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
- DUPR ratings stored in `UserDefaults` keyed by `StorageKeys.duprRatingsByUserID` as `[userIDString: {d: Double, s: Double}]`

## Pending (Blocked on Apple Dev Account)

- APNs push notifications — Edge Function written at `supabase/functions/booking-confirmed/index.ts`. Needs APNs `.p8` key, Key ID, Team ID, Bundle ID set as Supabase secrets before deploying.
