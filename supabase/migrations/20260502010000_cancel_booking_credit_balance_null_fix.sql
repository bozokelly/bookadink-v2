-- cancel_booking_with_credit: fix `new_balance_cents` returning NULL when the
-- user has no player_credits row for the club.
--
-- The original migration (20260427_cancel_booking_with_credit.sql) ended with:
--
--     SELECT COALESCE(pc.amount_cents, 0)
--     INTO   v_new_balance
--     FROM   player_credits pc
--     WHERE  pc.user_id  = auth.uid()
--       AND  pc.club_id  = v_club_id
--       AND  pc.currency = 'aud';
--
-- That COALESCE only protects against amount_cents being NULL *within* an
-- existing row. PL/pgSQL `SELECT INTO` with zero matched rows assigns NULL to
-- the target variable — overriding the `v_new_balance INT := 0` default. So
-- any cancel by a user who has never had credits at that club (free game
-- cancel, admin-booking cancel, ineligible-window cancel) returned a row of
--
--     (credit_issued_cents=0, was_eligible=…, new_balance_cents=NULL)
--
-- iOS decodes `new_balance_cents` as a non-optional Int and fails with
-- "Failed to decode Supabase response: The data couldn't be read because it
-- is missing". The booking row is already cancelled by the time RETURN QUERY
-- runs, so the user sees the cancel "fail" but the seat actually freed —
-- waitlist promotion still fires correctly via the trigger.
--
-- Fix: wrap the SELECT in a subquery COALESCE so `v_new_balance` is reliably
-- 0 when no row matches. Function signature, return shape, and trigger
-- behaviour are unchanged.

CREATE OR REPLACE FUNCTION cancel_booking_with_credit(p_booking_id UUID)
RETURNS TABLE(credit_issued_cents INT, was_eligible BOOL, new_balance_cents INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_booking       bookings%ROWTYPE;
    v_game_dt       TIMESTAMPTZ;
    v_club_id       UUID;
    v_refund_cents  INT := 0;
    v_new_balance   INT := 0;
    v_eligible      BOOL := false;
BEGIN
    -- Lock the booking row and verify the caller owns it.
    SELECT b.* INTO v_booking
    FROM   bookings b
    WHERE  b.id      = p_booking_id
      AND  b.user_id = auth.uid()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking_not_found' USING ERRCODE = 'P0002';
    END IF;

    -- Only cancellable statuses. Cast to ::text — booking_status is a PG enum and
    -- direct string comparison in IN() raises 22P02 (see CLAUDE.md).
    IF v_booking.status::text NOT IN ('confirmed', 'pending_payment', 'waitlisted') THEN
        RAISE EXCEPTION 'not_cancellable' USING ERRCODE = 'P0002';
    END IF;

    -- Resolve game date and club for window check and credit scope.
    SELECT g.date_time, g.club_id
    INTO   v_game_dt, v_club_id
    FROM   games g
    WHERE  g.id = v_booking.game_id;

    -- Cancel the booking.
    UPDATE bookings
    SET    status = 'cancelled'::booking_status
    WHERE  id = p_booking_id;

    -- 6-hour cancellation window.
    v_eligible := v_game_dt > NOW() + INTERVAL '6 hours';

    IF v_eligible THEN
        -- Refund policy:
        --   • Stripe-paid:   platform_fee + club_payout + credits_applied
        --   • Credit-only:   credits_applied
        --   • Free/admin:    0
        IF v_booking.fee_paid THEN
            v_refund_cents := COALESCE(v_booking.platform_fee_cents,   0)
                           + COALESCE(v_booking.club_payout_cents,     0)
                           + COALESCE(v_booking.credits_applied_cents, 0);
        ELSIF COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
            v_refund_cents := v_booking.credits_applied_cents;
        END IF;

        -- Atomic upsert — no read-modify-write race.
        IF v_refund_cents > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (auth.uid(), v_club_id, v_refund_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
        END IF;
    END IF;

    -- Authoritative new balance. Subquery + COALESCE so v_new_balance stays 0
    -- when no player_credits row exists for this user/club/currency. The
    -- previous form (`SELECT … INTO v_new_balance FROM player_credits WHERE …`)
    -- assigned NULL on zero rows because PL/pgSQL `SELECT INTO` overrides the
    -- variable's default initialiser whether or not a row matches.
    v_new_balance := COALESCE(
        (SELECT pc.amount_cents
         FROM   player_credits pc
         WHERE  pc.user_id  = auth.uid()
           AND  pc.club_id  = v_club_id
           AND  pc.currency = 'aud'),
        0
    );

    RETURN QUERY SELECT v_refund_cents, v_eligible, v_new_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION cancel_booking_with_credit(UUID) TO authenticated;
