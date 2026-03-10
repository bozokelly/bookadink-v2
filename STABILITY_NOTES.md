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
