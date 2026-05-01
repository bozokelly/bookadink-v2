-- Club Dashboard Summary RPC
--
-- get_club_dashboard_summary(p_club_id)
-- Lightweight snapshot of dashboard metrics for all club owners/admins.
-- Does NOT require analytics_access entitlement — available on all plan tiers.
--
-- Metrics returned:
--   total_members              — current approved member count
--   member_growth_30d          — members whose requested_at falls in the last 30 days
--                                (proxy for recently joined; removals not tracked)
--   monthly_active_players_30d — distinct players with a confirmed booking on a past
--                                club game in the last 30 days
--   prev_active_players_30d    — same metric, prior 30-day window (for delta display)
--   fill_rate_30d              — weighted fill rate (total confirmed / total capacity)
--                                across completed games in the last 30 days;
--                                0 when no games with valid capacity exist
--   prev_fill_rate_30d         — same metric, prior 30-day window
--   upcoming_bookings_count    — confirmed bookings across future non-cancelled games
--
-- Notes:
--   • Active players and fill rate use bookings.status = 'confirmed' as the attendance
--     proxy, consistent with get_club_analytics_kpis. game_attendance rows are not
--     consulted because attendance check-in is opt-in and not populated for all games.
--   • Fill rate is weighted (not a simple per-game average) so large games contribute
--     proportionally to the result, matching the Pro analytics definition.
--   • member_growth_30d counts only positive additions; member removals are not
--     tracked in the schema so net-negative growth cannot be surfaced.

CREATE OR REPLACE FUNCTION get_club_dashboard_summary(p_club_id UUID)
RETURNS TABLE (
  total_members              BIGINT,
  member_growth_30d          BIGINT,
  monthly_active_players_30d BIGINT,
  prev_active_players_30d    BIGINT,
  fill_rate_30d              NUMERIC,  -- NULL when no completed games with valid capacity exist
  prev_fill_rate_30d         NUMERIC,  -- NULL when no prior-period completed games with valid capacity exist
  upcoming_bookings_count    BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller     UUID        := auth.uid();
  v_curr_start TIMESTAMPTZ := now() - INTERVAL '30 days';
  v_prev_start TIMESTAMPTZ := now() - INTERVAL '60 days';
BEGIN
  -- Caller must be club owner or an admin of this club.
  IF NOT EXISTS (SELECT 1 FROM clubs      WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH
  -- Past games that occurred in the current 30-day window.
  curr_past_games AS (
    SELECT g.id, g.max_spots
    FROM   games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_curr_start
      AND  g.date_time <  now()
  ),
  -- Past games in the prior 30-day window (30–60 days ago).
  prev_past_games AS (
    SELECT g.id, g.max_spots
    FROM   games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_prev_start
      AND  g.date_time <  v_curr_start
  ),
  -- Future non-cancelled games.
  upcoming_games AS (
    SELECT g.id
    FROM   games g
    WHERE  g.club_id  = p_club_id
      AND  g.status  != 'cancelled'
      AND  g.date_time >= now()
  ),
  -- Confirmed bookings on current-period past games.
  curr_bookings AS (
    SELECT b.user_id, b.game_id
    FROM   bookings b
    WHERE  b.status  = 'confirmed'
      AND  b.game_id IN (SELECT id FROM curr_past_games)
  ),
  -- Confirmed bookings on previous-period past games.
  prev_bookings AS (
    SELECT b.user_id, b.game_id
    FROM   bookings b
    WHERE  b.status  = 'confirmed'
      AND  b.game_id IN (SELECT id FROM prev_past_games)
  ),
  -- Per-game attendance + capacity for current period fill rate.
  -- Only includes games with a valid capacity (max_spots > 0).
  curr_fill AS (
    SELECT cpg.max_spots, COUNT(cb.user_id) AS confirmed
    FROM   curr_past_games cpg
    LEFT   JOIN curr_bookings cb ON cb.game_id = cpg.id
    WHERE  cpg.max_spots IS NOT NULL AND cpg.max_spots > 0
    GROUP  BY cpg.id, cpg.max_spots
  ),
  -- Per-game attendance + capacity for previous period fill rate.
  prev_fill AS (
    SELECT ppg.max_spots, COUNT(pb.user_id) AS confirmed
    FROM   prev_past_games ppg
    LEFT   JOIN prev_bookings pb ON pb.game_id = ppg.id
    WHERE  ppg.max_spots IS NOT NULL AND ppg.max_spots > 0
    GROUP  BY ppg.id, ppg.max_spots
  )
  SELECT
    -- Current approved member count.
    (SELECT COUNT(*) FROM club_members
     WHERE  club_id = p_club_id AND status = 'approved')::BIGINT,

    -- Net new members in the last 30 days (join proxy via requested_at).
    (SELECT COUNT(*) FROM club_members
     WHERE  club_id      = p_club_id
       AND  status       = 'approved'
       AND  requested_at >= v_curr_start)::BIGINT,

    -- Unique active players: distinct confirmed bookers on past games, last 30 days.
    (SELECT COUNT(DISTINCT user_id) FROM curr_bookings)::BIGINT,

    -- Unique active players in prior 30-day window.
    (SELECT COUNT(DISTINCT user_id) FROM prev_bookings)::BIGINT,

    -- Weighted fill rate for current 30-day past games. NULL when no valid-capacity games exist.
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM curr_fill), 0) > 0
         THEN ROUND(
           (SELECT SUM(confirmed) FROM curr_fill)::NUMERIC
           / (SELECT SUM(max_spots) FROM curr_fill),
           4)
         ELSE NULL END,

    -- Weighted fill rate for previous 30-day past games. NULL when no valid-capacity games exist.
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM prev_fill), 0) > 0
         THEN ROUND(
           (SELECT SUM(confirmed) FROM prev_fill)::NUMERIC
           / (SELECT SUM(max_spots) FROM prev_fill),
           4)
         ELSE NULL END,

    -- Confirmed bookings across all upcoming non-cancelled games.
    (SELECT COUNT(*) FROM bookings
     WHERE  status  = 'confirmed'
       AND  game_id IN (SELECT id FROM upcoming_games))::BIGINT;

END;
$$;

GRANT EXECUTE ON FUNCTION get_club_dashboard_summary(UUID) TO authenticated;
