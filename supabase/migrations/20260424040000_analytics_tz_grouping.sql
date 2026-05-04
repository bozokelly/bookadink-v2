-- Analytics: timezone-aware day/week/DOW/hour grouping
--
-- Problem: trend buckets and peak-time slots were computed in UTC (Supabase DB
-- timezone). A Perth game at 7 pm local (= 11 am UTC) was grouped correctly by
-- total, but a Perth game at 10 pm local (= 2 am next UTC day) would fall in the
-- wrong day bucket, making the trend chart and peak-time heatmap misleading.
--
-- Fix: look up clubs.timezone (IANA identifier, stored at club-creation time) and
-- apply AT TIME ZONE for all grouping/display operations. Range FILTERING remains
-- on raw UTC TIMESTAMPTZ — only the bucket assignment changes.
--
-- Scope: get_club_revenue_trend, get_club_peak_times.
--   get_club_analytics_kpis      — unaffected (counts/sums, no date grouping)
--   get_club_analytics_supplemental — unaffected (no date grouping)
--   get_club_top_games            — unaffected (returns raw TIMESTAMPTZ game_date,
--                                   formatted client-side in device timezone)
--
-- Timezone resolution (both functions):
--   1. SELECT clubs.timezone WHERE id = p_club_id
--   2. NULLIF(TRIM(...), '') → fallback 'Australia/Perth' on NULL/empty
--   3. Validate against pg_timezone_names → fallback on invalid IANA string
--
-- Reconciliation invariant preserved:
--   Filtering set is unchanged (same UTC range predicates as KPIs).
--   SUM(trend.revenue_cents across all buckets) == KPI.curr_revenue_cents. ✓
--
-- Requires: clubs.timezone TEXT column (exists since initial schema).

DROP FUNCTION IF EXISTS get_club_revenue_trend(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS get_club_peak_times(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_club_revenue_trend  (timezone-aware day / week buckets)
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_tz          TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  -- Resolve club timezone; fall back when absent or not a valid IANA name.
  SELECT COALESCE(NULLIF(TRIM(c.timezone), ''), 'Australia/Perth') INTO v_tz
  FROM clubs c WHERE c.id = p_club_id;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN
    v_tz := 'Australia/Perth';
  END IF;

  -- Daily buckets when range ≤30 days, weekly otherwise.
  -- Range filtering uses raw UTC timestamps (same predicate as KPIs — totals reconcile).
  -- Bucket assignment uses local club timezone for display correctness.
  IF (v_retro_end - v_range_start) <= INTERVAL '30 days' THEN
    RETURN QUERY
    WITH
    -- Generate one row per local calendar day in the range.
    day_series AS (
      SELECT generate_series(
        (v_range_start AT TIME ZONE v_tz)::DATE,
        (v_retro_end   AT TIME ZONE v_tz)::DATE,
        '1 day'::INTERVAL
      )::DATE AS d
    ),
    -- Assign each game to its local calendar date.
    game_stats AS (
      SELECT
        (g.date_time AT TIME ZONE v_tz)::DATE AS d,
        g.id, g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                           AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id = p_club_id AND g.status != 'cancelled'
        AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
      GROUP BY (g.date_time AT TIME ZONE v_tz)::DATE, g.id, g.max_spots
    )
    SELECT
      ds.d,
      COALESCE(SUM(gs.rev),  0)::BIGINT,
      COALESCE(SUM(gs.conf), 0)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf)      FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
               / SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0), 4)
             ELSE 0 END, 0::NUMERIC)
    FROM day_series ds
    LEFT JOIN game_stats gs ON gs.d = ds.d
    GROUP BY ds.d
    ORDER BY ds.d;

  ELSE
    -- Weekly buckets: truncate to Monday of the local week.
    RETURN QUERY
    WITH game_stats AS (
      SELECT
        DATE_TRUNC('week', g.date_time AT TIME ZONE v_tz)::DATE AS d,
        g.id, g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                           AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) AS rev
      FROM games g
      LEFT JOIN bookings b ON b.game_id = g.id
      WHERE g.club_id = p_club_id AND g.status != 'cancelled'
        AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
      GROUP BY DATE_TRUNC('week', g.date_time AT TIME ZONE v_tz)::DATE, g.id, g.max_spots
    )
    SELECT
      gs.d,
      SUM(gs.rev)::BIGINT,
      SUM(gs.conf)::BIGINT,
      COALESCE(
        CASE WHEN SUM(gs.max_spots) FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0) > 0
             THEN ROUND(
               SUM(gs.conf)      FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
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
-- 2. get_club_peak_times  (timezone-aware DOW + hour extraction)
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_tz          TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  -- Resolve club timezone; fall back when absent or not a valid IANA name.
  SELECT COALESCE(NULLIF(TRIM(c.timezone), ''), 'Australia/Perth') INTO v_tz
  FROM clubs c WHERE c.id = p_club_id;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN
    v_tz := 'Australia/Perth';
  END IF;

  -- Extract DOW and hour in local club timezone.
  -- AT TIME ZONE on a TIMESTAMPTZ returns a TIMESTAMP (local wall-clock time),
  -- from which EXTRACT reads the correct local day-of-week and hour.
  RETURN QUERY
  WITH game_stats AS (
    SELECT
      EXTRACT(DOW  FROM (g.date_time AT TIME ZONE v_tz))::INT AS dow,
      EXTRACT(HOUR FROM (g.date_time AT TIME ZONE v_tz))::INT AS hod,
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed') AS confirmed_count
    FROM games g
    LEFT JOIN bookings b ON b.game_id = g.id
    WHERE g.club_id  = p_club_id
      AND g.status  != 'cancelled'
      AND g.date_time >= v_range_start
      AND g.date_time <= v_retro_end
    GROUP BY
      g.id,
      EXTRACT(DOW  FROM (g.date_time AT TIME ZONE v_tz)),
      EXTRACT(HOUR FROM (g.date_time AT TIME ZONE v_tz))
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
