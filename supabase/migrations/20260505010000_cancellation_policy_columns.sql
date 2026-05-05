-- Additive: cancellation policy columns on clubs + replacement marker on bookings.
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT THIS DOES
--   Adds three columns required by the new cancellation-policy logic:
--     • clubs.cancellation_policy_type TEXT NOT NULL DEFAULT 'managed'
--         CHECK ('managed', 'club_managed')
--         'managed'      → cancel_booking_with_credit applies the credit logic
--         'club_managed' → club handles cancellations off-platform; the RPC
--                          cancels the booking and never issues credit.
--     • clubs.cancellation_cutoff_hours INTEGER NOT NULL DEFAULT 12
--         CHECK BETWEEN 1 AND 48
--         Hours before game start. Cancelling at-or-before the cutoff is
--         eligible for credit (in 'managed' clubs) when the spot is not
--         filled by a waitlister.
--     • bookings.was_replaced BOOLEAN NOT NULL DEFAULT FALSE
--         Set TRUE on a cancelled booking by the waitlist-promotion paths
--         (trigger, cron, admin RPC) when a waitlister fills the freed spot.
--         cancel_booking_with_credit re-reads this flag after cancelling so
--         the trigger's update is visible; if TRUE, credit is issued
--         regardless of cutoff. Append-only style: never set back to FALSE.
--
-- WHAT THIS DOES NOT DO
--   Does NOT touch any function. Does NOT change any logic. The four
--   touched functions (cancel_booking_with_credit, promote_top_waitlisted,
--   revert_expired_holds_and_repromote, promote_waitlist_player) continue
--   to use their existing 6-hour cutoff and ignore was_replaced until the
--   surgical companion migration (20260505020000) is applied.
--
-- BLAST RADIUS
--   Zero. Three columns with NOT NULL defaults — existing rows backfill
--   instantly to the defaults. Existing logic continues unchanged because
--   nothing reads these columns yet.
--
-- COEXISTENCE WITH OLDER cancellation_policy COLUMN
--   migration 20260419040000_cancellation_policy.sql added a free-text
--   `clubs.cancellation_policy` column for the human-readable policy
--   description shown to members at join time. That column is unrelated to
--   this one and stays as-is. The new column is named cancellation_policy_TYPE
--   to avoid any conflict with the existing free-text column.
--
-- VERIFY AFTER RUN
--   SELECT cancellation_policy_type, cancellation_cutoff_hours
--     FROM clubs LIMIT 5;
--   -- All rows: 'managed', 12.
--
--   SELECT was_replaced FROM bookings LIMIT 5;
--   -- All rows: FALSE.
--
--   -- Constraint smoke tests (should all error):
--   --   UPDATE clubs SET cancellation_policy_type = 'whatever' WHERE id = ...;
--   --   UPDATE clubs SET cancellation_cutoff_hours = 0          WHERE id = ...;
--   --   UPDATE clubs SET cancellation_cutoff_hours = 49         WHERE id = ...;
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. clubs: cancellation_policy_type ───────────────────────────────────────
ALTER TABLE clubs
    ADD COLUMN IF NOT EXISTS cancellation_policy_type TEXT NOT NULL DEFAULT 'managed';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM   pg_constraint
        WHERE  conname = 'clubs_cancellation_policy_type_check'
    ) THEN
        ALTER TABLE clubs
            ADD CONSTRAINT clubs_cancellation_policy_type_check
            CHECK (cancellation_policy_type IN ('managed', 'club_managed'));
    END IF;
END;
$$;

COMMENT ON COLUMN clubs.cancellation_policy_type IS
'managed = platform issues credits per cancel_booking_with_credit; club_managed = club handles refunds off-platform, RPC never issues credit. Default: managed.';


-- ── 2. clubs: cancellation_cutoff_hours ──────────────────────────────────────
ALTER TABLE clubs
    ADD COLUMN IF NOT EXISTS cancellation_cutoff_hours INTEGER NOT NULL DEFAULT 12;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM   pg_constraint
        WHERE  conname = 'clubs_cancellation_cutoff_hours_check'
    ) THEN
        ALTER TABLE clubs
            ADD CONSTRAINT clubs_cancellation_cutoff_hours_check
            CHECK (cancellation_cutoff_hours BETWEEN 1 AND 48);
    END IF;
END;
$$;

COMMENT ON COLUMN clubs.cancellation_cutoff_hours IS
'Hours before game start. Cancelling at or before this cutoff is eligible for credit when not replaced. Range: 1..48. Default: 12.';


-- ── 3. bookings: was_replaced ────────────────────────────────────────────────
ALTER TABLE bookings
    ADD COLUMN IF NOT EXISTS was_replaced BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN bookings.was_replaced IS
'Set TRUE by a waitlist-promotion path (promote_top_waitlisted trigger, revert_expired_holds_and_repromote cron, promote_waitlist_player RPC) when a waitlister fills this booking''s freed spot. Read by cancel_booking_with_credit to grant credit even past the cutoff. Append-only: never reset to FALSE once set.';
