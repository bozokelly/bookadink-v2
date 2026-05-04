-- Add pending_payment to booking_status enum
--
-- PROBLEM:
--   The promote_top_waitlisted() trigger (Phase 3) sets status = 'pending_payment'
--   for paid-game waitlist promotions, but the booking_status enum does not include
--   this value. This causes a Supabase 400 error:
--     "invalid input value for enum booking_status: \"pending_payment\""
--
-- FIX:
--   Add 'pending_payment' to the enum. PostgreSQL requires ADD VALUE to be run
--   outside a transaction block — this is fine for a migration run via SQL Editor.
--
-- SAFE TO RE-RUN:
--   IF NOT EXISTS prevents an error if the value already exists (PostgreSQL 9.6+).

ALTER TYPE booking_status ADD VALUE IF NOT EXISTS 'pending_payment';
