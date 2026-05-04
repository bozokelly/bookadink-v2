-- Enforce: games with fee_amount > 0 are only allowed for clubs with can_accept_payments = true.
-- This trigger is the server-authoritative gate — the iOS client also checks entitlements,
-- but this trigger ensures the DB is the final word even if the client is bypassed.
--
-- Behaviour:
--   - INSERT or UPDATE of fee_amount > 0 on a club without can_accept_payments → exception
--   - fee_amount IS NULL or 0 → always allowed regardless of plan
--   - Missing entitlement row (no plan assigned) → treated as ineligible (fail-closed)
--
-- Legacy paid games on downgraded clubs are NOT zeroed out by this trigger.
-- They remain in the DB so owners can see them, but new bookings are blocked at
-- the create-payment-intent edge function (can_accept_payments = false → 403).

CREATE OR REPLACE FUNCTION enforce_game_fee_entitlement()
RETURNS TRIGGER AS $$
DECLARE
  v_can_accept_payments BOOLEAN;
BEGIN
  -- Only enforce when a non-zero fee is being set.
  IF NEW.fee_amount IS NULL OR NEW.fee_amount <= 0 THEN
    RETURN NEW;
  END IF;

  SELECT can_accept_payments
    INTO v_can_accept_payments
    FROM club_entitlements
   WHERE club_id = NEW.club_id;

  -- Fail-closed: missing entitlement row → ineligible.
  IF v_can_accept_payments IS NULL OR NOT v_can_accept_payments THEN
    RAISE EXCEPTION 'Club is not eligible to accept payments. Upgrade your plan or set the game fee to $0.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_enforce_game_fee_entitlement ON games;

CREATE TRIGGER trg_enforce_game_fee_entitlement
  BEFORE INSERT OR UPDATE OF fee_amount ON games
  FOR EACH ROW
  EXECUTE FUNCTION enforce_game_fee_entitlement();
