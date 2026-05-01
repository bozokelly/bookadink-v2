# DB Schema — Book A Dink (Supabase/PostgREST)

## Critical Rule
PostgREST only returns columns you explicitly enumerate in `select=`. **Any new column added to a Swift model must also be added to ALL relevant `select=` strings in `SupabaseService.swift`**. Omitting a column silently decodes as `nil`.

## Tables & Key Columns

### `clubs`
```
id UUID PK
name TEXT
description TEXT
image_url TEXT  (http/https/bookadink-avatar scheme — sanitised at decode)
contact_email TEXT
website TEXT
manager_name TEXT
members_only BOOL
created_by UUID FK→auth.users
win_condition TEXT  (e.g. "first_to_11_by2")
default_court_count INT
venue_name TEXT
street_address TEXT
suburb TEXT
state TEXT
postcode TEXT
country TEXT
latitude DOUBLE
longitude DOUBLE  ← MUST stay in all 5 club select= strings
hero_image_key TEXT
code_of_conduct TEXT
```

### `games`
```
id UUID PK
club_id UUID FK→clubs
title TEXT
description TEXT
date_time TIMESTAMPTZ
duration_minutes INT
skill_level TEXT  ("all"|"beginner"|"intermediate"|"advanced")
game_format TEXT  ("open_play"|"round_robin"|"king_of_court")
game_type TEXT  ("singles"|"doubles")
max_spots INT
court_count INT
fee_amount DOUBLE
fee_currency TEXT
venue_id UUID FK→club_venues
venue_name TEXT  (denormalised for display safety)
location TEXT
latitude DOUBLE
longitude DOUBLE
status TEXT  ("upcoming"|"cancelled"|"completed")
notes TEXT
requires_dupr BOOL
recurrence_group_id UUID  (groups recurring instances)
publish_at TIMESTAMPTZ NULL  (NULL=immediate; future=scheduled/hidden)
archived_at TIMESTAMPTZ NULL  (soft-delete; always filter with archived_at.is.null)
created_by UUID FK→auth.users
```

### `bookings`
```
id UUID PK
game_id UUID FK→games
user_id UUID FK→auth.users
status TEXT  ("confirmed"|"waitlisted"|"cancelled")
waitlist_position INT
created_at TIMESTAMPTZ
fee_paid BOOL
paid_at TIMESTAMPTZ
stripe_payment_intent_id TEXT
payment_method TEXT NULL  ("stripe"|"admin"|nil)
```
Required migration: `ALTER TABLE bookings ADD COLUMN IF NOT EXISTS payment_method TEXT NULL;`

### `profiles`
```
id UUID PK = auth.users.id
email TEXT
full_name TEXT
phone TEXT
date_of_birth DATE
emergency_contact_name TEXT
emergency_contact_phone TEXT
dupr_rating DOUBLE
skill_level TEXT
avatar_preset_id TEXT
push_token TEXT
```
RLS UPDATE policy **must** include `WITH CHECK (auth.uid() = id)` — without it PostgREST upserts silently fail.

### `club_members`
```
id UUID PK
club_id UUID FK→clubs
user_id UUID FK→auth.users
status TEXT  ("pending"|"approved"|"rejected")
requested_at TIMESTAMPTZ
conduct_accepted_at TIMESTAMPTZ
```

### `club_admins`
```
club_id UUID FK→clubs
user_id UUID FK→auth.users
role TEXT  ("owner"|"admin")
```

### `club_venues`
```
id UUID PK
club_id UUID FK→clubs
venue_name TEXT
street_address TEXT
suburb TEXT
state TEXT
postcode TEXT
country TEXT
is_primary BOOL
latitude DOUBLE
longitude DOUBLE
```

### `notifications`
```
id UUID PK
user_id UUID FK→auth.users
title TEXT
body TEXT
type TEXT  (see NotificationType enum)
reference_id UUID  (game_id or club_id depending on type)
read BOOL
created_at TIMESTAMPTZ
```
Required RLS: `CREATE POLICY "Users can delete own notifications" ON notifications FOR DELETE USING (auth.uid() = user_id);`
DB trigger `send_notification_email` on INSERT calls `send-notification-email` Edge Function via `net.http_post`.

### `game_attendance`
```
game_id UUID FK→games
booking_id UUID FK→bookings
user_id UUID FK→auth.users
checked_in_by UUID FK→auth.users
checked_in_at TIMESTAMPTZ
payment_status TEXT  ("unpaid"|"cash"|"stripe")
```

### `game_reviews`
```
id UUID PK
game_id UUID FK→games
user_id UUID FK→auth.users
rating INT
comment TEXT
created_at TIMESTAMPTZ
```

### `club_messages` (club chat posts + moderation reports)
Posts and moderation reports are stored here.

## Select String Inventory (5 club queries, 8+ game queries)
All club queries use identical column list including `latitude,longitude`.
All game queries include `publish_at`. All booking queries include `payment_method`.

## Date Handling
- Read: `SupabaseDateParser.parse()` — tries `.withFractionalSeconds` then standard ISO8601
- Write: `SupabaseDateWriter.string(from:)` — ISO8601 with fractional seconds
- Raw string fields named `*Raw` (e.g. `dateTimeRaw`, `createdAtRaw`) converted via `flatMap(SupabaseDateParser.parse)`
