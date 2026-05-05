-- Additive: replacement tracking columns on bookings.
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT THIS DOES
--   Adds three columns required by the deferred cancellation-credit logic:
--
--     • bookings.replacement_booking_id UUID NULL REFERENCES bookings(id)
--         Set on a CANCELLED booking when a waitlister is promoted into the
--         freed seat. Points to the candidate replacement booking. The link
--         can be re-pointed (e.g. when a held replacement forfeits and the
--         cron promotes the next waitlister) — see migration 20260505040000.
--
--     • bookings.replacement_confirmed_at TIMESTAMPTZ NULL
--         Set on the cancelled booking when the replacement booking actually
--         transitions into a confirmed/paid state (paid game: confirmed AND
--         fee_paid=TRUE; free game: confirmed). Audit-only timestamp; not
--         read by any decision logic.
--
--     • bookings.replacement_credit_issued_at TIMESTAMPTZ NULL
--         Idempotency guard for the cancellation credit. Set the moment a
--         credit is issued for this booking — by either the immediate
--         cutoff path (cancel_booking_with_credit when NOW() <= cutoff) or
--         the deferred trigger path (when the replacement booking confirms).
--         Once non-NULL, no further credit can ever be issued for this
--         booking. Append-only.
--
-- WHAT THIS DOES NOT DO
--   Does NOT touch any function. Does NOT change any logic. The existing
--   cancellation/promotion/cron functions continue to ignore these columns
--   until the surgical companion migration (20260505040000) is applied.
--
-- COEXISTENCE WITH bookings.was_replaced
--   was_replaced (added in 20260505010000) remains the boolean "the freed
--   seat has actually been filled by a confirmed/paid replacement" flag.
--   Under the new model:
--     • free game inline replacement → was_replaced flips TRUE inside the
--       same cancel_booking_with_credit transaction (existing behaviour).
--     • paid game promotion to pending_payment → was_replaced stays FALSE
--       until the replacement booking actually confirms AND pays.
--   replacement_credit_issued_at is the strict idempotency marker; was_replaced
--   tracks the audit fact that the seat is filled. They can diverge when
--   credit is issued via the cutoff path with no replacement (eligible by
--   time) — was_replaced FALSE, replacement_credit_issued_at non-NULL.
--
-- BLAST RADIUS
--   Zero. Three nullable columns, no defaults beyond NULL. Adds a partial
--   index that's empty until the companion migration starts populating
--   replacement_booking_id.
--
-- VERIFY AFTER RUN
--   SELECT replacement_booking_id, replacement_confirmed_at, replacement_credit_issued_at
--     FROM bookings LIMIT 5;
--   -- All rows: NULL, NULL, NULL.
--
--   -- FK enforcement (should error: target booking does not exist)
--   --   UPDATE bookings SET replacement_booking_id = '00000000-0000-0000-0000-000000000000'
--   --     WHERE id = (SELECT id FROM bookings LIMIT 1);
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. Columns ──────────────────────────────────────────────────────────────
ALTER TABLE bookings
    ADD COLUMN IF NOT EXISTS replacement_booking_id        UUID        NULL REFERENCES bookings(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS replacement_confirmed_at      TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS replacement_credit_issued_at  TIMESTAMPTZ NULL;

COMMENT ON COLUMN bookings.replacement_booking_id IS
'Set on a cancelled booking when a waitlister is promoted into the freed seat. Points to the candidate replacement booking. May be re-pointed by revert_expired_holds_and_repromote when a held replacement forfeits and the next waitlister is promoted. Cleared back to NULL only when no next replacement exists. Set ONLY by server-side promotion paths.';

COMMENT ON COLUMN bookings.replacement_confirmed_at IS
'Audit timestamp set when the replacement booking actually confirmed (paid game: confirmed AND fee_paid=TRUE; free game: confirmed). Read by no decision logic; for tracing/reporting only.';

COMMENT ON COLUMN bookings.replacement_credit_issued_at IS
'Idempotency guard for cancellation credit. NULL = no credit issued yet (or no credit ever; e.g. club_managed). Non-NULL = credit was issued (by cutoff path or deferred trigger). Once non-NULL, NO further credit issuance is permitted for this booking. Append-only.';


-- ── 2. Lookup index for the deferred-credit trigger ────────────────────────
-- The deferred trigger looks up cancelled bookings whose replacement candidate
-- has just confirmed: WHERE replacement_booking_id = NEW.id AND status='cancelled'
--   AND was_replaced = FALSE AND replacement_credit_issued_at IS NULL.
-- A partial index keeps the working set tiny — only cancelled bookings with an
-- outstanding replacement candidate ever enter the index.
CREATE INDEX IF NOT EXISTS idx_bookings_pending_replacement
    ON bookings (replacement_booking_id)
    WHERE replacement_booking_id IS NOT NULL
      AND was_replaced = FALSE
      AND replacement_credit_issued_at IS NULL;
