-- Credits & Cancellation Policy — server-authoritative enforcement
--
-- Changes:
--   1. Add credit_refund_issued_at to bookings for idempotency
--   2. Drop old 3-arg issue_cancellation_credit (client-side amount param removed)
--   3. Recreate issue_cancellation_credit as a 2-arg, fully server-authoritative RPC:
--      - Enforces 6h cancellation window
--      - Computes refund amount from booking record (no client trust)
--      - Idempotent via credit_refund_issued_at
--      - Issues credits only (no Stripe refunds ever)
--
-- Safe to re-run: CREATE OR REPLACE + ADD COLUMN IF NOT EXISTS + DROP IF EXISTS.

-- 1. Idempotency guard column
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS credit_refund_issued_at TIMESTAMPTZ NULL;

-- 2. Drop old client-amount version (different signature = different overload in PG)
DROP FUNCTION IF EXISTS issue_cancellation_credit(UUID, UUID, INT);

-- 3. Server-authoritative 6h-policy, idempotent credit refund
CREATE OR REPLACE FUNCTION issue_cancellation_credit(
  p_user_id    UUID,
  p_booking_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking  bookings%ROWTYPE;
  v_game     games%ROWTYPE;
  v_refund   INT;
BEGIN
  -- Lock booking row to prevent concurrent double-issue
  SELECT * INTO v_booking
  FROM   bookings
  WHERE  id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  -- Idempotency: already issued for this booking
  IF v_booking.credit_refund_issued_at IS NOT NULL THEN RETURN; END IF;

  -- Only refund cancelled bookings
  IF v_booking.status::text != 'cancelled' THEN RETURN; END IF;

  -- Look up the game for the policy check
  SELECT * INTO v_game FROM games WHERE id = v_booking.game_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- 6h policy: only issue credit when game starts > 6 hours from now
  IF v_game.date_time <= (NOW() AT TIME ZONE 'UTC') + INTERVAL '6 hours' THEN
    RETURN;
  END IF;

  -- Compute refund server-side from the booking record.
  -- Card-paid bookings: full amount back as credits (platform_fee + club_payout + any credits applied).
  -- Credit-only bookings: return credits_applied_cents.
  -- Free / admin-added: nothing.
  v_refund := CASE
    WHEN COALESCE(v_booking.fee_paid, false) = true THEN
      COALESCE(v_booking.platform_fee_cents,    0) +
      COALESCE(v_booking.club_payout_cents,     0) +
      COALESCE(v_booking.credits_applied_cents, 0)
    WHEN COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
      v_booking.credits_applied_cents
    ELSE
      0
  END;

  IF v_refund <= 0 THEN RETURN; END IF;

  -- Credit the user's balance
  INSERT INTO player_credits (user_id, amount_cents, currency)
    VALUES (p_user_id, v_refund, 'aud')
  ON CONFLICT (user_id, currency)
  DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;

  -- Mark issued — prevents any future duplicate call from running
  UPDATE bookings
  SET    credit_refund_issued_at = NOW()
  WHERE  id = p_booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION issue_cancellation_credit(UUID, UUID) TO authenticated;
