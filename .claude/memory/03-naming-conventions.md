# Naming Conventions — Book A Dink

## Swift Naming
- Types: `UpperCamelCase` — `ClubDetailView`, `GameAttendee`, `BookingRecord`
- Properties/functions: `lowerCamelCase` — `clubID`, `gamesByClubID`, `refreshClubs()`
- Enums: `UpperCamelCase` with `lowerCamelCase` cases — `BookingState.confirmed`, `AuthState.signedIn`
- Private row structs suffixed `Row` — `ClubRow`, `GameRow`, `BookingRow`, `ProfileRow`
- Private insert/update structs suffixed `InsertBody`/`UpdateRow` — `BookingInsertBody`, `GameInsertRow`, `GameOwnerUpdateRow`
- Draft view-models suffixed `Draft` — `ClubOwnerGameDraft`, `ClubOwnerEditDraft`, `ClubVenueDraft`

## Supabase Column ↔ Swift CodingKeys Pattern
All `Decodable` row structs use explicit `enum CodingKeys: String, CodingKey` mapping snake_case DB columns to camelCase Swift properties.

Common mappings:
```
club_id         → clubID
user_id         → userID
game_id         → gameID
booking_id      → bookingID
full_name       → fullName
date_time       → dateTimeRaw (String, parsed via SupabaseDateParser)
created_at      → createdAtRaw (String, parsed via SupabaseDateParser)
updated_at      → updatedAtRaw
paid_at         → paidAtRaw
publish_at      → publishAtRaw
contact_email   → contactEmail
members_only    → membersOnly
win_condition   → winConditionRaw
default_court_count → defaultCourtCount
venue_name      → venueName
street_address  → streetAddress
image_url       → imageURLString
created_by      → createdByUserID
recurrence_group_id → recurrenceGroupID
requires_dupr   → requiresDUPR
fee_amount      → feeAmount
fee_currency    → feeCurrency
max_spots       → maxSpots
court_count     → courtCount
waitlist_position → waitlistPosition
stripe_payment_intent_id → stripePaymentIntentID
payment_method  → paymentMethod
hero_image_key  → heroImageKey
code_of_conduct → codeOfConduct
dupr_rating     → duprRating
emergency_contact_name → emergencyContactName
emergency_contact_phone → emergencyContactPhone
date_of_birth   → dateOfBirth
```

Raw date strings are always stored as `*Raw: String?` and converted to `Date?` using `flatMap(SupabaseDateParser.parse)`.

## File Organisation
```
BookadinkV2/
  App/           AppState.swift, BookADinkApp.swift
  Models/        Models.swift  (all domain types)
  Services/      SupabaseService.swift (protocol + implementation)
                 LocalCalendarManager.swift
                 LocalNotificationManager.swift
                 LocationManager.swift, LocationService.swift
                 DeepLinkRouter.swift
  Theme/         Brand.swift, Glass.swift, ProfileAvatarPresets.swift
  Views/
    Auth/        AuthWelcomeView.swift
    Bookings/    BookingsListView.swift
    Clubs/       ClubDetailView.swift, ClubsListView.swift, ClubGameRow.swift,
                 ClubOwnerSheets.swift, ClubNewsView.swift, ClubBookGameView.swift
    Games/       GameDetailView.swift, GameScheduleSheet.swift
    Home/        (home tab views)
    Main/        MainTabView.swift
    Notifications/ NotificationsView.swift
    Onboarding/  OnboardingView.swift
    Profile/     ProfileDashboardView.swift, ProfileSetupView.swift,
                 DUPRHistoryCard.swift, DUPRHistoryDetailView.swift,
                 GamesPlayedCard.swift
  Extensions/    MapNavigationURL.swift
supabase/
  functions/     booking-confirmed/, send-notification-email/,
                 notify/, create-payment-intent/, archive-old-games/
```

## Target Membership
Every new `.swift` file **must** be manually added in Xcode → File Inspector → Target Membership. Missing this causes "Cannot find type X in scope" cascade errors at build time.

## UserDefaults Storage Keys (AppState.StorageKeys)
```swift
"bookadink.auth.session"
"bookadink.owner.checkedInBookingIDs"
"bookadink.clubNews.notificationsEnabled"
"bookadink.profile.duprIDByUserID"
"bookadink.profile.duprRatingsByUserID"   // [userIDString: {d: Double, s: Double}]
"bookadink.profile.duprHistoryByUserID"
```
