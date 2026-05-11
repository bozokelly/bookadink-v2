-- admin_cancel_game — re-publish with per-booking audit logging.
--
-- Issue reported: when the admin/owner is also a paid participant on the game
-- they cancel, their own paid booking sometimes appeared not to be credited.
--
-- Source-level audit confirmed there is no caller-exclusion filter in this
-- function: Phase 3 selects every confirmed booking via
--   WHERE game_id = p_game_id AND status = 'confirmed'
-- with no auth.uid() predicate, no `user_id <> v_caller` clause, and no
-- club-admin join that would drop the caller's row. The credit upsert uses
-- `v_booking.user_id` (the booking's owner) so the caller's own booking is
-- treated identically to any other player's booking. SECURITY DEFINER also
-- bypasses RLS so player_credits writes succeed for any user_id.
--
-- This migration:
--   • Re-publishes the function with byte-identical eligibility logic, in
--     case the live function diverged from the source via a SQL Editor edit.
--   • Adds RAISE LOG lines per credit decision so the next reproducer leaves
--     a trace in Postgres logs (Supabase → Logs → Postgres, search
--     `admin_cancel_game:`). Each log line includes booking_id, user_id,
--     fee_paid, payment_method, credits_applied, computed refund, and a
--     `is_caller` flag — answering "did the caller's own booking get
--     credited" without needing to inspect data.
--
-- What this migration does NOT change:
--   • Eligibility logic is unchanged.
--   • Idempotency (status filter + UNIQUE on player_credits) is unchanged.
--   • club_managed behaviour (no credit) is unchanged.
--   • Self-cancel `cancel_booking_with_credit` is untouched.
--   • promote_top_waitlisted trigger is untouched.
--
-- Reading the audit log:
--   • `decision=credited` — booking refunded; check user_id matches caller.
--   • `decision=skip_managed` — credit suppressed by club_managed policy.
--   • `decision=skip_zero` — booking's fee columns and credits_applied were
--     all 0/NULL. This is the case for admin-added comp bookings (those
--     created via owner_create_booking with payment_method='admin' and
--     fee_paid=FALSE) — they got a free seat, no money to refund.

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
    v_is_caller     BOOLEAN;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required' USING ERRCODE = 'P0001';
    END IF;

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
    -- Note: this gate authorizes the CALLER, it does NOT filter which
    -- bookings get credited below. The credit loops walk every active
    -- booking on the game regardless of caller identity.
    v_authorized :=
        (v_club.created_by = v_caller)
        OR EXISTS (
            SELECT 1 FROM club_admins ca
            WHERE  ca.club_id = v_club.id AND ca.user_id = v_caller
        );

    IF NOT v_authorized THEN
        RAISE EXCEPTION 'forbidden_owner_or_admin_only' USING ERRCODE = 'P0001';
    END IF;

    -- Idempotency: already cancelled.
    IF v_game.status = 'cancelled' THEN
        RAISE LOG 'admin_cancel_game: already cancelled game=% caller=%', p_game_id, v_caller;
        RETURN QUERY SELECT 0::INT, 0::INT, 0::INT;
        RETURN;
    END IF;

    v_managed := (COALESCE(v_club.cancellation_policy_type, 'managed') = 'club_managed');

    UPDATE games SET status = 'cancelled' WHERE id = p_game_id;

    -- Phase 1: cancel waitlisted bookings (no credit owed — they paid nothing
    -- and credits_applied is always 0 on a waitlist row). Done first so the
    -- promote_top_waitlisted trigger has nothing to promote when confirmed
    -- seats cancel below.
    UPDATE bookings b
    SET    status = 'cancelled'::booking_status
    WHERE  b.game_id = p_game_id
      AND  b.status::text = 'waitlisted';
    GET DIAGNOSTICS v_total_count = ROW_COUNT;

    -- Phase 2: cancel pending_payment bookings. Refund credits_applied (if
    -- any) — these never went through Stripe so platform_fee/club_payout
    -- are always zero.
    FOR v_booking IN
        SELECT b.id, b.user_id, b.fee_paid, b.payment_method,
               b.platform_fee_cents, b.club_payout_cents, b.credits_applied_cents
        FROM   bookings b
        WHERE  b.game_id = p_game_id
          AND  b.status::text = 'pending_payment'
        FOR UPDATE
    LOOP
        UPDATE bookings SET status = 'cancelled'::booking_status WHERE id = v_booking.id;
        v_total_count := v_total_count + 1;
        v_is_caller := (v_booking.user_id = v_caller);

        IF v_managed THEN
            RAISE LOG 'admin_cancel_game: phase=pending_payment booking=% user=% is_caller=% decision=skip_managed',
                v_booking.id, v_booking.user_id, v_is_caller;
        ELSIF COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (v_booking.user_id, v_game.club_id, v_booking.credits_applied_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
            v_total_credits := v_total_credits + v_booking.credits_applied_cents;
            RAISE LOG 'admin_cancel_game: phase=pending_payment booking=% user=% is_caller=% decision=credited credits_applied=% refund=%',
                v_booking.id, v_booking.user_id, v_is_caller,
                v_booking.credits_applied_cents, v_booking.credits_applied_cents;
        ELSE
            RAISE LOG 'admin_cancel_game: phase=pending_payment booking=% user=% is_caller=% decision=skip_zero credits_applied=0',
                v_booking.id, v_booking.user_id, v_is_caller;
        END IF;
    END LOOP;

    -- Phase 3: cancel confirmed bookings. This is where the admin's own
    -- paid booking lands — same loop, same math, same upsert as every
    -- other player. Refund math mirrors cancel_booking_with_credit.
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
        v_is_caller := (v_booking.user_id = v_caller);

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

        IF v_managed THEN
            RAISE LOG 'admin_cancel_game: phase=confirmed booking=% user=% is_caller=% decision=skip_managed fee_paid=% payment_method=%',
                v_booking.id, v_booking.user_id, v_is_caller,
                v_booking.fee_paid, v_booking.payment_method;
        ELSIF v_refund_cents > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (v_booking.user_id, v_game.club_id, v_refund_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
            v_total_credits := v_total_credits + v_refund_cents;
            IF v_booking.fee_paid THEN
                v_paid_count := v_paid_count + 1;
            END IF;
            RAISE LOG 'admin_cancel_game: phase=confirmed booking=% user=% is_caller=% decision=credited fee_paid=% payment_method=% platform_fee=% club_payout=% credits_applied=% refund=%',
                v_booking.id, v_booking.user_id, v_is_caller,
                v_booking.fee_paid, v_booking.payment_method,
                COALESCE(v_booking.platform_fee_cents, 0),
                COALESCE(v_booking.club_payout_cents, 0),
                COALESCE(v_booking.credits_applied_cents, 0),
                v_refund_cents;
        ELSE
            -- decision=skip_zero is the canonical "comp seat" footprint:
            -- payment_method='admin' bookings created by owner_create_booking
            -- have fee_paid=FALSE and credits_applied=0, so no money was ever
            -- paid for this booking and no credit is owed. If the caller is
            -- surprised by this, check booking.payment_method in the log line.
            RAISE LOG 'admin_cancel_game: phase=confirmed booking=% user=% is_caller=% decision=skip_zero fee_paid=% payment_method=% platform_fee=% club_payout=% credits_applied=%',
                v_booking.id, v_booking.user_id, v_is_caller,
                v_booking.fee_paid, v_booking.payment_method,
                COALESCE(v_booking.platform_fee_cents, 0),
                COALESCE(v_booking.club_payout_cents, 0),
                COALESCE(v_booking.credits_applied_cents, 0);
        END IF;
    END LOOP;

    RAISE LOG 'admin_cancel_game: game=% club=% caller=% bookings_cancelled=% paid_credited=% credits_cents=% managed=%',
        p_game_id, v_game.club_id, v_caller, v_total_count, v_paid_count, v_total_credits, v_managed;

    RETURN QUERY SELECT v_total_count, v_paid_count, v_total_credits;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_cancel_game(UUID) TO authenticated;

COMMENT ON FUNCTION admin_cancel_game(UUID) IS
'Admin-initiated game cancellation. Cancels every active booking (waitlisted, pending_payment, confirmed) and issues refund credits to ALL eligible bookings — including the caller''s own — using cancel_booking_with_credit''s math. Eligibility depends ONLY on booking/payment state: a booking qualifies for credit when fee_paid=TRUE OR credits_applied_cents > 0, regardless of whether booking.user_id equals auth.uid(). The caller-auth gate is independent of the credit loop. Honours cancellation_policy_type=''club_managed''. Idempotent on already-cancelled games. Per-booking decisions are RAISE LOGged for tracing — search Postgres logs for `admin_cancel_game: phase=` to see which bookings were credited or skipped (and why).';
