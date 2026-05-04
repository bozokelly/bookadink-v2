-- Harden promote_waitlist_player(): lock games row + count active seats.
-- ─────────────────────────────────────────────────────────────────────────────
-- INCIDENT (2026-05-01):
--   A game with max_spots=4 ended up with 5 confirmed bookings. Sequence:
--     1. 4 confirmed, 2 waitlisted (BC#1, BK#2).
--     2. A confirmed player cancels → promote_top_waitlisted trigger correctly
--        promotes BC to pending_payment (3 confirmed + 1 pending = 4 active ✓).
--     3. The admin's iOS client then ran autoPromoteWaitlistIfPossible, which
--        counted ONLY confirmed (3) and computed openSlots = 4 - 3 = 1.
--     4. iOS promoteWaitlistPlayer did a direct PATCH on bookings with
--        WHERE status = 'waitlisted' — NO games row lock, NO capacity check.
--        BK was flipped to pending_payment.
--     5. Result: 3 confirmed + 2 pending = 5 active for max=4. Both paid →
--        confirmed → 5/4 over-booked.
--
-- WHAT THIS MIGRATION DOES:
--   Replaces promote_waitlist_player with a hardened version that mirrors the
--   invariants enforced by book_game() and owner_create_booking():
--     1. SELECT games FOR UPDATE — serialises with book_game(), the trigger,
--        the cron, and any concurrent promote calls.
--     2. Counts confirmed + pending_payment as active seats (NEVER just
--        confirmed — pending_payment physically holds a seat).
--     3. Returns FALSE if invariant would be violated, so callers see a
--        clean "no spot available" rather than a silent over-promotion.
--     4. Computes hold_expires_at server-side (clamped to a sane minimum)
--        instead of trusting the client-provided value blindly.
--
--   This is defence-in-depth. The iOS client-side auto-promote is being
--   removed in the same commit (the DB trigger handles the same case
--   automatically and correctly). This RPC remains as a safety net for
--   admin tooling, manual SQL ops, and any future caller that needs to
--   force-promote a specific waitlisted booking.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE + idempotent GRANT.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION promote_waitlist_player(
    p_game_id      UUID,
    p_booking_id   UUID,
    p_hold_minutes INT DEFAULT 30
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_spots    INT;
    v_fee_amount   INT;
    v_is_paid      BOOLEAN;
    v_active_cnt   INT;
    v_hold_mins    INT;
    v_rows_updated INT;
BEGIN
    -- Lock the game row. Same lock book_game(), owner_create_booking(),
    -- and recompact_waitlist_positions() take. Without this, a concurrent
    -- book_game() could read max_spots and count active seats while we hold
    -- a stale snapshot — leading to over-booking under load.
    SELECT g.max_spots, COALESCE(g.fee_amount, 0)
    INTO   v_max_spots, v_fee_amount
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    v_is_paid := v_fee_amount > 0;

    -- Count active seats. confirmed AND pending_payment both physically hold
    -- a seat — the canonical invariant is `confirmed + pending_payment <= max_spots`.
    -- Counting only confirmed is the bug class that produced the 5/4 incident.
    SELECT COUNT(*)
    INTO   v_active_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_active_cnt >= v_max_spots THEN
        RETURN FALSE;
    END IF;

    -- Clamp hold_minutes to a sane range. Negative or zero values would
    -- create an immediately-expired hold (cron picks it up next minute and
    -- forfeits the user — confusing UX). Cap upper bound at 1440 (24h) so
    -- a buggy caller can't squat on a seat indefinitely.
    v_hold_mins := GREATEST(1, LEAST(COALESCE(p_hold_minutes, 30), 1440));

    -- Promote — atomic with the lock above. The status='waitlisted' filter
    -- means the promote_top_waitlisted trigger or another concurrent caller
    -- can't double-promote: only one of the racing UPDATEs will see status
    -- as 'waitlisted' at commit time, the other affects 0 rows.
    IF v_is_paid THEN
        UPDATE bookings b
        SET
            status            = 'pending_payment',
            waitlist_position = NULL,
            hold_expires_at   = now() + (v_hold_mins || ' minutes')::INTERVAL,
            promoted_at       = now()
        WHERE  b.id      = p_booking_id
          AND  b.game_id = p_game_id
          AND  b.status::text = 'waitlisted';
    ELSE
        -- Free game — no payment hold needed; promote straight to confirmed.
        UPDATE bookings b
        SET
            status            = 'confirmed',
            waitlist_position = NULL,
            hold_expires_at   = NULL,
            promoted_at       = now()
        WHERE  b.id      = p_booking_id
          AND  b.game_id = p_game_id
          AND  b.status::text = 'waitlisted';
    END IF;

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
    RETURN v_rows_updated > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION promote_waitlist_player(UUID, UUID, INT) TO authenticated;
