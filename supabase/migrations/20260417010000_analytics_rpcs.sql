-- Phase 5B — Advanced Club Analytics RPCs
-- Run once in Supabase SQL Editor (as postgres). All functions are safe to re-run (CREATE OR REPLACE).
-- All functions require: caller is club owner or admin + analytics_access entitlement.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_club_analytics_kpis(p_club_id, p_days)
--
--    Returns current-period KPIs and the prior-period window for comparison.
--    Also returns cancellation_rate and repeat_player_rate (no prior comparison).
--
--    Period filter: games.date_time (when the game occurred, not when it was booked).
--    Revenue:        sum of club_payout_cents for payment_method = 'stripe' bookings.
--    Bookings:       all confirmed bookings (paid + free).
--    Fill rate:      total confirmed / total spots across games with max_spots > 0.
--    Active players: distinct user IDs with confirmed bookings in the period.
-- ─────────────────────────────────────────────────────────────────────────────
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
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH
  -- Games in current period
  curr_games AS (
    SELECT g.id, g.max_spots
    FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled' AND g.date_time >= v_curr_start
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
  -- How many distinct games each player attended (current period, for repeat rate)
  player_game_counts AS (
    SELECT user_id, COUNT(DISTINCT game_id) AS n
    FROM curr_conf GROUP BY user_id
  )
  SELECT
    -- Current period revenue
    COALESCE(SUM(cc.payout) FILTER (WHERE cc.payment_method = 'stripe'), 0)::BIGINT,
    -- Current bookings
    COUNT(DISTINCT cc.id)::BIGINT,
    -- Current fill rate
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM curr_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM curr_fills)::NUMERIC / (SELECT SUM(max_spots) FROM curr_fills), 4)
         ELSE 0::NUMERIC END,
    -- Current active players
    COUNT(DISTINCT cc.user_id)::BIGINT,

    -- Previous period revenue
    COALESCE((SELECT SUM(payout) FROM prev_conf), 0)::BIGINT,
    -- Previous bookings
    COALESCE((SELECT COUNT(id) FROM prev_conf), 0)::BIGINT,
    -- Previous fill rate
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM prev_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM prev_fills)::NUMERIC / (SELECT SUM(max_spots) FROM prev_fills), 4)
         ELSE 0::NUMERIC END,
    -- Previous active players
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM prev_conf), 0)::BIGINT,

    -- Cancellation rate (current period only)
    CASE WHEN (SELECT COUNT(*) FROM curr_all) > 0
         THEN ROUND(
           (SELECT COUNT(*) FROM curr_all WHERE status = 'cancelled')::NUMERIC
           / (SELECT COUNT(*) FROM curr_all), 4)
         ELSE 0::NUMERIC END,
    -- Repeat player rate (current period only)
    CASE WHEN COUNT(DISTINCT cc.user_id) > 0
         THEN ROUND(
           (SELECT COUNT(*) FROM player_game_counts WHERE n > 1)::NUMERIC
           / NULLIF(COUNT(DISTINCT cc.user_id), 0), 4)
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
  FROM curr_conf cc;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_club_revenue_trend(p_club_id, p_days)
