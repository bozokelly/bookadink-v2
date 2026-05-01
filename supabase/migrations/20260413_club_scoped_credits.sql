-- Club-scoped credits
--
-- Credits must belong to the specific club that issued them.
-- A player who cancels a booking at Club A receives credits redeemable ONLY at Club A.
--
-- Changes:
--   1. Add club_id to player_credits
--   2. Clear orphaned global (non-club-scoped) rows
--   3. Make club_id NOT NULL + add unique(user_id, club_id, currency)
--   4. Recreate use_credits to require and validate p_club_id
--   5. Recreate issue_cancellation_credit to derive club_id from booking → game internally

-- 1. Add column
ALTER TABLE player_credits ADD COLUMN IF NOT EXISTS club_id UUID REFERENCES clubs(id);

-- 2. Remove any pre-existing rows that have no club context
--    (safe in test/dev; in production, migrate or reassign before running)
DELETE FROM player_credits WHERE club_id IS NULL;

-- 3. Enforce NOT NULL, rebuild unique constraint
ALTER TABLE player_credits ALTER COLUMN club_id SET NOT NULL;
ALTER TABLE player_credits DROP CONSTRAINT IF EXISTS player_credits_user_id_currency_key;
ALTER TABLE player_credits ADD CONSTRAINT player_credits_user_club_currency_key
  UNIQUE (user_id, club_id, currency);

-- 4. Recreate use_credits with club_id param
DROP FUNCTION IF EXISTS use_credits(UUID, UUID, INT);
CREATE OR REPLACE FUNCTION use_credits(
  p_user_id     UUID,
  p_booking_id  UUID,
  p_amount_cents INT,
  p_club_id     UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance INT;
BEGIN
  SELECT amount_cents INTO v_balance
  FROM   player_credits
  WHERE  user_id = p_user_id AND club_id = p_club_id AND currency = 'aud'
  FOR UPDATE;

  IF NOT FOUND OR v_balance < p_amount_cents THEN
    RETURN FALSE;
  END IF;

  UPDATE player_credits
  SET    amount_cents = amount_cents - p_amount_cents
  WHERE  user_id = p_user_id AND club_id = p_club_id AND currency = 'aud';

  RETURN TRUE;
END;
$$;
GRANT EXECUTE ON FUNCTION use_credits(UUID, UUID, INT, UUID) TO authenticated;

-- 5. Recreate issue_cancellation_credit — derives club_id from booking → game
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
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Idempotency: already issued
  IF v_booking.credit_refund_issued_at IS NOT NULL THEN RETURN; END IF;

  -- Only cancelled bookings
  IF v_booking.status::text != 'cancelled' THEN RETURN; END IF;

  -- Resolve game to get the club_id and policy check
  SELECT * INTO v_game FROM games WHERE id = v_booking.game_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- 6h policy
  IF v_game.date_time <= (NOW() AT TIME ZONE 'UTC') + INTERVAL '6 hours' THEN RETURN; END IF;

  -- Compute refund server-side
  v_refund := CASE
    WHEN COALESCE(v_booking.fee_paid, false) = true THEN
      COALESCE(v_booking.platform_fee_cents,    0) +
      COALESCE(v_booking.club_payout_cents,     0) +
      COALESCE(v_booking.credits_applied_cents, 0)
    WHEN COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
      v_booking.credits_applied_cents
    ELSE 0
  END;

  IF v_refund <= 0 THEN RETURN; END IF;

  -- Issue credit scoped to the club that ran the game
  INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
    VALUES (p_user_id, v_game.club_id, v_refund, 'aud')
  ON CONFLICT (user_id, club_id, currency)
  DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;

  UPDATE bookings SET credit_refund_issued_at = NOW() WHERE id = p_booking_id;
END;
$$;
GRANT EXECUTE ON FUNCTION issue_cancellation_credit(UUID, UUID) TO authenticated;
