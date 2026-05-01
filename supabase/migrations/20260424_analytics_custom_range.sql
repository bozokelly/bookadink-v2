-- Analytics Custom Range Support
--
-- Adds optional p_start_date TIMESTAMPTZ and p_end_date TIMESTAMPTZ to all 5
-- analytics RPCs. When provided, exact dates are used; when omitted, the existing
-- p_days-from-now behaviour is preserved, so all existing callers are unaffected.
--
-- Date resolution (applied identically across every RPC):
--   v_range_end   := COALESCE(p_end_date, now())
--   v_range_start := COALESCE(p_start_date, v_range_end - p_days * interval)
--   v_retro_end   := LEAST(v_range_end, now())   -- caps future to now for backward metrics
--   v_duration    := v_range_end - v_range_start  -- used to compute prior-period window
--   v_prev_start  := v_range_start - v_duration
--
-- Swift callers:
--   Preset ranges: send only p_club_id + p_days (p_start_date/p_end_date absent → NULL)
--   Custom ranges: send p_club_id + p_days=0 + p_start_date + p_end_date
--     where p_end_date = start of the day AFTER the selected end (exclusive upper bound)
--
-- Future-game handling:
--   Retrospective metrics (revenue, bookings, fill rate, no-show):
--     filter g.date_time >= v_range_start AND g.date_time <= v_retro_end
--   Live demand metrics (waitlist):
--     filter g.date_time >= v_range_start AND g.date_time < v_range_end
--     (includes future games so upcoming demand is visible)
--
-- All functions require SECURITY DEFINER + owner/admin + analytics_access checks (unchanged).
-- All DROPs are IF EXISTS — safe to re-run.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_club_analytics_kpis
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_analytics_kpis(UUID, INT);

