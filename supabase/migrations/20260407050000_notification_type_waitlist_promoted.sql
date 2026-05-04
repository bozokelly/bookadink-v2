-- Add waitlist_promoted to notification_type enum
--
-- PROBLEM:
--   The notify Edge Function inserts into the notifications table with
--   type = 'waitlist_promoted'. If this value is missing from the
--   notification_type enum the INSERT fails with:
--     "invalid input value for enum notification_type: \"waitlist_promoted\""
--   This failure is silent from the DB trigger's perspective (pg_net fires
--   the HTTP call but the Edge Function returns 500), so no notification row
--   is created and no APNs push is sent.
--
-- FIX:
--   Add 'waitlist_promoted' to the enum. PostgreSQL requires ADD VALUE to
--   run outside a transaction block — this is fine for a migration run via
--   the SQL Editor.
--
-- SAFE TO RE-RUN:
--   IF NOT EXISTS prevents an error if the value already exists (PostgreSQL 9.6+).

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'waitlist_promoted';