--
--    Time-series for the analytics trend chart.
--    ≤30 days → daily buckets. >30 days → weekly buckets (DATE_TRUNC('week')).
--    Revenue:      club_payout_cents where payment_method = 'stripe'.
--    Booking count: confirmed bookings.
--    Fill rate:    weighted across games scheduled on that bucket day/week.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_club_revenue_trend(
  p_club_id UUID,
  p_days    INT DEFAULT 30
)
RETURNS TABLE (bucket_date DATE, revenue_cents BIGINT, booking_count BIGINT, fill_rate NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  IF p_days <= 30 THEN
    -- Daily buckets (fill empty days with zeros via generate_series)
    RETURN QUERY
    WITH
    day_series AS (
      SELECT generate_series(
        (now() - (p_days::TEXT || ' days')::INTERVAL)::DATE,
        now()::DATE,
        '1 day'::INTERVAL
      )::DATE AS d
    ),
    game_stats AS (
      SELECT
        g.date_time::DATE AS d,
        g.id,
        g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')           AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id = p_club_id AND g.status != 'cancelled'
        AND g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL
      GROUP BY g.date_time::DATE, g.id, g.max_spots
    )
    SELECT
      ds.d,
      COALESCE(SUM(gs.rev), 0)::BIGINT,
      COALESCE(SUM(gs.conf), 0)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
               / SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0),
             4)
             ELSE 0 END,
        0::NUMERIC
      )
    FROM day_series ds
    LEFT JOIN game_stats gs ON gs.d = ds.d
    GROUP BY ds.d
    ORDER BY ds.d;
  ELSE
    -- Weekly buckets (sparse — only weeks with games)
    RETURN QUERY
    WITH game_stats AS (
      SELECT
        DATE_TRUNC('week', g.date_time)::DATE AS d,
        g.id,
        g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')           AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id = p_club_id AND g.status != 'cancelled'
        AND g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL
      GROUP BY DATE_TRUNC('week', g.date_time)::DATE, g.id, g.max_spots
    )
    SELECT
      gs.d,
      SUM(gs.rev)::BIGINT,
      SUM(gs.conf)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
               / SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0),
             4)
             ELSE 0 END,
        0::NUMERIC
      )
    FROM game_stats gs
    GROUP BY gs.d
    ORDER BY gs.d;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_revenue_trend(UUID, INT) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_club_top_games(p_club_id, p_days, p_limit)
--
--    Returns the top p_limit past games ranked by confirmed attendance, then
--    fill rate. Only counts games with date_time < now() (already occurred).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_club_top_games(
  p_club_id UUID,
  p_days    INT DEFAULT 30,
  p_limit   INT DEFAULT 5
)
RETURNS TABLE (
  game_id         UUID,
  game_title      TEXT,
  game_date       TIMESTAMPTZ,
  confirmed_count BIGINT,
  max_spots       INT,
  fill_rate       NUMERIC,
  revenue_cents   BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  SELECT
    g.id,
    g.title::TEXT,
    g.date_time,
    COUNT(b.id) FILTER (WHERE b.status = 'confirmed')::BIGINT            AS confirmed_count,
    g.max_spots,
    CASE WHEN g.max_spots IS NOT NULL AND g.max_spots > 0
         THEN ROUND(COUNT(b.id) FILTER (WHERE b.status = 'confirmed')::NUMERIC / g.max_spots, 4)
         ELSE 0::NUMERIC END                                              AS fill_rate,
    COALESCE(SUM(b.club_payout_cents)
      FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)::BIGINT AS revenue_cents
  FROM games g
  LEFT JOIN bookings b ON b.game_id = g.id
  WHERE g.club_id = p_club_id
    AND g.status != 'cancelled'
    AND g.date_time < now()
    AND (p_days IS NULL OR g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL)
  GROUP BY g.id, g.title, g.date_time, g.max_spots
  ORDER BY confirmed_count DESC, fill_rate DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_top_games(UUID, INT, INT) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. get_club_peak_times(p_club_id, p_days)
--
--    Returns the top 5 day-of-week + hour-of-day combinations by average
--    confirmed attendance. Used to surface "when your games fill best."
--    day_of_week: 0 = Sunday, 6 = Saturday (PostgreSQL DOW).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_club_peak_times(
  p_club_id UUID,
  p_days    INT DEFAULT 90
)
RETURNS TABLE (day_of_week INT, hour_of_day INT, avg_confirmed NUMERIC, game_count BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH game_stats AS (
    SELECT
      EXTRACT(DOW  FROM g.date_time)::INT  AS dow,
      EXTRACT(HOUR FROM g.date_time)::INT  AS hod,
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed') AS confirmed_count
    FROM games g
    LEFT JOIN bookings b ON b.game_id = g.id
    WHERE g.club_id = p_club_id
      AND g.status != 'cancelled'
      AND g.date_time < now()
      AND (p_days IS NULL OR g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL)
    GROUP BY g.id, EXTRACT(DOW FROM g.date_time), EXTRACT(HOUR FROM g.date_time)
  )
  SELECT
    dow   AS day_of_week,
    hod   AS hour_of_day,
    ROUND(AVG(confirmed_count), 1) AS avg_confirmed,
    COUNT(*)::BIGINT               AS game_count
  FROM game_stats
  GROUP BY dow, hod
  ORDER BY avg_confirmed DESC, game_count DESC
  LIMIT 5;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_peak_times(UUID, INT) TO authenticated;
