-- Credits System Bootstrap
--
-- Run this FIRST (before or instead of the earlier credits migrations).
-- Safe to re-run: all statements are IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS.
--
-- What this sets up:
--   1. player_credits table (club-scoped balances)
--   2. credit_refund_issued_at column on bookings (idempotency guard)
--   3. use_credits(user_id, booking_id, amount_cents, club_id) RPC
--   4. issue_cancellation_credit(user_id, booking_id) RPC
--      — server-authoritative, 6h policy, derives club_id from booking → game
--   5. RLS policies on player_credits

-- ─────────────────────────────────────────────
-- 1. player_credits table
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS player_credits (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  club_id      UUID NOT NULL REFERENCES clubs(id)      ON DELETE CASCADE,
  amount_cents INT  NOT NULL DEFAULT 0 CHECK (amount_cents >= 0),
  currency     TEXT NOT NULL DEFAULT 'aud',
  CONSTRAINT player_credits_user_club_currency_key UNIQUE (user_id, club_id, currency)
);

ALTER TABLE player_credits ENABLE ROW LEVEL SECURITY;

-- Users can read their own credit balances
DROP POLICY IF EXISTS "Users can read own credits" ON player_credits;
CREATE POLICY "Users can read own credits"
  ON player_credits FOR SELECT
  USING (auth.uid() = user_id);

-- ─────────────────────────────────────────────
-- 2. Idempotency guard on bookings
-- ─────────────────────────────────────────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS credit_refund_issued_at TIMESTAMPTZ NULL;

-- ─────────────────────────────────────────────
-- 3. use_credits RPC
--    Atomically deducts amount_cents from the user's balance at a specific club.
--    Returns TRUE on success, FALSE if insufficient balance.
-- ─────────────────────────────────────────────
DROP FUNCTION IF EXISTS use_credits(UUID, UUID, INT);
DROP FUNCTION IF EXISTS use_credits(UUID, UUID, INT, UUID);

CREATE OR REPLACE FUNCTION use_credits(
  p_user_id      UUID,
  p_booking_id   UUID,
  p_amount_cents INT,
  p_club_id      UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance INT;
BEGIN
  -- Lock the row to prevent concurrent double-spend
  SELECT amount_cents INTO v_balance
  FROM   player_credits
  WHERE  user_id = p_user_id AND club_id = p_club_id AND currency = 'aud'
  FOR UPDATE;

  IF NOT FOUND OR v_balance < p_amount_cents THEN
    RETURN FALSE;
  END IF;

  UPDATE player_credits
  SET    amount_cents = amount_cents - p_amount_cents,
         updated_at   = now()
  WHERE  user_id = p_user_id AND club_id = p_club_id AND currency = 'aud';

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION use_credits(UUID, UUID, INT, UUID) TO authenticated;

-- ─────────────────────────────────────────────
-- 4. issue_cancellation_credit RPC
--    Server-authoritative: 6h policy, amount derived from booking record,
--    club derived from booking → game, idempotent via credit_refund_issued_at.
-- ─────────────────────────────────────────────
DROP FUNCTION IF EXISTS issue_cancellation_credit(UUID, UUID, INT);
DROP FUNCTION IF EXISTS issue_cancellation_credit(UUID, UUID);

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
  -- Lock booking to prevent concurrent double-issue
  SELECT * INTO v_booking
  FROM   bookings
  WHERE  id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  -- Already issued — idempotency guard
  IF v_booking.credit_refund_issued_at IS NOT NULL THEN RETURN; END IF;

  -- Cast to text — booking_status is a PG enum; comparing directly against
  -- a non-member string ('canceled') raises 22P02 invalid input value for enum.
  IF v_booking.status::text != 'cancelled' THEN RETURN; END IF;

  -- Resolve game for club_id and 6h policy check
  SELECT * INTO v_game FROM games WHERE id = v_booking.game_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- 6h cancellation window: game must start more than 6h from now
  IF v_game.date_time <= (NOW() AT TIME ZONE 'UTC') + INTERVAL '6 hours' THEN
    RETURN;
  END IF;

  -- Compute refund entirely server-side from the booking record.
  --
  -- Stripe-paid booking: full amount back as credits.
  --   platform_fee_cents + club_payout_cents = total charged to card.
  --   credits_applied_cents = any credits that topped up the payment.
  -- Credit-only booking (fee_paid = false, credits_applied_cents > 0):
  --   return the credits that were spent.
  -- Free / admin-added (no payment): nothing to refund.
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

  -- Upsert credits scoped to the club that ran the game
  INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
    VALUES (p_user_id, v_game.club_id, v_refund, 'aud')
  ON CONFLICT (user_id, club_id, currency)
  DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;

  -- Mark as issued — prevents any future duplicate call from running
  UPDATE bookings
  SET    credit_refund_issued_at = now()
  WHERE  id = p_booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION issue_cancellation_credit(UUID, UUID) TO authenticated;
