-- Phase 4 Part 2B — Active game limit enforcement
-- Creates a BEFORE INSERT trigger on games that rejects inserts
-- when the club has reached its max_active_games entitlement.
--
-- Run once in Supabase SQL Editor (as postgres).
-- Safe to re-run (uses CREATE OR REPLACE + DROP IF EXISTS).
--
-- Active game definition: status != 'cancelled' AND date_time > now()
-- Scheduled/unpublished games (publish_at in future) count against the limit.
-- -1 in max_active_games means unlimited — trigger allows insert immediately.

-- ---------------------------------------------------------------------------
-- 1. Trigger function
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_active_game_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_max_active   INT;
  v_active_count INT;
BEGIN
  -- Read the entitlement for this club.
  -- If no row exists, deny by default — do not allow creation on missing data.
  SELECT max_active_games
  INTO   v_max_active
  FROM   club_entitlements
  WHERE  club_id = NEW.club_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plan entitlements unavailable. Please try again.'
      USING ERRCODE = 'P0001';
  END IF;

  -- -1 means unlimited — skip the count entirely.
  IF v_max_active = -1 THEN
    RETURN NEW;
  END IF;

  -- Count active games for this club (not cancelled, date in future).
  SELECT COUNT(*)
  INTO   v_active_count
  FROM   games
  WHERE  club_id  = NEW.club_id
    AND  status  != 'cancelled'
    AND  date_time > now();

  IF v_active_count >= v_max_active THEN
    RAISE EXCEPTION 'Active game limit reached (%). Upgrade your plan to add more games.', v_max_active
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Trigger — fires before each INSERT row on games
-- ---------------------------------------------------------------------------

DROP TRIGGER IF EXISTS enforce_active_game_limit ON games;

CREATE TRIGGER enforce_active_game_limit
  BEFORE INSERT ON games
  FOR EACH ROW
  EXECUTE FUNCTION check_active_game_limit();
