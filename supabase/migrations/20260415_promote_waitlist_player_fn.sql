-- Create promote_waitlist_player() SECURITY DEFINER RPC
-- ─────────────────────────────────────────────────────────────────────────────
-- This function was previously created directly in the SQL Editor (no migration).
-- PostgREST's schema cache never picked it up (PGRST202), so the iOS client has
-- been switched to a direct PATCH on bookings (same pattern as use_credits).
--
-- This migration creates the canonical DB definition for documentation, disaster
-- recovery, and future schema reloads. iOS does NOT call this via PostgREST RPC.
--
-- WHAT IT DOES:
--   Atomically promotes a single waitlisted booking to pending_payment with a
--   timed hold. Returns TRUE if the booking was promoted, FALSE if:
--     - Booking is no longer 'waitlisted' (trigger already promoted it, cancelled, etc.)
--     - Game is at or over capacity
--   Note: the DB trigger promote_top_waitlisted() handles the same promotion
--   automatically on confirmed→cancelled. This RPC is a manual-promotion safety net.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION promote_waitlist_player(
  p_game_id      UUID,
  p_booking_id   UUID,
  p_hold_minutes INT DEFAULT 30
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game         games%ROWTYPE;
  v_confirmed    INT;
  v_rows_updated INT;
BEGIN
  -- Look up the game
  SELECT * INTO v_game FROM games WHERE id = p_game_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  -- Count confirmed bookings to guard against over-promotion
  SELECT COUNT(*) INTO v_confirmed
  FROM bookings
  WHERE game_id = p_game_id AND status = 'confirmed';

  IF v_confirmed >= v_game.max_spots THEN RETURN FALSE; END IF;

  -- Atomically promote — only if the booking is still waitlisted
  UPDATE bookings
  SET
    status            = 'pending_payment',
    waitlist_position = NULL,
    hold_expires_at   = now() + (p_hold_minutes || ' minutes')::INTERVAL,
    promoted_at       = now()
  WHERE id     = p_booking_id
    AND status = 'waitlisted';

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  RETURN v_rows_updated > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION promote_waitlist_player(UUID, UUID, INT) TO authenticated;
