-- Analytics Hardening — two targeted fixes
--
-- Fix 1: get_club_revenue_trend — add AND g.date_time <= now() upper bound
--   Previously the trend included confirmed bookings on FUTURE games in the window,
--   causing trend-sum != KPI-total when upcoming games have bookings.
--   KPIs already filter date_time <= now(); trend must match.
--
-- Fix 2: get_club_analytics_supplemental — move no-show rate from Swift to DB
--   Adds curr_no_show_rate NUMERIC (NULL when no attendance data).
--   The Swift computed property ClubAnalyticsSupplemental.noShowRate is replaced
--   by this DB-authoritative value. Raw counts (curr_no_show_count, curr_checked_count)
--   are kept for future use and audit queries.
--
-- Both are CREATE OR REPLACE except supplemental which changes RETURNS TABLE (DROP first).

-- ─────────────────────────────────────────────────────────────────────────────
-- Fix 1: Revenue Trend — past games only (date_time <= now())
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
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                                            AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)                  AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id    = p_club_id
        AND g.status    != 'cancelled'
        AND g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL
        AND g.date_time <= now()   -- only past games; matches KPI filter
      GROUP BY g.date_time::DATE, g.id, g.max_spots
    )
    SELECT
      ds.d,
      COALESCE(SUM(gs.rev), 0)::BIGINT,
      COALESCE(SUM(gs.conf), 0)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf)     FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
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
    RETURN QUERY
    WITH game_stats AS (
      SELECT
        DATE_TRUNC('week', g.date_time)::DATE AS d,
        g.id,
        g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                                            AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)                  AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id    = p_club_id
        AND g.status    != 'cancelled'
        AND g.date_time >= now() - (p_days::TEXT || ' days')::INTERVAL
        AND g.date_time <= now()   -- only past games; matches KPI filter
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
-- Fix 2: Supplemental — add DB-computed no-show rate
-- DROP required because RETURNS TABLE changes (new column).
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_analytics_supplemental(UUID, INT);

CREATE OR REPLACE FUNCTION get_club_analytics_supplemental(
  p_club_id UUID,
  p_days    INT DEFAULT 30
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
  curr_no_show_rate          NUMERIC   -- NULL when no attendance data; 0.0–1.0
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
  curr_games AS (
    SELECT g.id FROM games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_curr_start
  ),
  prev_games AS (
    SELECT g.id FROM games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_prev_start
      AND  g.date_time <  v_curr_start
  ),
  curr_past_games AS (
    SELECT g.id FROM games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_curr_start
      AND  g.date_time <  now()
  ),
  curr_conf AS (
    SELECT b.user_id, b.game_id, b.payment_method,
           COALESCE(b.club_payout_cents, 0) AS payout,
           b.created_at
    FROM   bookings b
    WHERE  b.status  = 'confirmed'
      AND  b.game_id IN (SELECT id FROM curr_games)
  ),
  player_first_booking AS (
    SELECT b.user_id, MIN(b.created_at) AS first_at
    FROM   bookings b
    JOIN   games    g ON g.id = b.game_id
    WHERE  g.club_id = p_club_id
      AND  b.status  = 'confirmed'
    GROUP  BY b.user_id
  ),
  -- Attendance counts for DB-side no-show rate
  att AS (
    SELECT
      COUNT(*) FILTER (WHERE ga.attendance_status = 'no_show') AS no_show_cnt,
      COUNT(*)                                                  AS checked_cnt
    FROM game_attendance ga
    WHERE ga.game_id IN (SELECT id FROM curr_past_games)
  )
  SELECT
    (SELECT COUNT(*) FROM club_members
     WHERE  club_id      = p_club_id AND status = 'approved'
       AND  requested_at >= v_curr_start)::BIGINT,

    (SELECT COUNT(*) FROM club_members
     WHERE  club_id      = p_club_id AND status = 'approved'
       AND  requested_at >= v_prev_start AND requested_at < v_curr_start)::BIGINT,

    (SELECT COUNT(*) FROM club_members
     WHERE  club_id = p_club_id AND status = 'approved')::BIGINT,

    (SELECT COUNT(*) FROM player_first_booking
     WHERE  first_at >= v_curr_start)::BIGINT,

    (SELECT COUNT(*) FROM curr_past_games)::BIGINT,

    (SELECT no_show_cnt FROM att)::BIGINT,
    (SELECT checked_cnt FROM att)::BIGINT,

    (SELECT COUNT(*) FROM bookings b
     WHERE  b.status  = 'waitlisted'
       AND  b.game_id IN (SELECT id FROM curr_games))::BIGINT,

    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'stripe')::BIGINT,

    (SELECT COUNT(*) FROM curr_conf
     WHERE  payment_method IS DISTINCT FROM 'stripe')::BIGINT,

    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf WHERE payment_method = 'stripe') > 0
         THEN ROUND(
           (SELECT SUM(payout) FROM curr_conf WHERE payment_method = 'stripe')::NUMERIC
           / (SELECT COUNT(DISTINCT user_id) FROM curr_conf WHERE payment_method = 'stripe')
         )::BIGINT
         ELSE 0::BIGINT END,

    -- DB-authoritative no-show rate: NULL when no attendance rows exist
    CASE WHEN (SELECT checked_cnt FROM att) > 0
         THEN ROUND((SELECT no_show_cnt FROM att)::NUMERIC
                  / (SELECT checked_cnt FROM att), 4)
         ELSE NULL END;

END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_supplemental(UUID, INT) TO authenticated;
