-- Fix: promote_top_waitlisted() — Phase 3 paid-game awareness
--
-- ROOT CAUSE:
--   The existing promote_top_waitlisted() trigger function was written before
--   Phase 3 (paid game waitlist promotion with hold). It unconditionally sets
--   status = 'confirmed' for the top waitlisted booking whenever a confirmed
--   booking is cancelled — regardless of whether the game requires payment.
--
--   For paid games this is wrong. The promoted user is confirmed without ever
--   creating a PaymentIntent or paying. The spot is handed to them for free.
--
-- PHASE 3 EXPECTED BEHAVIOUR:
--   Free game  (fee_amount IS NULL OR fee_amount = 0):
--     waitlisted → confirmed        (unchanged from old behaviour)
--
--   Paid game  (fee_amount > 0):
--     waitlisted → pending_payment
--     hold_expires_at = now() + 30 minutes   (matches iOS waitlistHoldMinutes = 30)
--     promoted_at     = now()
--     waitlist_position = NULL
--
--   The promoted user receives a push notification (sent by AppState after it
--   polls and detects the pending_payment booking) and has 30 minutes to open
--   the app and complete payment. If the hold expires without payment the
--   booking reverts to waitlisted (handled by existing hold-expiry logic).
--
-- CONCURRENT SAFETY:
--   FOR UPDATE SKIP LOCKED on the waitlisted booking SELECT prevents two
--   simultaneous cancellations from promoting the same row twice. The second
--   concurrent cancellation finds no unlocked waitlisted row and promotes nothing
--   — correct, because the first already claimed the one open slot.
--
-- PROMOTED_AT COLUMN:
--   Added with IF NOT EXISTS. Used server-side for audit / analytics only.
--   The iOS client does not read this column.
--
-- SAFE TO RE-RUN:
--   CREATE OR REPLACE FUNCTION is idempotent.
--   ADD COLUMN IF NOT EXISTS is idempotent.
--   The trigger wiring (CREATE TRIGGER ... EXECUTE FUNCTION promote_top_waitlisted())
--   is unchanged — only the function body is replaced.

-- 1. Ensure promoted_at column exists on bookings.
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS promoted_at TIMESTAMPTZ NULL;

-- 2. Replace the trigger function with Phase 3-aware logic.
CREATE OR REPLACE FUNCTION promote_top_waitlisted()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game          games%ROWTYPE;
  v_booking_id    UUID;
  v_is_paid       BOOLEAN;
  v_hold_minutes  CONSTANT INT := 30;   -- must match AppState.waitlistHoldMinutes
BEGIN
  -- Only fire when a CONFIRMED booking transitions to CANCELLED.
  -- Ignore all other status changes (e.g. waitlisted → cancelled, etc.)
  IF OLD.status IS DISTINCT FROM 'confirmed' OR NEW.status IS DISTINCT FROM 'cancelled' THEN
    RETURN NEW;
  END IF;

  -- Look up the game to determine free vs paid.
  SELECT * INTO v_game
  FROM   games
  WHERE  id = NEW.game_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

  -- Claim the top waitlisted booking atomically.
  -- FOR UPDATE SKIP LOCKED: if another transaction is already promoting this row
  -- (concurrent cancellation), skip it and promote nothing — the other transaction
  -- will handle it. This prevents double-promotion.
  SELECT id INTO v_booking_id
  FROM   bookings
  WHERE  game_id = NEW.game_id
    AND  status  = 'waitlisted'
  ORDER  BY waitlist_position ASC NULLS LAST,
            created_at        ASC
  LIMIT  1
  FOR UPDATE SKIP LOCKED;

  IF v_booking_id IS NULL THEN
    RETURN NEW;   -- no one on the waitlist
  END IF;

  IF v_is_paid THEN
    -- Paid game: promote to pending_payment with a timed hold.
    -- The iOS client detects this state change on next refresh and shows the
    -- "Complete Booking" CTA with a countdown timer.
    UPDATE bookings
    SET
      status            = 'pending_payment',
      waitlist_position = NULL,
      hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
      promoted_at       = now()
    WHERE id = v_booking_id;

  ELSE
    -- Free game: promote directly to confirmed (pre-Phase-3 behaviour, unchanged).
    UPDATE bookings
    SET
      status            = 'confirmed',
      waitlist_position = NULL
    WHERE id = v_booking_id;

  END IF;

  RETURN NEW;
END;
$$;

-- 3. Verify the trigger is still wired correctly.
--    (The CREATE TRIGGER statement below is commented out because the trigger
--    was created in the live DB before this migration was written. It is included
--    here for documentation and disaster-recovery purposes only.
--    Running it against a fresh DB would create the trigger correctly.)
--
-- DO $$
-- BEGIN
--   IF NOT EXISTS (
--     SELECT 1 FROM pg_trigger
--     WHERE tgname = 'trg_promote_top_waitlisted'
--       AND tgrelid = 'bookings'::regclass
--   ) THEN
--     CREATE TRIGGER trg_promote_top_waitlisted
--       AFTER UPDATE OF status ON bookings
--       FOR EACH ROW
--       EXECUTE FUNCTION promote_top_waitlisted();
--   END IF;
-- END $$;
