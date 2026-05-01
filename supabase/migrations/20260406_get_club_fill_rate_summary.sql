-- Phase 5A-2 — Club Fill Rate / Attendance Summary RPC
-- Run once in Supabase SQL Editor (as postgres).
-- Safe to re-run (CREATE OR REPLACE).
--
-- get_club_fill_rate_summary(p_club_id, p_days)
--   p_days = NULL → all time
--   p_days = 30   → games with date_time in last 30 days, etc.
--   (uses game.date_time, not booking.created_at — attendance is about the scheduled game)
--
-- Server enforces:
--   1. Caller must be club owner (clubs.created_by) or club admin (club_admins)
--   2. Club must have analytics_access = true in club_entitlements
--
-- Metric definitions:
--   total_games_count       — non-cancelled games in period (all valid max_spots)
--   total_spots_offered     — sum of max_spots for games where max_spots > 0
--   total_confirmed_bookings— bookings.status = 'confirmed' across all counted games
--   average_fill_rate       — confirmed / spots_offered for max_spots > 0 games (0.0–1.0)
--   full_games_count        — games where confirmed_count >= max_spots (max_spots > 0 only)
--   average_players_per_game— total_confirmed / total_games (all games, no max_spots filter)
--   cancellation_rate       — cancelled bookings / all bookings for counted games (0.0–1.0)
--   as_of                   — server timestamp at query time
--
-- Returns zeros (not nulls) when no qualifying games exist.

CREATE OR REPLACE FUNCTION get_club_fill_rate_summary(
  p_club_id UUID,
  p_days    INT DEFAULT NULL
)
RETURNS TABLE (
  total_games_count          INT,
  total_spots_offered        INT,
  total_confirmed_bookings   INT,
  average_fill_rate          NUMERIC,
  full_games_count           INT,
  average_players_per_game   NUMERIC,
  cancellation_rate          NUMERIC,
  as_of                      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  -- 1. Verify caller is club owner or admin.
  IF NOT EXISTS (
    SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller
  ) AND NOT EXISTS (
    SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller
  ) THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Verify analytics_access entitlement.
  IF NOT EXISTS (
    SELECT 1 FROM club_entitlements
    WHERE club_id = p_club_id AND analytics_access = true
  ) THEN
    RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001';
  END IF;

  -- 3. Aggregate.
  RETURN QUERY
  WITH all_games AS (
    -- All non-cancelled games in the period. Confirmed/cancelled booking counts per game.
    SELECT
      g.id,
      g.max_spots,
      COUNT(CASE WHEN b.status = 'confirmed' THEN 1 END)  AS confirmed_count,
      COUNT(b.id)                                          AS total_booking_count,
      COUNT(CASE WHEN b.status = 'cancelled' THEN 1 END)  AS cancelled_count
    FROM   games    g
    LEFT JOIN bookings b ON b.game_id = g.id
    WHERE  g.club_id = p_club_id
      AND  g.status != 'cancelled'
      AND  (p_days IS NULL
            OR g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL)
    GROUP BY g.id, g.max_spots
  ),
  fill_games AS (
    -- Subset with valid capacity — used for fill-rate and full_games metrics only.
    SELECT * FROM all_games WHERE max_spots IS NOT NULL AND max_spots > 0
  )
  SELECT
    -- Total games (all non-cancelled)
    COUNT(*)::INT                                                                    AS total_games_count,

    -- Total spots offered (fill-rate-eligible games only)
    COALESCE((SELECT SUM(max_spots) FROM fill_games), 0)::INT                       AS total_spots_offered,

    -- Total confirmed players (all games)
    COALESCE(SUM(confirmed_count), 0)::INT                                          AS total_confirmed_bookings,

    -- Average fill rate: confirmed / spots across fill-eligible games
    CASE
      WHEN COALESCE((SELECT SUM(max_spots) FROM fill_games), 0) > 0
      THEN ROUND(
             COALESCE((SELECT SUM(confirmed_count) FROM fill_games), 0)::NUMERIC
             / (SELECT SUM(max_spots) FROM fill_games),
             4
           )
      ELSE 0::NUMERIC
    END                                                                              AS average_fill_rate,

    -- Full games: confirmed >= max_spots
    COALESCE((SELECT COUNT(*) FROM fill_games WHERE confirmed_count >= max_spots), 0)::INT
                                                                                     AS full_games_count,

    -- Average players per game (all games)
    CASE
      WHEN COUNT(*) > 0
      THEN ROUND(COALESCE(SUM(confirmed_count), 0)::NUMERIC / COUNT(*), 2)
      ELSE 0::NUMERIC
    END                                                                              AS average_players_per_game,

    -- Cancellation rate: cancelled bookings / all bookings across counted games
    CASE
      WHEN COALESCE(SUM(total_booking_count), 0) > 0
      THEN ROUND(
             COALESCE(SUM(cancelled_count), 0)::NUMERIC
             / NULLIF(SUM(total_booking_count), 0),
             4
           )
      ELSE 0::NUMERIC
    END                                                                              AS cancellation_rate,

    now()                                                                            AS as_of

  FROM all_games;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_fill_rate_summary(UUID, INT) TO authenticated;
