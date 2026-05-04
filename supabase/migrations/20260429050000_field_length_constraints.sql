-- Field length constraints — server-authoritative validation
--
-- Purpose: enforce the same limits the iOS sanitiser/validator already applies,
-- so Android, web, and direct API calls receive clean DB errors instead of
-- silently storing oversized values.
--
-- ALL constraints are added NOT VALID so the migration runs without scanning
-- existing rows. Run the STEP 0 audit queries below, fix any violations, then
-- run the VALIDATE statements at the bottom to lock in the constraints.
--
-- ┌─────────────────────────────────────────────────────────────┐
-- │ STEP 0 — run these BEFORE applying this migration.         │
-- │ If any query returns rows, fix the data first.             │
-- └─────────────────────────────────────────────────────────────┘
--
-- SELECT id, name, length(name)             FROM clubs        WHERE length(name) > 120;
-- SELECT id, length(description)            FROM clubs        WHERE length(description) > 2000;
-- SELECT id, length(contact_email)          FROM clubs        WHERE length(contact_email) > 320;
-- SELECT id, length(contact_phone)          FROM clubs        WHERE length(contact_phone) > 30;
-- SELECT id, length(website)                FROM clubs        WHERE length(website) > 260;
-- SELECT id, length(manager_name)           FROM clubs        WHERE length(manager_name) > 160;
-- SELECT id, length(suburb)                 FROM clubs        WHERE length(suburb) > 80;
-- SELECT id, length(state)                  FROM clubs        WHERE length(state) > 80;
-- SELECT id, length(venue_name)             FROM clubs        WHERE length(venue_name) > 260;
--
-- SELECT id, length(venue_name)             FROM club_venues  WHERE length(venue_name) > 260;
-- SELECT id, length(suburb)                 FROM club_venues  WHERE length(suburb) > 80;
-- SELECT id, length(state)                  FROM club_venues  WHERE length(state) > 80;
--
-- SELECT id, title, length(title)           FROM games        WHERE length(title) > 200;
-- SELECT id, max_spots                      FROM games        WHERE max_spots IS NOT NULL AND (max_spots < 2 OR max_spots > 64);
-- SELECT id, court_count                    FROM games        WHERE court_count IS NOT NULL AND (court_count < 1 OR court_count > 50);
--
-- SELECT id, length(full_name)              FROM profiles     WHERE length(full_name) > 200;
-- SELECT id, length(phone)                  FROM profiles     WHERE length(phone) > 30;
-- SELECT id, length(emergency_contact_name) FROM profiles     WHERE length(emergency_contact_name) > 160;
-- SELECT id, length(emergency_contact_phone)FROM profiles     WHERE length(emergency_contact_phone) > 30;
-- SELECT id, dupr_id, length(dupr_id)       FROM profiles     WHERE dupr_id IS NOT NULL AND (length(trim(dupr_id)) < 6 OR length(dupr_id) > 24);

-- ─────────────────────────────────────────────────────────────────────────────
-- clubs
-- Limits mirror ClubRow.toClub() sanitizedText() calls in SupabaseService.swift
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE clubs
    ADD CONSTRAINT clubs_name_length_check
        CHECK (length(name) <= 120) NOT VALID,

    ADD CONSTRAINT clubs_description_length_check
        CHECK (description IS NULL OR length(description) <= 2000) NOT VALID,

    ADD CONSTRAINT clubs_contact_email_length_check
        CHECK (contact_email IS NULL OR length(contact_email) <= 320) NOT VALID,

    ADD CONSTRAINT clubs_contact_phone_length_check
        CHECK (contact_phone IS NULL OR length(contact_phone) <= 30) NOT VALID,

    ADD CONSTRAINT clubs_website_length_check
        CHECK (website IS NULL OR length(website) <= 260) NOT VALID,

    ADD CONSTRAINT clubs_manager_name_length_check
        CHECK (manager_name IS NULL OR length(manager_name) <= 160) NOT VALID,

    ADD CONSTRAINT clubs_suburb_length_check
        CHECK (suburb IS NULL OR length(suburb) <= 80) NOT VALID,

    ADD CONSTRAINT clubs_state_length_check
        CHECK (state IS NULL OR length(state) <= 80) NOT VALID,

    ADD CONSTRAINT clubs_venue_name_length_check
        CHECK (venue_name IS NULL OR length(venue_name) <= 260) NOT VALID;

