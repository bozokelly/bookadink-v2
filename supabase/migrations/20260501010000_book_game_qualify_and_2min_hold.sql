-- Fix: book_game() column ambiguity (42702) + restore DUPR gate + 2-min hold (test).
--
-- WHY:
--   A previous edit replaced book_game with an unqualified body. Because
--   RETURNS TABLE(... id UUID, game_id UUID, user_id UUID, status TEXT,
--   waitlist_position INT ...) makes those names OUT variables in the function's
--   PL/pgSQL scope, any unqualified reference inside the body raised
--   `42702 column reference "X" is ambiguous` at execution time, breaking
--   bookings on free and paid games alike. Same shadowing class as the
--   members-only-gate bug fixed earlier (memory 1873/1881).
--
-- WHAT THIS MIGRATION DOES:
--   1. Qualifies every column reference inside the function body with a table
--      alias (b.*, g.*, p.*) so no name collides with the OUT variables.
--      The INSERT column list is unambiguous and does not need qualification.
--   2. Restores the server-authoritative DUPR gate (was accidentally dropped
--      in the previous edit) — `requires_dupr = true` games still raise
--      'dupr_required' for callers without a valid `profiles.dupr_id`.
--   3. Sets v_hold_mins to 2 minutes — TEMPORARY, for waitlist promotion
--      testing only. Must be returned to 30 (matching AppState and the cron
--      function) before production ship.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE + idempotent GRANT.

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
    v_hold_mins     CONSTANT INT := 2;   -- TEMP: testing waitlist promotion. Revert to 30 before ship.
    v_caller_dupr   TEXT;
BEGIN
    -- Lock the game row to prevent concurrent over-booking.
    -- Read requires_dupr alongside max_spots so the DUPR check is consistent
    -- with the capacity snapshot taken under the same lock.
    SELECT g.max_spots, COALESCE(g.requires_dupr, FALSE)
    INTO   v_max_spots, v_requires_dupr
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- DUPR gate: caller must have a stored DUPR ID when the game requires it.
    -- Applies to confirmed spots and waitlist joins alike.
    IF v_requires_dupr THEN
        SELECT trim(p.dupr_id)
        INTO   v_caller_dupr
        FROM   profiles p
        WHERE  p.id = p_user_id;

        IF v_caller_dupr IS NULL OR length(v_caller_dupr) < 6 THEN
            RAISE EXCEPTION 'dupr_required';
        END IF;
    END IF;

    -- Count active seats. Both `confirmed` and `pending_payment` physically
    -- hold a seat — the invariant is `confirmed + pending_payment <= max_spots`.
    SELECT COUNT(*) INTO v_confirmed_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_confirmed_cnt >= v_max_spots THEN
        -- Game is full — place on waitlist regardless of hold flag.
        SELECT COALESCE(MAX(b.waitlist_position), 0) + 1
        INTO   v_waitlist_pos
        FROM   bookings b
        WHERE  b.game_id      = p_game_id
          AND  b.status::text = 'waitlisted';

        v_status := 'waitlisted';
    ELSE
        -- Spot available. When the caller requests a payment hold (paid fresh
        -- booking), use pending_payment so the Stripe PI can be scoped to this
        -- booking_id and the cron job can revert it if payment never lands.
        v_waitlist_pos := NULL;
        v_status := CASE WHEN p_hold_for_payment THEN 'pending_payment' ELSE 'confirmed' END;
    END IF;

    -- INSERT column list refers to the bookings table directly; OUT variable
    -- shadowing does not apply to the column list — only to expressions in
    -- WHERE / SELECT / UPDATE / DELETE / SET clauses.
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
