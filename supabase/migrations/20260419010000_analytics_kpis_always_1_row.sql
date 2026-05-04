-- Fix: get_club_analytics_kpis always returns exactly 1 row
--
-- Root cause: the previous version used FROM curr_conf cc in the final SELECT.
-- When no confirmed bookings exist in the period, curr_conf is empty, FROM produces
-- 0 rows, the RPC returns an empty JSON array, iOS sees rows.first == nil, and the
-- analytics page shows "No analytics yet" even though the club is valid and has data
-- outside the selected window.
--
-- Fix: replace FROM curr_conf cc with scalar subqueries and FROM (SELECT 1) AS d
-- so the function always returns exactly one row (with 0/0.0 for empty periods).
--
-- Safe to re-run (CREATE OR REPLACE). All access checks are preserved unchanged.

CREATE OR REPLACE FUNCTION get_club_analytics_kpis(
  p_club_id UUID,
  p_days    INT DEFAULT 30
)
RETURNS TABLE (
  curr_revenue_cents  BIGINT,
  curr_booking_count  BIGINT,
  curr_fill_rate      NUMERIC,
  curr_active_players BIGINT,
  prev_revenue_cents  BIGINT,
  prev_booking_count  BIGINT,
  prev_fill_rate      NUMERIC,
  prev_active_players BIGINT,
  cancellation_rate   NUMERIC,
  repeat_player_rate  NUMERIC,
  currency            TEXT,
  as_of               TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller     UUID        := auth.uid();
  v_curr_start TIMESTAMPTZ := now() - (p_days::TEXT || ' days')::INTERVAL;
  v_prev_start TIMESTAMPTZ := now() - (p_days::TEXT || ' days')::INTERVAL * 2;
BEGIN
  -- Access check: caller must be club owner or admin
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  -- Feature gate: club must have analytics entitlement
  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH
  -- Games in current period (past 30d up to now, excludes future for KPIs)
  curr_games AS (
    SELECT g.id, g.max_spots
    FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_curr_start AND g.date_time <= now()
  ),
  -- Games in previous period
  prev_games AS (
    SELECT g.id, g.max_spots
    FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_prev_start AND g.date_time < v_curr_start
  ),
  -- Confirmed bookings for current period
  curr_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents, 0) AS payout,
           b.payment_method
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM curr_games)
  ),
  -- Confirmed bookings for previous period
  prev_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents, 0) AS payout
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM prev_games)
  ),
  -- All bookings in current period (for cancellation rate)
  curr_all AS (
    SELECT b.id, b.status FROM bookings b
    WHERE b.game_id IN (SELECT id FROM curr_games)
  ),
  -- Per-game fill data (current) — only games with valid capacity
  curr_fills AS (
    SELECT cg.id, cg.max_spots,
           COUNT(cc.id) AS conf
    FROM curr_games cg
    LEFT JOIN curr_conf cc ON cc.game_id = cg.id
    WHERE cg.max_spots IS NOT NULL AND cg.max_spots > 0
    GROUP BY cg.id, cg.max_spots
  ),
  -- Per-game fill data (previous)
  prev_fills AS (
    SELECT pg.id, pg.max_spots,
           COUNT(pc.id) AS conf
    FROM prev_games pg
    LEFT JOIN prev_conf pc ON pc.game_id = pg.id
    WHERE pg.max_spots IS NOT NULL AND pg.max_spots > 0
    GROUP BY pg.id, pg.max_spots
  ),
  -- Games each player attended (current period, for repeat rate)
  player_game_counts AS (
    SELECT user_id, COUNT(DISTINCT game_id) AS n
    FROM curr_conf GROUP BY user_id
  )
  -- FROM (SELECT 1) AS d guarantees exactly 1 row regardless of booking volume.
  SELECT
    -- Current period revenue
    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    -- Current bookings
    COALESCE((SELECT COUNT(id) FROM curr_conf), 0)::BIGINT,
    -- Current fill rate
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM curr_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM curr_fills)::NUMERIC
                  / (SELECT SUM(max_spots) FROM curr_fills), 4)
         ELSE 0::NUMERIC END,
    -- Current active players
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0)::BIGINT,

    -- Previous period revenue
    COALESCE((SELECT SUM(payout) FROM prev_conf), 0)::BIGINT,
    -- Previous bookings
    COALESCE((SELECT COUNT(id) FROM prev_conf), 0)::BIGINT,
    -- Previous fill rate
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM prev_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM prev_fills)::NUMERIC
                  / (SELECT SUM(max_spots) FROM prev_fills), 4)
         ELSE 0::NUMERIC END,
    -- Previous active players
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM prev_conf), 0)::BIGINT,

    -- Cancellation rate (current period)
    CASE WHEN (SELECT COUNT(*) FROM curr_all) > 0
         THEN ROUND(
           (SELECT COUNT(*) FROM curr_all WHERE status = 'cancelled')::NUMERIC
           / (SELECT COUNT(*) FROM curr_all), 4)
         ELSE 0::NUMERIC END,

    -- Repeat player rate (current period)
    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf) > 0
         THEN ROUND(
           (SELECT COUNT(*) FROM player_game_counts WHERE n > 1)::NUMERIC
           / NULLIF((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0), 4)
         ELSE 0::NUMERIC END,

    -- Currency (most recent from a paid booking)
    COALESCE(
      (SELECT g2.fee_currency FROM games g2
       JOIN bookings b2 ON b2.game_id = g2.id
       WHERE g2.club_id = p_club_id AND b2.payment_method = 'stripe' AND g2.fee_currency IS NOT NULL
       ORDER BY b2.created_at DESC LIMIT 1),
      'AUD'
    ),
    now()
  FROM (SELECT 1) AS d;  -- Guarantees exactly 1 row even with 0 bookings in the period
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT) TO authenticated;
