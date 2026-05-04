-- Add p_hold_for_payment to book_game.
--
-- PROBLEM:
--   Fresh paid bookings were creating a Stripe PaymentIntent BEFORE a booking row
--   existed in the DB.  The idempotency key was scoped to the game, not the player,
--   so multiple users (or the same user re-booking after cancel) received the SAME
--   already-charged PI → paymentIntentInTerminalState on PaymentSheet load.
--
-- SOLUTION:
--   Pass p_hold_for_payment = TRUE from iOS preparePaymentSheet.
--   book_game creates a `pending_payment` booking with hold_expires_at = now() + 30min.
--   iOS then calls create-payment-intent; Gate 0.5 finds the pending_payment booking
--   and uses pi-{booking_id}-{amount} as the idempotency key.
--   Each player's booking gets a unique, never-reused Stripe PI.
--   iOS completes the flow via confirmPendingBooking — the same path waitlist
--   promotions already use.
--
-- UNCHANGED BEHAVIOUR:
--   All existing callers omit p_hold_for_payment (defaults FALSE) so they continue to
--   receive `confirmed` or `waitlisted` status exactly as before.
--   The pending_payment hold lifecycle (expiry cron, position compaction, promote
--   trigger) is identical to the waitlist-promotion path.
--
-- HOLD CONSTANT:
--   v_hold_mins = 30 matches AppState.waitlistHoldMinutes and the value used by
--   promote_waitlist_player / revert_expired_holds_and_repromote.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE, GRANT is idempotent.

CREATE OR REPLACE FUNCTION book_game(
    p_game_id               UUID,
    p_user_id               UUID,
    p_fee_paid              BOOLEAN  DEFAULT FALSE,
    p_stripe_pi_id          TEXT     DEFAULT NULL,
    p_payment_method        TEXT     DEFAULT NULL,
    p_platform_fee_cents    INT      DEFAULT NULL,
    p_club_payout_cents     INT      DEFAULT NULL,
    p_credits_applied_cents INT      DEFAULT NULL,
    p_hold_for_payment      BOOLEAN  DEFAULT FALSE
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
    v_max_spots     INT;
    v_confirmed_cnt INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID := gen_random_uuid();
    v_hold_mins     CONSTANT INT := 30;
BEGIN
    -- Lock the game row to prevent concurrent over-booking.
    SELECT max_spots
    INTO   v_max_spots
    FROM   games
    WHERE  games.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Count active seats (confirmed + pending_payment both hold a physical spot).
    SELECT COUNT(*) INTO v_confirmed_cnt
    FROM   bookings
    WHERE  game_id = p_game_id
      AND  status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_confirmed_cnt >= v_max_spots THEN
        -- Game is full — place on waitlist regardless of hold flag.
        SELECT COALESCE(MAX(waitlist_position), 0) + 1 INTO v_waitlist_pos
        FROM   bookings
        WHERE  game_id = p_game_id
          AND  status::text = 'waitlisted';

        v_status := 'waitlisted';
    ELSE
        -- Spot available.
        v_waitlist_pos := NULL;
        -- When the caller requests a payment hold (paid fresh booking), use
        -- pending_payment so the Stripe PI can be scoped to this booking_id.
        v_status := CASE WHEN p_hold_for_payment THEN 'pending_payment' ELSE 'confirmed' END;
    END IF;

    INSERT INTO bookings (
        id,
        game_id,
        user_id,
        status,
        waitlist_position,
        fee_paid,
        stripe_payment_intent_id,
        payment_method,
        platform_fee_cents,
        club_payout_cents,
        credits_applied_cents,
        hold_expires_at
    ) VALUES (
        v_booking_id,
        p_game_id,
        p_user_id,
        v_status::booking_status,
        v_waitlist_pos,
        p_fee_paid,
        p_stripe_pi_id,
        p_payment_method,
        p_platform_fee_cents,
        p_club_payout_cents,
        p_credits_applied_cents,
        CASE WHEN v_status = 'pending_payment'
             THEN now() + (v_hold_mins || ' minutes')::INTERVAL
             ELSE NULL
        END
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

-- 20260427_book_game_fix_max_spots.sql (runs before this migration alphabetically) already
-- dropped the old 8-param signature, so GRANT only covers the canonical 9-param form.
GRANT EXECUTE ON FUNCTION book_game(UUID, UUID, BOOLEAN, TEXT, TEXT, INT, INT, INT, BOOLEAN) TO authenticated;
