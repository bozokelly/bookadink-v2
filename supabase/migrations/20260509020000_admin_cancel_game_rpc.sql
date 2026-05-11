-- Admin game cancellation with paid-player credit issuance.
--
-- Today the admin cancel/delete game path only flips games.status='cancelled'
-- (cancel) or hard-deletes the games row (delete). Bookings are not cascaded
-- and paid players receive ZERO credit. This RPC plugs the gap:
--
--   • Cancels every active booking (waitlisted, pending_payment, confirmed)
--     for the game in a single transaction.
--   • Issues refund credits to the original player for every cancelled
--     booking, mirroring `cancel_booking_with_credit`'s math:
--       Stripe-paid:  platform_fee + club_payout + credits_applied
--       Credit-only:  credits_applied
--       Free/admin:   0
--   • Honours `clubs.cancellation_policy_type='club_managed'` — those clubs
--     never receive credit (refunds handled off-platform), the bookings are
--     still cancelled. Mirrors the existing self-cancel RPC's behaviour.
--   • Skips the per-club cutoff window. Admin-initiated cancellation always
--     gives full refund regardless of how close to the game start it lands —
--     the cutoff exists to prevent abusive last-minute self-cancels, not to
--     punish players when the club itself cancels.
--   • Idempotent: re-running on an already-cancelled game returns zeros
--     because the WHERE clauses filter on active statuses only and
--     player_credits has UNIQUE (user_id, club_id, currency).
--
-- Cancellation order is significant. Waitlisted bookings are cancelled FIRST
-- so the `trg_promote_top_waitlisted` trigger (fires on confirmed→cancelled)
-- has no waitlister to promote when we later cancel confirmed seats. Without
-- this ordering the trigger would shuffle players into a game that is itself
-- being cancelled.

