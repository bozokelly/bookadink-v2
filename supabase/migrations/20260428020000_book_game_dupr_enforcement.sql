-- Server-authoritative DUPR gate in book_game.
--
-- PROBLEM:
--   games.requires_dupr = true was enforced only by iOS client logic.
--   Android, web, and direct API callers could bypass the check entirely.
--
-- SOLUTION:
--   1. Add profiles.dupr_id TEXT NULL — stores the player's DUPR player ID string.
--      iOS persists this at DUPR ID save time; the field is the authoritative
--      source for the server check (not dupr_rating which is numeric).
--   2. book_game() reads requires_dupr alongside max_spots (within the FOR UPDATE
--      lock). If requires_dupr = true and the caller has no valid dupr_id, raises
--      'dupr_required'. iOS, Android, and web all receive this string and surface
--      the appropriate UX message.
--
-- ADMIN BYPASS (intentional):
--   ownerCreateBooking (direct bookings INSERT via PostgREST) bypasses book_game().
--   Club owners/admins manually adding players may legitimately override DUPR
--   requirements — this is the correct and intended behaviour.
--
-- UNCHANGED BEHAVIOUR:
--   All existing callers omit no new parameters. Return shape is unchanged.
--   free games, waitlisted games, paid games — all paths unchanged except the
--   new early-return guard.
--
-- SAFE TO RE-RUN: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE, GRANT is idempotent.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS dupr_id TEXT NULL;

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
    v_requires_dupr BOOL;
    v_confirmed_cnt INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID := gen_random_uuid();
    v_hold_mins     CONSTANT INT := 30;
    v_caller_dupr   TEXT;
BEGIN
    -- Lock the game row to prevent concurrent over-booking.
    -- Read requires_dupr here so the DUPR check is consistent with capacity state.
    SELECT max_spots, COALESCE(requires_dupr, FALSE)
    INTO   v_max_spots, v_requires_dupr
    FROM   games
    WHERE  games.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- DUPR gate: caller must have a stored DUPR ID when the game requires it.
    -- This applies to both confirmed spots and waitlist joins — a player without
    -- a DUPR ID cannot hold a spot they would be unable to activate.
    IF v_requires_dupr THEN
        SELECT trim(dupr_id)
        INTO   v_caller_dupr
        FROM   profiles
        WHERE  id = p_user_id;

        IF v_caller_dupr IS NULL OR length(v_caller_dupr) < 6 THEN
            RAISE EXCEPTION 'dupr_required';
        END IF;
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

GRANT EXECUTE ON FUNCTION book_game(UUID, UUID, BOOLEAN, TEXT, TEXT, INT, INT, INT, BOOLEAN) TO authenticated;
