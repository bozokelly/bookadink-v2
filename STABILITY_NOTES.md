# BookingAppV2 Stability Notes

## Incident Summary
- Symptom: app appeared to freeze when tapping club cards (especially `Sunset Pickleball Club`).
- Key observation: Xcode showed `Thread 1: breakpoint 1.1` in `ClubDetailView` during the club actions path.
- Result: this was a debugger pause path plus UI pressure, not a single deterministic crash.

## Root Cause (Practical)
- Club detail had risky open-time behavior:
  - navigation-time work + complex UI modifiers in the same flow.
  - `confirmationDialog` path around club actions that repeatedly hit runtime-debug breakpoints.
- Data/render safety was not strict enough for malformed or oversized remote fields.
- Legacy style/image paths increased branching complexity.

## Fixes Applied
- Removed high-risk club action dialog path and switched to a simple `Menu` action path.
- Removed aggressive scroll layout constraints that were adding navigation/render pressure.
- Removed automatic network fetches on initial club open; now loads on tab change only.
- Added decode-time sanitization for club fields from Supabase:
  - text length caps
  - URL scheme validation
- Added render-time text caps to prevent pathological layout work.
- Removed legacy club-style code paths/schemes.
- Added telemetry breadcrumbs for club open/tab-change and key refresh/save flows.
- Added smoke checks and regression checklist.

## Do Not Reintroduce
- Do not add `confirmationDialog("Club Actions", ...)` back into `ClubDetailView`.
- Do not reintroduce `containerRelativeFrame`/forced clipping patterns in club navigation containers unless profiled.
- Do not auto-run multiple network tasks on `ClubDetailView` open.
- Do not accept unbounded club text fields from backend into UI models.
- Do not re-enable legacy `bookadink-preset` URL handling.

---

## Changes — March 9–10, 2026

### Auth / Loading Screen

- **Removed `fullScreenCover` from `AuthWelcomeView`** — was firing `isPresented: .constant(appState.isAuthenticating)` during token refreshes while the user was already in `MainTabView`, causing the loading screen to overlay the main app mid-session.
- **Added `LoadingScreenView`** — replaces the old `ProgressView` spinner used during bootstrap. Shown only in `RootView` when `isBootstrapping` is true (signed in, bootstrap incomplete, no profile yet). Uses navy `LinearGradient` background, breathing logo animation, "Pickling..." text with staggered dot indicators.
- **`RootView` bootstrap guard** — `isBootstrapping` computed var: `authState != .signedOut && !isInitialBootstrapComplete && profile == nil`. Three `.animation(.easeInOut(duration: 0.55))` fade transitions guard each state change.

### App Logo Asset

- Iteratively resolved black/white border artifact around loading screen logo:
  - `.blendMode(.screen)` eliminates solid-colour backgrounds via multiply math.
  - `.mask(RadialGradient)` creates true alpha transparency at image edges for near-black pixels that screen blend cannot fully remove.
  - Final resolution: replaced PNG with a transparent-background SVG (`Bookadink logo vector.svg`) — no blend mode or masking required.
- Asset catalog `app_logo.imageset` updated to use `preserves-vector-representation: true`.

### ClubDetailView — Header Redesign

- Replaced `heroCard` + separate `clubActionRow` with a single glass card: avatar (64pt), normalised address, member count, state-driven button row.
- **Default tab changed** from `.info` → `.games`.
- Added `refreshMemberships()` call in `.onAppear` — fixes member seeing "Pending" status after admin approval on refresh.
- Admin badge moved inline with member count: `· 🛡 Admin` in teal.
- `isMemberOrAdmin` helper handles `.approved`, `.unknown` (club owner), and `isClubAdminUser`.
- Dead code removed: `heroLeadingArtwork`, `heroHeaderText`, `heroLocationLine`, `heroHeaderTagsSection`, `compactHeroPill`, `heroHeaderTags`, `joinButton`, `shareButton`, `shareButtonCompact`, `clubActionRow`, all legacy status colour helpers.

### Button Hit Area Fix

- **Root cause:** `.background` applied *after* `.buttonStyle(.plain)` is visual-only — hit area is only the label content.
- **Fix:** moved `.background` + `.actionBorder` *inside* the label closure on:
  - `ProfileDashboardView` — "Edit Profile" pill
  - `GameDetailView` — "Remove From Calendar" pill

### Invite Button Glow Fix

- `ShareLink` applies system button highlight by default.
- Fix: `.buttonStyle(.plain)` added to `ShareLink` wrapper in `ClubDetailView`.

### GamesPlayedCard

- Removed "Win Rate —" stat pill (no data to back it). Two stat pills remain: Total and This Month.

### Supabase RLS — Profiles UPDATE Policy

- `TO public` → `TO authenticated` + `WITH CHECK ((auth.uid() = id))` required on the `Users can update own profile` policy. Without `WITH CHECK`, PostgREST upserts silently fail. User advised; may not yet be applied to remote project.

### String+NormalizedAddress Extension

- New `String.normalizedAddress()` — trim/collapse whitespace, title-case all-lowercase strings, truncate at 40 chars with ellipsis. Used in `ClubDetailView` header.

---

## Required Validation Before Merge
- Run:

```bash
./scripts/smoke_check.sh
```

- Manual checks:
  1. Tap into/out of `Sunset Pickleball Club` 3 times.
  2. Force close app, relaunch, open multiple clubs.
  3. Switch `Info`, `Games`, `Members`, `Club Chat` tabs.
  4. Open `Club Settings`, save a valid update, verify success feedback and dismiss.

## Debugging Guidance If It Returns
- First confirm app is actually frozen vs paused by debugger:
  - Check for `Thread 1: breakpoint ...` in Xcode.
  - Disable runtime/exception breakpoints and retest.
- Inspect telemetry logs for:
  - `open_club_detail`
  - `club_detail_tab_change`
  - `refresh_*_start/success/error`
- If freeze persists without debugger pause, temporarily swap club detail to minimal shell and re-enable sections incrementally.
