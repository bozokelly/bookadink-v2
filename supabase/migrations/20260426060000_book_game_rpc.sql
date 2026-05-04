-- Atomic booking creation that eliminates the client-side race condition
-- where two concurrent requests both read liveGame.isFull == false and
-- both insert with status = 'confirmed', overflowing the max_players cap.
--
-- The function acquires a row-level FOR UPDATE lock on the games row,
-- counts confirmed + pending_payment bookings inside that lock, then
-- inserts with the server-determined status. No client ever decides
-- confirmed vs waitlisted — the DB does.

CREATE OR REPLACE FUNCTION book_game(
    p_game_id              UUID,
    p_user_id              UUID,
    p_fee_paid             BOOLEAN   DEFAULT FALSE,
    p_stripe_pi_id         TEXT      DEFAULT NULL,
    p_payment_method       TEXT      DEFAULT NULL,
    p_platform_fee_cents   INT       DEFAULT NULL,
    p_club_payout_cents    INT       DEFAULT NULL,
    p_credits_applied_cents INT      DEFAULT NULL
)
RETURNS TABLE(
    id                      UUID,
    game_id                 UUID,
    user_id                 UUID,
    status                  TEXT,
    waitlist_position       INT,
    created_at              TIMESTAMPTZ,
    fee_paid                BOOLEAN,
    paid_at                 TIMESTAMPTZ,
    stripe_payment_intent_id TEXT,
    payment_method          TEXT,
    platform_fee_cents      INT,
    club_payout_cents       INT,
    credits_applied_cents   INT,
    hold_expires_at         TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_spots     INT;
    v_confirmed_cnt INT;
    v_waitlist_cnt  INT;
    v_status        TEXT;
    v_waitlist_pos  INT;
    v_booking_id    UUID;
BEGIN
    -- Lock the game row to prevent concurrent over-booking.
    SELECT max_spots
    INTO   v_max_spots
    FROM   games
    WHERE  id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Count active (non-cancelled) seats.
    -- Cast status::text because booking_status is a PG enum; direct string
    -- comparisons in IN() raise 22P02 on some PG versions (see CLAUDE.md).
    SELECT COUNT(*) INTO v_confirmed_cnt
    FROM   bookings
    WHERE  game_id = p_game_id
      AND  status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_confirmed_cnt >= v_max_spots THEN
        -- Game is full — place on waitlist.
        SELECT COALESCE(MAX(waitlist_position), 0) + 1 INTO v_waitlist_pos
        FROM   bookings
        WHERE  game_id = p_game_id
          AND  status::text = 'waitlisted';

        v_status       := 'waitlisted';
    ELSE
        -- Spot available.
        v_waitlist_pos := NULL;
        v_status       := 'confirmed';
    END IF;

    INSERT INTO bookings (
        game_id,
        user_id,
        status,
        waitlist_position,
        fee_paid,
        stripe_payment_intent_id,
        payment_method,
        platform_fee_cents,
        club_payout_cents,
        credits_applied_cents
    ) VALUES (
        p_game_id,
        p_user_id,
        v_status::booking_status,
        v_waitlist_pos,
        p_fee_paid,
        p_stripe_pi_id,
        p_payment_method,
        p_platform_fee_cents,
        p_club_payout_cents,
        p_credits_applied_cents
    )
    RETURNING bookings.id INTO v_booking_id;

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

GRANT EXECUTE ON FUNCTION book_game(UUID, UUID, BOOLEAN, TEXT, TEXT, INT, INT, INT) TO authenticated;
