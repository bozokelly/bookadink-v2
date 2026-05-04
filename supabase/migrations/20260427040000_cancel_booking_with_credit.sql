-- cancel_booking_with_credit: atomically cancels a player's own booking and issues
-- a credit refund when within the eligible window (> 6 hours before the game starts).
--
-- Replaces the iOS client-side pattern of:
--   1. PATCH bookings status → cancelled
--   2. Client computes 6h window + refund amount
--   3. GET player_credits → PATCH/INSERT (read-modify-write with race window)
--
-- This function holds a FOR UPDATE lock on the booking row for the duration, so
-- concurrent calls for the same booking are serialised and the credit upsert is
-- atomic (INSERT ... ON CONFLICT DO UPDATE with no intermediate read).
--
-- Returns one row: (credit_issued_cents INT, was_eligible BOOL, new_balance_cents INT)

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
        -- Mirror the refund policy from the original iOS client:
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

    -- Return the authoritative new balance so the client does not need a second fetch.
    SELECT COALESCE(pc.amount_cents, 0)
    INTO   v_new_balance
    FROM   player_credits pc
    WHERE  pc.user_id  = auth.uid()
      AND  pc.club_id  = v_club_id
      AND  pc.currency = 'aud';

    RETURN QUERY SELECT v_refund_cents, v_eligible, v_new_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION cancel_booking_with_credit(UUID) TO authenticated;