CREATE OR REPLACE FUNCTION get_club_analytics_kpis(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  curr_revenue_cents          BIGINT,
  curr_booking_count          BIGINT,
  curr_fill_rate              NUMERIC,
  curr_active_players         BIGINT,
  prev_revenue_cents          BIGINT,
  prev_booking_count          BIGINT,
  prev_fill_rate              NUMERIC,
  prev_active_players         BIGINT,
  cancellation_rate           NUMERIC,
  repeat_player_rate          NUMERIC,
  currency                    TEXT,
  as_of                       TIMESTAMPTZ,
  curr_gross_revenue_cents    BIGINT,
  curr_platform_fee_cents     BIGINT,
  curr_credits_used_cents     BIGINT,
  prev_gross_revenue_cents    BIGINT,
  prev_platform_fee_cents     BIGINT,
  prev_credits_used_cents     BIGINT,
  curr_cancelled_gross_cents  BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller      UUID        := auth.uid();
  v_range_end   TIMESTAMPTZ := COALESCE(p_end_date,   now());
  v_range_start TIMESTAMPTZ := COALESCE(p_start_date, v_range_end - (p_days::TEXT || ' days')::INTERVAL);
  v_retro_end   TIMESTAMPTZ := LEAST(v_range_end, now());
  v_duration    INTERVAL    := v_range_end - v_range_start;
  v_prev_start  TIMESTAMPTZ := v_range_start - v_duration;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH
  curr_games AS (
    SELECT g.id, g.max_spots FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
  ),
  prev_games AS (
    SELECT g.id, g.max_spots FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_prev_start AND g.date_time < v_range_start
  ),
  curr_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents,    0) AS payout,
           COALESCE(b.platform_fee_cents,   0) AS platform_fee,
           COALESCE(b.credits_applied_cents,0) AS credits,
           b.payment_method
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM curr_games)
  ),
  prev_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents,    0) AS payout,
           COALESCE(b.platform_fee_cents,   0) AS platform_fee,
           COALESCE(b.credits_applied_cents,0) AS credits,
           b.payment_method
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM prev_games)
  ),
  curr_all AS (
    SELECT b.id, b.status, b.fee_paid, b.payment_method,
           COALESCE(b.platform_fee_cents,0) + COALESCE(b.club_payout_cents,0) AS gross
    FROM bookings b
    WHERE b.game_id IN (SELECT id FROM curr_games)
  ),
  curr_fills AS (
    SELECT cg.id, cg.max_spots, COUNT(cc.id) AS conf
    FROM curr_games cg
    LEFT JOIN curr_conf cc ON cc.game_id = cg.id
    WHERE cg.max_spots IS NOT NULL AND cg.max_spots > 0
    GROUP BY cg.id, cg.max_spots
  ),
  prev_fills AS (
    SELECT pg.id, pg.max_spots, COUNT(pc.id) AS conf
    FROM prev_games pg
    LEFT JOIN prev_conf pc ON pc.game_id = pg.id
    WHERE pg.max_spots IS NOT NULL AND pg.max_spots > 0
    GROUP BY pg.id, pg.max_spots
  ),
  player_game_counts AS (
    SELECT user_id, COUNT(DISTINCT game_id) AS n
    FROM curr_conf GROUP BY user_id
  )
  SELECT
    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT COUNT(id) FROM curr_conf), 0)::BIGINT,
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM curr_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM curr_fills)::NUMERIC / (SELECT SUM(max_spots) FROM curr_fills), 4)
         ELSE 0::NUMERIC END,
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0)::BIGINT,

    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT COUNT(id) FROM prev_conf), 0)::BIGINT,
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM prev_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM prev_fills)::NUMERIC / (SELECT SUM(max_spots) FROM prev_fills), 4)
         ELSE 0::NUMERIC END,
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM prev_conf), 0)::BIGINT,

    CASE WHEN (SELECT COUNT(*) FROM curr_all) > 0
         THEN ROUND((SELECT COUNT(*) FROM curr_all WHERE status = 'cancelled')::NUMERIC
                  / (SELECT COUNT(*) FROM curr_all), 4)
         ELSE 0::NUMERIC END,
    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf) > 0
         THEN ROUND((SELECT COUNT(*) FROM player_game_counts WHERE n > 1)::NUMERIC
                  / NULLIF((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0), 4)
         ELSE 0::NUMERIC END,

    COALESCE(
      (SELECT g2.fee_currency FROM games g2 JOIN bookings b2 ON b2.game_id = g2.id
       WHERE g2.club_id = p_club_id AND b2.payment_method = 'stripe' AND g2.fee_currency IS NOT NULL
       ORDER BY b2.created_at DESC LIMIT 1),
      'AUD'),
    now(),

    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(platform_fee)          FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(credits) FROM curr_conf), 0)::BIGINT,

    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(platform_fee)          FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(credits) FROM prev_conf), 0)::BIGINT,

    COALESCE((SELECT SUM(gross) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT
  FROM (SELECT 1) AS d;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_club_analytics_supplemental
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_analytics_supplemental(UUID, INT);

CREATE OR REPLACE FUNCTION get_club_analytics_supplemental(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  curr_member_joins          BIGINT,
  prev_member_joins          BIGINT,
  total_active_members       BIGINT,
  curr_new_players           BIGINT,
  curr_game_count            BIGINT,
  curr_no_show_count         BIGINT,
  curr_checked_count         BIGINT,
  curr_waitlist_count        BIGINT,
  curr_paid_bookings         BIGINT,
  curr_free_bookings         BIGINT,
  avg_rev_per_player_cents   BIGINT,
  curr_no_show_rate          NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller      UUID        := auth.uid();
  v_range_end   TIMESTAMPTZ := COALESCE(p_end_date,   now());
  v_range_start TIMESTAMPTZ := COALESCE(p_start_date, v_range_end - (p_days::TEXT || ' days')::INTERVAL);
  v_retro_end   TIMESTAMPTZ := LEAST(v_range_end, now());
  v_duration    INTERVAL    := v_range_end - v_range_start;
  v_prev_start  TIMESTAMPTZ := v_range_start - v_duration;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH
  -- Includes future games for live demand (waitlist signal)
  curr_games AS (
    SELECT g.id FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_range_start AND g.date_time < v_range_end
  ),
  prev_games AS (
    SELECT g.id FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_prev_start AND g.date_time < v_range_start
  ),
  -- Retrospective: past games only (no-show, game count)
  curr_past_games AS (
    SELECT g.id FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
  ),
  curr_conf AS (
    SELECT b.user_id, b.game_id, b.payment_method,
           COALESCE(b.club_payout_cents, 0) AS payout,
           b.created_at
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM curr_games)
  ),
  player_first_booking AS (
    SELECT b.user_id, MIN(b.created_at) AS first_at
    FROM bookings b JOIN games g ON g.id = b.game_id
    WHERE g.club_id = p_club_id AND b.status = 'confirmed'
    GROUP BY b.user_id
  ),
  att AS (
    SELECT
      COUNT(*) FILTER (WHERE ga.attendance_status = 'no_show') AS no_show_cnt,
      COUNT(*)                                                  AS checked_cnt
    FROM game_attendance ga
    WHERE ga.game_id IN (SELECT id FROM curr_past_games)
  )
  SELECT
    (SELECT COUNT(*) FROM club_members
     WHERE club_id = p_club_id AND status = 'approved'
       AND requested_at >= v_range_start)::BIGINT,

    (SELECT COUNT(*) FROM club_members
     WHERE club_id = p_club_id AND status = 'approved'
       AND requested_at >= v_prev_start AND requested_at < v_range_start)::BIGINT,

    (SELECT COUNT(*) FROM club_members
     WHERE club_id = p_club_id AND status = 'approved')::BIGINT,

    (SELECT COUNT(*) FROM player_first_booking
     WHERE first_at >= v_range_start)::BIGINT,

    (SELECT COUNT(*) FROM curr_past_games)::BIGINT,

    (SELECT no_show_cnt FROM att)::BIGINT,
    (SELECT checked_cnt FROM att)::BIGINT,

    (SELECT COUNT(*) FROM bookings b
     WHERE b.status = 'waitlisted'
       AND b.game_id IN (SELECT id FROM curr_games))::BIGINT,

    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'stripe')::BIGINT,

    (SELECT COUNT(*) FROM curr_conf
     WHERE payment_method IS DISTINCT FROM 'stripe')::BIGINT,

    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf WHERE payment_method = 'stripe') > 0
         THEN ROUND(
           (SELECT SUM(payout) FROM curr_conf WHERE payment_method = 'stripe')::NUMERIC
           / (SELECT COUNT(DISTINCT user_id) FROM curr_conf WHERE payment_method = 'stripe')
         )::BIGINT
         ELSE 0::BIGINT END,

    CASE WHEN (SELECT checked_cnt FROM att) > 0
         THEN ROUND((SELECT no_show_cnt FROM att)::NUMERIC / (SELECT checked_cnt FROM att), 4)
         ELSE NULL END;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_supplemental(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_club_revenue_trend
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_revenue_trend(UUID, INT);

CREATE OR REPLACE FUNCTION get_club_revenue_trend(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (bucket_date DATE, revenue_cents BIGINT, booking_count BIGINT, fill_rate NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller      UUID        := auth.uid();
  v_range_end   TIMESTAMPTZ := COALESCE(p_end_date,   now());
  v_range_start TIMESTAMPTZ := COALESCE(p_start_date, v_range_end - (p_days::TEXT || ' days')::INTERVAL);
  v_retro_end   TIMESTAMPTZ := LEAST(v_range_end, now());
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  -- Daily buckets when range is ≤30 days, weekly otherwise
  IF (v_retro_end - v_range_start) <= INTERVAL '30 days' THEN
    RETURN QUERY
    WITH
    day_series AS (
      SELECT generate_series(v_range_start::DATE, v_retro_end::DATE, '1 day'::INTERVAL)::DATE AS d
    ),
    game_stats AS (
      SELECT
        g.date_time::DATE AS d, g.id, g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                                  AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)        AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id = p_club_id AND g.status != 'cancelled'
        AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
      GROUP BY g.date_time::DATE, g.id, g.max_spots
    )
    SELECT
      ds.d,
      COALESCE(SUM(gs.rev),  0)::BIGINT,
      COALESCE(SUM(gs.conf), 0)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf)     FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
               / SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0), 4)
             ELSE 0 END, 0::NUMERIC)
    FROM day_series ds
    LEFT JOIN game_stats gs ON gs.d = ds.d
    GROUP BY ds.d
    ORDER BY ds.d;
  ELSE
    RETURN QUERY
    WITH game_stats AS (
      SELECT
        DATE_TRUNC('week', g.date_time)::DATE AS d, g.id, g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                                  AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)        AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id = p_club_id AND g.status != 'cancelled'
        AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
      GROUP BY DATE_TRUNC('week', g.date_time)::DATE, g.id, g.max_spots
    )
    SELECT
      gs.d,
      SUM(gs.rev)::BIGINT,
      SUM(gs.conf)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf)     FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
               / SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0), 4)
             ELSE 0 END, 0::NUMERIC)
    FROM game_stats gs
    GROUP BY gs.d
    ORDER BY gs.d;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_revenue_trend(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. get_club_top_games
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_top_games(UUID, INT, INT);

CREATE OR REPLACE FUNCTION get_club_top_games(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_limit      INT         DEFAULT 5,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
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
  v_caller      UUID        := auth.uid();
  v_range_end   TIMESTAMPTZ := COALESCE(p_end_date,   now());
  v_range_start TIMESTAMPTZ := COALESCE(p_start_date, v_range_end - (p_days::TEXT || ' days')::INTERVAL);
  v_retro_end   TIMESTAMPTZ := LEAST(v_range_end, now());
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
    COUNT(b.id) FILTER (WHERE b.status = 'confirmed')::BIGINT AS confirmed_count,
    g.max_spots,
    CASE WHEN g.max_spots IS NOT NULL AND g.max_spots > 0
         THEN ROUND(COUNT(b.id) FILTER (WHERE b.status = 'confirmed')::NUMERIC / g.max_spots, 4)
         ELSE 0::NUMERIC END AS fill_rate,
    COALESCE(SUM(b.club_payout_cents)
      FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)::BIGINT AS revenue_cents
  FROM games g
  LEFT JOIN bookings b ON b.game_id = g.id
  WHERE g.club_id  = p_club_id
    AND g.status  != 'cancelled'
    AND g.date_time >= v_range_start
    AND g.date_time <= v_retro_end
  GROUP BY g.id, g.title, g.date_time, g.max_spots
  ORDER BY confirmed_count DESC, fill_rate DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_top_games(UUID, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. get_club_peak_times
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_peak_times(UUID, INT);

CREATE OR REPLACE FUNCTION get_club_peak_times(
  p_club_id    UUID,
  p_days       INT         DEFAULT 90,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (day_of_week INT, hour_of_day INT, avg_confirmed NUMERIC, game_count BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller      UUID        := auth.uid();
  v_range_end   TIMESTAMPTZ := COALESCE(p_end_date,   now());
  v_range_start TIMESTAMPTZ := COALESCE(p_start_date, v_range_end - (p_days::TEXT || ' days')::INTERVAL);
  v_retro_end   TIMESTAMPTZ := LEAST(v_range_end, now());
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH game_stats AS (
    SELECT
      EXTRACT(DOW  FROM g.date_time)::INT AS dow,
      EXTRACT(HOUR FROM g.date_time)::INT AS hod,
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed') AS confirmed_count
    FROM games g
    LEFT JOIN bookings b ON b.game_id = g.id
    WHERE g.club_id  = p_club_id
      AND g.status  != 'cancelled'
      AND g.date_time >= v_range_start
      AND g.date_time <= v_retro_end
    GROUP BY g.id, EXTRACT(DOW FROM g.date_time), EXTRACT(HOUR FROM g.date_time)
  )
  SELECT
    dow   AS day_of_week,
    hod   AS hour_of_day,
    ROUND(AVG(confirmed_count), 1) AS avg_confirmed,
    COUNT(*)::BIGINT                AS game_count
  FROM game_stats
  GROUP BY dow, hod
  ORDER BY avg_confirmed DESC, game_count DESC
  LIMIT 5;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_peak_times(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