-- ─────────────────────────────────────────────────────────────────────────────
-- club_venues
-- Same limits as the club-level address columns they mirror.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE club_venues
    ADD CONSTRAINT club_venues_venue_name_length_check
        CHECK (venue_name IS NULL OR length(venue_name) <= 260) NOT VALID,

    ADD CONSTRAINT club_venues_suburb_length_check
        CHECK (suburb IS NULL OR length(suburb) <= 80) NOT VALID,

    ADD CONSTRAINT club_venues_state_length_check
        CHECK (state IS NULL OR length(state) <= 80) NOT VALID;

-- ─────────────────────────────────────────────────────────────────────────────
-- games
-- max_spots and court_count: stepper enforces 2–64 and 1–50 on iOS.
-- title: required non-empty in iOS; 200 added as DB upper bound.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE games
    ADD CONSTRAINT games_title_length_check
        CHECK (length(trim(title)) > 0 AND length(title) <= 200) NOT VALID,

    ADD CONSTRAINT games_max_spots_range_check
        CHECK (max_spots IS NULL OR (max_spots >= 2 AND max_spots <= 64)) NOT VALID,

    ADD CONSTRAINT games_court_count_range_check
        CHECK (court_count IS NULL OR (court_count >= 1 AND court_count <= 50)) NOT VALID;

-- ─────────────────────────────────────────────────────────────────────────────
-- profiles
-- dupr_id: iOS validates 6–24 chars via saveCurrentUserDUPRID.
-- Other fields: lengths match the equivalent club contact field patterns.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE profiles
    ADD CONSTRAINT profiles_full_name_length_check
        CHECK (full_name IS NULL OR length(full_name) <= 200) NOT VALID,

    ADD CONSTRAINT profiles_phone_length_check
        CHECK (phone IS NULL OR length(phone) <= 30) NOT VALID,

    ADD CONSTRAINT profiles_emergency_contact_name_length_check
        CHECK (emergency_contact_name IS NULL OR length(emergency_contact_name) <= 160) NOT VALID,

    ADD CONSTRAINT profiles_emergency_contact_phone_length_check
        CHECK (emergency_contact_phone IS NULL OR length(emergency_contact_phone) <= 30) NOT VALID,

    ADD CONSTRAINT profiles_dupr_id_length_check
        CHECK (dupr_id IS NULL OR (length(trim(dupr_id)) >= 6 AND length(dupr_id) <= 24)) NOT VALID;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — after verifying STEP 0 returns no rows, validate each constraint.
-- Run these individually so a single failure doesn't block the rest.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_name_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_description_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_contact_email_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_contact_phone_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_website_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_manager_name_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_suburb_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_state_length_check;
-- ALTER TABLE clubs      VALIDATE CONSTRAINT clubs_venue_name_length_check;
-- ALTER TABLE club_venues VALIDATE CONSTRAINT club_venues_venue_name_length_check;
-- ALTER TABLE club_venues VALIDATE CONSTRAINT club_venues_suburb_length_check;
-- ALTER TABLE club_venues VALIDATE CONSTRAINT club_venues_state_length_check;
-- ALTER TABLE games       VALIDATE CONSTRAINT games_title_length_check;
-- ALTER TABLE games       VALIDATE CONSTRAINT games_max_spots_range_check;
-- ALTER TABLE games       VALIDATE CONSTRAINT games_court_count_range_check;
-- ALTER TABLE profiles    VALIDATE CONSTRAINT profiles_full_name_length_check;
-- ALTER TABLE profiles    VALIDATE CONSTRAINT profiles_phone_length_check;
-- ALTER TABLE profiles    VALIDATE CONSTRAINT profiles_emergency_contact_name_length_check;
-- ALTER TABLE profiles    VALIDATE CONSTRAINT profiles_emergency_contact_phone_length_check;
-- ALTER TABLE profiles    VALIDATE CONSTRAINT profiles_dupr_id_length_check;
