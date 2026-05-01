# Core App Flows — Book A Dink

## Bootstrap Sequence
1. `AppState.init()` → `restorePersistedSession()` → restore DUPR/UserDefaults
2. Task: if `.signedIn` → `refreshSessionIfPossible(silent: true)`
3. `refreshClubs()` (always — even signed-out)
4. If `.signedIn`: `loadProfileFromBackendIfAvailable()`, `refreshBookings(silent:)`, `refreshUpcomingGames()`
5. `isInitialBootstrapComplete = true`

`RootView` auth bootstrap guard: `authState != .signedOut && !isInitialBootstrapComplete && profile == nil`

## Auth Flow
- Sign in: `AppState.signIn(email:password:)` → `dataProvider.signIn()` → `applyAuthFlowResult()` → `postAuthenticationBootstrap()`
- Post-auth bootstrap: loads profile, memberships, admin roles, bookings, upcoming games, registers push token
- Sign up may return `.requiresEmailConfirmation` — app shows confirmation message without entering `.signedIn`
- Token refresh: `withAuthRetry { }` wrapper — retries once on auth failure by calling `refreshSessionIfPossible()`

## Game Creation (Club Owner)
1. Owner fills `ClubOwnerGameDraft` in `GameScheduleSheet`
2. `AppState.createGameForClub(club:draft:)` → `dataProvider.createGame(for:createdBy:draft:recurrenceGroupID:)`
3. If `draft.repeatWeekly && draft.repeatCount > 1` → generates a `recurrenceGroupID = UUID()` and creates `repeatCount` instances with staggered `startDate` (+7d each). `publishAt` offset applied per instance: `instanceDraft.publishAt = instanceDraft.startDate.addingTimeInterval(-offset)`.
4. Validation: if `publishAt != nil && publishAt <= Date()` → returns early with error "Publish time must be in the future".
5. On success: `gamesByClubID[clubID]` updated, `allUpcomingGames` merged.

## Booking Flow
1. User taps "Join Game" in `GameDetailView`
2. If game has fee → Stripe payment sheet shown first
3. On Stripe `.completed`: `requestBooking(for:stripePaymentIntentID:)` → writes `fee_paid=true`, `payment_method="stripe"`, `stripe_payment_intent_id`
4. Free game: `requestBooking(for:)` → `dataProvider.createBooking(gameID:userID:status:"confirmed":...)` or `status:"waitlisted"` if full
5. `bookings` array updated; `attendeesByGameID[gameID]` refreshed
6. Push notification triggered via `triggerBookingConfirmedPush()`

## Admin Booking (Owner-Adds Player)
- `ownerCreateBooking()` → always inserts `payment_method="admin"` via `BookingAdminInsertBody`
- Displays as "Comp" badge (grey) in attendee list

## Payment via Stripe
- `StripeAPI.defaultPublishableKey` set from `SupabaseConfig.stripePublishableKey` at app init
- `GameDetailView` calls `createPaymentIntent(amountCents:currency:metadata:)` → Edge Function `create-payment-intent`
- Edge Function called with `anon key` (not user JWT) for auth headers
- `PaymentSheet` presented; on `.completed` → booking created with Stripe metadata
- Apple Pay: `merchantId: "merchant.com.bookadink"`, `merchantCountryCode: "AU"` — test mode currently
- Payment intent ID extracted: `clientSecret.components(separatedBy: "_secret_").first`

## Post-Game Review Flow
- `gameReviewRequest` notification sent 24h after game (via Edge Function / scheduled job)
- Deep link: `.review(gameID:)` → opens review sheet in `GameDetailView`
- `submitReview(gameID:userID:rating:comment:)` → inserts into `game_reviews`
- Reviews fetched per-club via `fetchClubReviews(clubID:)` → stored in `AppState.reviewsByClubID`

## Notification Flow
1. DB insert to `notifications` table
2. DB trigger `send_notification_email` fires → calls `send-notification-email` Edge Function via `net.http_post` (uses anon key)
3. iOS: `fetchNotifications(userID:)` polls on app foreground; `markNotificationRead(id:)` on tap
4. APNs push: `notify` Edge Function inserts notification row AND sends APNs push
5. Push token stored in `profiles.push_token`; cleared to nil on sign-out

## Club Chat Realtime
- Per-club `SupabaseClubChatRealtimeClient` instances stored in `AppState.clubChatRealtimeClients`
- `commentDraft` must be `@State private` inside `ClubNewsPostCard` — lifting it causes full re-render on every keystroke
- Like/comment use optimistic UI — mutate local cache immediately, revert on failure
- Do NOT call `refreshClubNews` after every interaction

## Upcoming Games (Home / Nearby)
- `fetchUpcomingGames()` fetches 14-day window, filters `archived_at.is.null`, OR: `(publish_at.is.null,publish_at.lte.<now>)`
- `mergeIntoAllUpcomingGames()` client-side filters: status=="upcoming", within 14d window, publishAt nil or past
- Stored in `AppState.allUpcomingGames`
