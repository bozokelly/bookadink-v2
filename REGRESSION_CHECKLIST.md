# BookingAppV2 Regression Checklist

## Club Detail Freeze Guard
- Launch app with a signed-in user.
- Open `Clubs`.
- Tap `Sunset Pickleball Club`.
- Expected: detail screen opens within 2 seconds and remains responsive.
- Switch tabs `Info`, `Games`, `Members`, `Club Chat`.
- Expected: no hang, no repeated stutter, no app freeze.

## Club Profile Picture Flow
- Open `Club Settings` as an owner/admin.
- Expected: section is `Club Profile Picture` and `Club Style` is not present.
- Select each of the 9 profile picture options.
- Save and reopen the same club.
- Expected: selected image appears in both club card and club detail hero.

## Persistence
- Force close app and relaunch.
- Reopen the same club.
- Expected: selected club profile picture persists.

## Start A Club Flow
- Open `Clubs` and tap the `+` button in the top-right.
- Fill `Club Name` and optionally select one of the 9 profile pictures.
- Tap `Create`.
- Expected: sheet closes after success, club detail opens automatically, and no freeze/stall occurs.
- Switch `My Clubs` filter on the Clubs tab.
- Expected: newly created club appears and opens without freezing.

## DUPR Booking Flow
- Open any game with `Requires DUPR` enabled.
- Tap `Join Game`.
- Expected: a `Confirm DUPR` sheet appears before booking starts.
- Enter a valid DUPR ID and toggle confirmation.
- Tap `Confirm`.
- Expected: booking proceeds.
- Reopen the same DUPR game and tap `Join Game` again on a new account/game state.
- Expected: stored DUPR ID is prefilled but confirmation is still required before booking.

## Data Safety
- Verify clubs with malformed/long fields still render.
- Expected: no freeze; text is capped and UI remains responsive.

## Legacy Path Removal
- Run:

```bash
rg -n "bookadink-preset|Club Style|ClubArtworkPreset|isLegacyClubStyleURL" BookadinkV2/BookadinkV2
```

- Expected: no matches.

---

## Loading Screen (added March 10)

- Cold-launch the app while signed out.
- Sign in with valid credentials.
- Expected: `LoadingScreenView` appears during bootstrap (navy gradient, logo, "Pickling..." text with animated dots), then fades into `MainTabView` once profile loads.
- Expected: no loading screen appears again mid-session after token refresh.
- Force-quit and relaunch while signed in.
- Expected: loading screen shows briefly during bootstrap then transitions directly to `MainTabView` — not to `AuthWelcomeView`.

## Auth Flow — No Overlay on Refresh (added March 10)

- Open app, sign in, navigate to any tab.
- Leave app in background for several minutes to trigger a token refresh.
- Return to foreground.
- Expected: no loading screen or spinner overlays `MainTabView` during or after the refresh.

## Club Detail — Default Tab & Membership Sync (added March 10)

- Open any club as a non-admin user.
- Expected: club detail opens on the **Games** tab by default (not Info).
- As an admin: approve a pending member on the admin device.
- On the member's device: close and reopen the club detail.
- Expected: status updates from "Pending" to "Member" without requiring a full app restart.

## Button Hit Areas (added March 10)

- On the **Profile** tab, tap the "Edit Profile" pill anywhere inside the pill bounds (not just on the text).
- Expected: edit sheet opens regardless of where inside the pill was tapped.
- Open any game detail with a calendar event synced.
- Tap "Remove From Calendar" anywhere inside the pill.
- Expected: removal triggers; does not require tapping exactly on the label text.

## Invite Button — No Glow (added March 10)

- Open a club where you are a member or admin.
- Expected: "Invite" button has the same visual style as the "Member" button — white fill, no system highlight glow around it.

## GamesPlayedCard — No Win Rate (added March 10)

- Open the **Profile** tab and scroll to the Games Played card.
- Expected: only two stat pills visible — **Total** and **This Month**. No "Win Rate" pill.

---

## One-Command Smoke Check
- Run:

```bash
./scripts/smoke_check.sh
```

- Expected: all checks pass (or build check is skipped if Xcode is unavailable).
