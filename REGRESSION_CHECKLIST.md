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

## One-Command Smoke Check
- Run:

```bash
./scripts/smoke_check.sh
```

- Expected: all checks pass (or build check is skipped if Xcode is unavailable).
