-- owner_create_booking() — admin-add-player flow with capacity invariant
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   Admin "Add player" did a direct PostgREST INSERT into bookings, bypassing
--   book_game()'s FOR UPDATE lock and capacity count. Two concrete bugs:
--
--   1. Client-side gameFull check counted only `confirmed` bookings, ignoring
--      `pending_payment` (held seats during the 30-min waitlist promotion
--      window). Admins could add a player as `confirmed` while another player
--      held a pending_payment seat → confirmed + pending_payment > max_spots.
--
--   2. No server-side enforcement at all. Two admins clicking simultaneously
--      could race past the client check.
--
-- DESIGN:
--   Mirror book_game() pattern exactly:
--     - SELECT games FOR UPDATE
--     - Count confirmed + pending_payment under the lock
--     - Branch: < max_spots → confirmed, >= max_spots → waitlisted (next pos)
--     - Insert booking with payment_method='admin'
--   Bypasses the DUPR gate (admin privilege — see book_game() DUPR section
--   in CLAUDE.md).
--
--   Caller authorization: must be the club owner or a club_admins row for the
--   game's club. Mirrors existing analytics RPC patterns.
--
-- INVARIANT GUARANTEED:
--   confirmed + pending_payment <= max_spots, enforced under the same row lock
--   as book_game(). Concurrent admin adds and player bookings serialize on the
--   games row.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION owner_create_booking(
    p_game_id UUID,
    p_user_id UUID
)
RETURNS TABLE(
    id                       UUID,
    game_id                  UUID,
    user_id                  UUID,
    status                   TEXT,
    waitlist_position        INT,
    created_at               TIMESTAMPTZ,
    fee_paid                 BOOLEAN,
    paid_at                  TIMESTAMPTZ,
    stripe_payment_intent_id TEXT,
    payment_method           TEXT,
    platform_fee_cents       INT,
    club_payout_cents        INT,
    credits_applied_cents    INT,
    hold_expires_at          TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller        UUID := auth.uid();
    v_club_id       UUID;
    v_max_spots     INT;
    v_active_cnt    INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID := gen_random_uuid();
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    -- Lock the game row. Reading club_id + max_spots together so authorization
    -- and capacity decisions are based on the same locked snapshot.
    SELECT club_id, max_spots
    INTO   v_club_id, v_max_spots
    FROM   games
    WHERE  games.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Authorization: caller must be club owner or in club_admins for this club.
    -- All column references are qualified to avoid PL/pgSQL OUT-name shadowing
    -- (RETURNS TABLE declares user_id, game_id, status, waitlist_position which
    -- become variables in scope; unqualified column references throw 42702).
    IF NOT EXISTS (
        SELECT 1 FROM club_admins ca
        WHERE  ca.club_id = v_club_id
          AND  ca.user_id = v_caller
    ) AND NOT EXISTS (
        SELECT 1 FROM clubs c
        WHERE  c.id = v_club_id
          AND  c.created_by = v_caller
    ) THEN
        RAISE EXCEPTION 'forbidden_not_admin';
    END IF;

    -- Reject duplicate: an active (non-cancelled) booking already exists.
    IF EXISTS (
        SELECT 1 FROM bookings b
        WHERE  b.game_id = p_game_id
          AND  b.user_id = p_user_id
          AND  b.status::text IN ('confirmed', 'pending_payment', 'waitlisted')
    ) THEN
        RAISE EXCEPTION 'duplicate_booking';
    END IF;

    -- Capacity count under the lock — same definition as book_game().
    -- Confirmed and pending_payment both physically hold a seat.
    SELECT COUNT(*) INTO v_active_cnt
    FROM   bookings b
    WHERE  b.game_id = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_active_cnt >= v_max_spots THEN
        SELECT COALESCE(MAX(b.waitlist_position), 0) + 1 INTO v_waitlist_pos
        FROM   bookings b
        WHERE  b.game_id = p_game_id
          AND  b.status::text = 'waitlisted';

        v_status := 'waitlisted';
    ELSE
        v_waitlist_pos := NULL;
        v_status := 'confirmed';
    END IF;

    INSERT INTO bookings (
        id,
        game_id,
        user_id,
        status,
        waitlist_position,
        payment_method
    ) VALUES (
        v_booking_id,
        p_game_id,
        p_user_id,
        v_status::booking_status,
        v_waitlist_pos,
        'admin'
    );

    RETURN QUERY
    SELECT
        b.id,
        b.game_id,
        b.user_id,
        b.status::TEXT,
        b.waitlist_position,
        b.created_at,
        b.fee_paid,
        b.paid_at,
        b.stripe_payment_intent_id,
        b.payment_method,
        b.platform_fee_cents,
        b.club_payout_cents,
        b.credits_applied_cents,
        b.hold_expires_at
    FROM bookings b
    WHERE b.id = v_booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION owner_create_booking(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION owner_create_booking(UUID, UUID) IS
    'Admin-add-player: server-authoritative booking creation that enforces '
    'confirmed + pending_payment <= max_spots under the same FOR UPDATE lock '
    'as book_game(). Returns the inserted booking. Bypasses DUPR (admin '
    'privilege). Caller must be club owner or club_admins for the game''s club.';
