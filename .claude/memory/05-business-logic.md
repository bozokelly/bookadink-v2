# Business Logic — Book A Dink

## Club Membership States (`ClubMembershipState`)
```
.none        → "Join Club" button enabled
.pending     → "Request Sent" — no action
.approved    → "Joined" — no action (member access granted)
.rejected    → "Request Again" — button enabled
.unknown(String) → "Member" — club owner / admin edge case
```
`isMemberOrAdmin` in `ClubDetailView` must handle `.approved`, `.unknown` (club owner), and `isClubAdminUser`.

## Admin vs Owner Distinction
```swift
// AppState
func isClubAdmin(for club: Club) -> Bool  // owner OR admin role
func isClubOwner(for club: Club) -> Bool  // owner only
```
- Owner (`created_by` = authUserID OR `club_admins.role == "owner"`): can promote/demote admins, remove any member
- Admin (`club_admins.role == "admin"`): can manage regular (non-admin) members only
- In `ClubDetailView` the computed var `isClubAdminUser` is used for UI gating

## Skill Levels
```
DB values: "all" | "beginner" | "intermediate" | "advanced"
SkillLevel enum: .beginner | .intermediate | .advanced | .tournament
```
Note: DB uses lowercase (e.g. `"all"`, `"beginner"`). The Swift enum `SkillLevel` uses capitalised raw values ("Beginner" etc.) for `ClubOwnerGameDraft.skillLevelRaw` which writes lowercase to DB.
CLAUDE.md constraint: `skill_level` enum values in DB are `all`, `beginner`, `intermediate`, `advanced` — no `tournament`.

## Game Status Flow
```
created → "upcoming"
cancelled → "cancelled"  (via cancelGame() — sends gameCancelled notifications to all attendees)
completed → "completed"  (set after end time passes, or manually)
archived → archived_at TIMESTAMPTZ set (soft-delete; filtered out in all fetch queries)
```

## Payment Methods (`bookings.payment_method`)
```
"stripe"  → paid via card/Apple Pay through Stripe
"admin"   → added by club owner, no charge ("Comp" badge, grey)
nil       → self-booked free game, or legacy row
```
Badge display rules (admin/owner only in attendee list):
- "Card" (blue) = payment_method "stripe"
- "Comp" (grey) = payment_method "admin"
- "Unpaid" (orange) = nil or fee not paid

## Game Scheduling / `publish_at`
```
nil         → publish immediately (visible to all)
future Date → scheduled/hidden from members, visible to admins at 55% opacity
              with orange "Not visible to the public · Goes live in Xd Yh Zm" banner
```
`Game.isScheduled: Bool` = `publishAt != nil && publishAt > Date()`
Admin-only: scheduled games shown dimmed with countdown `Timer.publish(every: 60)`.
`fetchUpcomingGames()` filter: `(publish_at.is.null,publish_at.lte.<now>)` — excludes scheduled from public feed.
`mergeIntoAllUpcomingGames()` also filters client-side.

## Recurring Games
- `recurrenceGroupID: UUID` links all instances
- `RecurringGameScope`: `.singleEvent` | `.thisAndFuture` | `.entireSeries`
- `publishAt` per-instance: offset = `template.startDate.timeIntervalSince(template.publishAt)`, applied to each instance
- Validation: `publishAt` must be in the future at creation/update time

## Booking State (`BookingState`)
```
.none           canBook: true   canCancel: false
.confirmed      canBook: false  canCancel: true
.waitlisted(position) canBook: false  canCancel: true
.cancelled      canBook: true   canCancel: false
.unknown(String) canBook: false  canCancel: false
```

## DUPR Ratings
- Two storage paths: `profiles.dupr_rating` (Supabase) + UserDefaults `bookadink.profile.duprRatingsByUserID` as `[userIDString: {d: Double, s: Double}]`
- `loadProfileFromBackendIfAvailable()` syncs Supabase → UserDefaults after every profile fetch
- Admin can update member DUPR via `adminUpdateMemberDUPR(memberUserID:rating:)`
- DUPR ID format: validated by `isLikelyDUPRID()`, normalized by `normalizeDUPRID()`
- Range validation: 1.0 – 8.0

## Club Chat / Club News
- Posts (`ClubNewsPost`) support: text content, images (`[URL]`), announcements, like count, comments
- `isAnnouncement: Bool` triggers special display (announcement badge)
- Moderation reports stored in `club_messages` table; resolved via DELETE
- Per-club muted: `AppState.mutedClubChatIDs: Set<UUID>`

## Notifications (`AppNotification.NotificationType`)
Types and their deep links:
```
bookingConfirmed / bookingWaitlisted / waitlistPromoted / bookingCancelled
gameCancelled / gameUpdated → .game(id: referenceID)
gameReviewRequest → .review(gameID: referenceID)
membershipApproved / membershipRejected / membershipRemoved /
membershipRequestReceived / adminPromoted /
clubNewPost / clubAnnouncement / clubNewComment → .club(id: referenceID)
```
`NotificationsView` uses its own `NavigationStack`. Club notifications push inline; game notifications open as `.sheet`.

## Club Tools Menu Order (standardised)
1. View / Edit Games
2. Create Game
3. Divider
4. Club Settings
5. Divider
6. Join Requests
7. Manage Members

## Text Sanitisation (ClubRow.sanitizedText)
- Length caps at decode time: name 120, description 2000, email 320, website 260, managerName 160, suburb/state 80, venueName 260
- URL validation: only `http`, `https`, `bookadink-avatar` schemes allowed
- Addresses canonicalized via `String.normalizedAddress()`: trim, collapse whitespace, title-case, truncate at 40 chars