CREATE OR REPLACE FUNCTION admin_cancel_game(p_game_id UUID)
RETURNS TABLE(
    bookings_cancelled INT,
    paid_bookings_credited INT,
    total_credits_cents INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller        UUID := auth.uid();
    v_game          RECORD;
    v_club          RECORD;
    v_authorized    BOOLEAN;
    v_managed       BOOLEAN;
    v_booking       RECORD;
    v_refund_cents  INT;
    v_total_credits INT := 0;
    v_paid_count    INT := 0;
    v_total_count   INT := 0;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required' USING ERRCODE = 'P0001';
    END IF;

    -- Lock the game so concurrent admin actions / book_game calls serialize.
    SELECT g.id, g.club_id, g.status, g.date_time
    INTO   v_game
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found' USING ERRCODE = 'P0002';
    END IF;

    SELECT c.id, c.created_by, c.cancellation_policy_type
    INTO   v_club
    FROM   clubs c
    WHERE  c.id = v_game.club_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'club_not_found' USING ERRCODE = 'P0002';
    END IF;

    -- Owner OR admin allowed. Mirrors the games DELETE / UPDATE RLS policy.
    v_authorized :=
        (v_club.created_by = v_caller)
        OR EXISTS (
            SELECT 1 FROM club_admins ca
            WHERE  ca.club_id = v_club.id AND ca.user_id = v_caller
        );

    IF NOT v_authorized THEN
        RAISE EXCEPTION 'forbidden_owner_or_admin_only' USING ERRCODE = 'P0001';
    END IF;

    -- Idempotency: already cancelled. Return zeros so iOS retries / double-tap
    -- don't double-credit.
    IF v_game.status = 'cancelled' THEN
        RAISE LOG 'admin_cancel_game: already cancelled game=% caller=%', p_game_id, v_caller;
        RETURN QUERY SELECT 0::INT, 0::INT, 0::INT;
        RETURN;
    END IF;

    v_managed := (COALESCE(v_club.cancellation_policy_type, 'managed') = 'club_managed');

    -- Mark the game cancelled FIRST so any downstream observers see the
    -- definitive game state. Booking-level triggers below operate within the
    -- same transaction so atomicity is preserved.
    UPDATE games SET status = 'cancelled' WHERE id = p_game_id;

    -- Phase 1: cancel waitlisted bookings. trg_compact_waitlist_on_leave
    -- fires for each but no-ops harmlessly. trg_promote_top_waitlisted does
    -- NOT fire (it only watches confirmed→cancelled).
    UPDATE bookings b
    SET    status = 'cancelled'::booking_status
    WHERE  b.game_id = p_game_id
      AND  b.status::text = 'waitlisted';
    GET DIAGNOSTICS v_total_count = ROW_COUNT;

    -- Phase 2: cancel pending_payment bookings. These never went through
    -- Stripe so platform_fee / club_payout are zero — only credits_applied
    -- (if any) come back. Loop because we may need to refund credits.
    FOR v_booking IN
        SELECT b.id, b.user_id, b.fee_paid,
               b.platform_fee_cents, b.club_payout_cents, b.credits_applied_cents
        FROM   bookings b
        WHERE  b.game_id = p_game_id
          AND  b.status::text = 'pending_payment'
        FOR UPDATE
    LOOP
        UPDATE bookings SET status = 'cancelled'::booking_status WHERE id = v_booking.id;
        v_total_count := v_total_count + 1;

        IF NOT v_managed AND COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (v_booking.user_id, v_game.club_id, v_booking.credits_applied_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
            v_total_credits := v_total_credits + v_booking.credits_applied_cents;
        END IF;
    END LOOP;

    -- Phase 3: cancel confirmed bookings. Refund math mirrors
    -- cancel_booking_with_credit.  At this point Phase 1 already cleared
    -- the waitlist queue, so trg_promote_top_waitlisted finds nobody to
    -- promote and is a safe no-op per cancellation.
    FOR v_booking IN
        SELECT b.id, b.user_id, b.fee_paid, b.payment_method,
               b.platform_fee_cents, b.club_payout_cents, b.credits_applied_cents
        FROM   bookings b
        WHERE  b.game_id = p_game_id
          AND  b.status::text = 'confirmed'
        FOR UPDATE
    LOOP
        UPDATE bookings SET status = 'cancelled'::booking_status WHERE id = v_booking.id;
        v_total_count := v_total_count + 1;

        IF v_managed THEN
            v_refund_cents := 0;
        ELSIF v_booking.fee_paid THEN
            v_refund_cents := COALESCE(v_booking.platform_fee_cents,   0)
                           +  COALESCE(v_booking.club_payout_cents,     0)
                           +  COALESCE(v_booking.credits_applied_cents, 0);
        ELSIF COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
            v_refund_cents := v_booking.credits_applied_cents;
        ELSE
            v_refund_cents := 0;
        END IF;

        IF v_refund_cents > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (v_booking.user_id, v_game.club_id, v_refund_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
            v_total_credits := v_total_credits + v_refund_cents;
            IF v_booking.fee_paid THEN
                v_paid_count := v_paid_count + 1;
            END IF;
        END IF;
    END LOOP;

    RAISE LOG 'admin_cancel_game: game=% club=% caller=% bookings_cancelled=% paid_credited=% credits_cents=% managed=%',
        p_game_id, v_game.club_id, v_caller, v_total_count, v_paid_count, v_total_credits, v_managed;

    RETURN QUERY SELECT v_total_count, v_paid_count, v_total_credits;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_cancel_game(UUID) TO authenticated;

COMMENT ON FUNCTION admin_cancel_game(UUID) IS
'Admin-initiated game cancellation. Cancels all active bookings (waitlisted, pending_payment, confirmed) for the game and issues refund credits to paid players using cancel_booking_with_credit''s math. Caller must be the club owner or a club_admins row. Honours cancellation_policy_type=''club_managed'' (no credit). Skips per-club cutoff window — admin cancellation always refunds full amount. Idempotent on already-cancelled games. Returns (bookings_cancelled, paid_bookings_credited, total_credits_cents).';
