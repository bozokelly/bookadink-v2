-- Additive: app_config row + get_waitlist_hold_minutes() helper.
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT THIS DOES
--   Seeds `app_config('waitlist_hold_minutes', '2')` and creates a STABLE
--   SECURITY DEFINER helper that reads the row, parses + clamps to [1, 1440],
--   and falls back to 2 only if the row is missing or unparseable.
--
-- WHAT THIS DOES NOT DO
--   Does NOT touch any existing function (book_game, promote_top_waitlisted,
--   revert_expired_holds_and_repromote, promote_waitlist_player). Does NOT
--   change any trigger. Does NOT change any logic. The four hold-setting
--   functions continue to use their hardcoded constants until the surgical
--   companion migration (20260504070000) is applied.
--
-- BLAST RADIUS
--   Zero. Adds one row, one function, one grant. Existing call paths are
--   unchanged; the helper has no callers until the next migration is applied.
--
-- VERIFY AFTER RUN
--   SELECT value FROM app_config WHERE key = 'waitlist_hold_minutes';   -- '2'
--   SELECT get_waitlist_hold_minutes();                                  -- 2
--   SELECT get_waitlist_hold_minutes() FROM (
--     SELECT set_config('app_config_disabled', 'true', true)             -- harmless
--   ) _;                                                                 -- 2
--
-- HOLD VALUE CONTROL (effective once the companion migration lands)
--   UPDATE app_config SET value = 'N' WHERE key = 'waitlist_hold_minutes';
--   No function recreation needed.
-- ─────────────────────────────────────────────────────────────────────────────


INSERT INTO app_config (key, value, description)
VALUES (
  'waitlist_hold_minutes',
  '2',
  'Minutes a promoted waitlister or fresh paid booking has to complete payment before the hold expires and is forfeited. Read by book_game, promote_top_waitlisted (trigger), promote_waitlist_player, and revert_expired_holds_and_repromote (cron) once 20260504070000 is applied. Flip with: UPDATE app_config SET value = ''N'' WHERE key = ''waitlist_hold_minutes''; — next function call sees the new value, no recreation needed.'
)
ON CONFLICT (key) DO UPDATE
  SET description = EXCLUDED.description,
      updated_at  = now();
-- ON CONFLICT does NOT overwrite `value` — preserves any pre-set override
-- (e.g. someone has already flipped to '30' for ship).


CREATE OR REPLACE FUNCTION get_waitlist_hold_minutes()
RETURNS INT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_value TEXT;
  v_int   INT;
BEGIN
  SELECT value INTO v_value FROM app_config WHERE key = 'waitlist_hold_minutes';
  IF v_value IS NULL THEN
    RETURN 2;  -- Row missing; fail open with the testing default.
  END IF;
  BEGIN
    v_int := v_value::INT;
  EXCEPTION WHEN OTHERS THEN
    -- Bad config (someone wrote 'thirty') → fall back rather than 500 every booking.
    RETURN 2;
  END;
  -- Clamp to a sane envelope (matches promote_waitlist_player's existing clamp).
  RETURN GREATEST(1, LEAST(v_int, 1440));
END;
$$;

GRANT EXECUTE ON FUNCTION get_waitlist_hold_minutes() TO authenticated;
