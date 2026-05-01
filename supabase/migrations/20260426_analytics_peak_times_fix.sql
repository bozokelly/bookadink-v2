-- Analytics: Peak Times — re-apply timezone fix + add avg_fill_rate and avg_waitlist
--
-- REGRESSION FIX: 20260424_analytics_custom_range.sql re-created get_club_peak_times
-- with bare EXTRACT(DOW FROM g.date_time) (UTC), silently discarding the AT TIME ZONE
-- fix introduced in 20260424_analytics_tz_grouping.sql. A Perth club's 10pm Friday
-- game (UTC Saturday 2am) was grouped as Saturday, not Friday.
--
-- This migration re-applies the timezone-aware DOW/hour extraction that was lost, and
-- adds two new output columns requested for the analytics spec:
--   avg_fill_rate NUMERIC  — average fill rate across games in this slot
--   avg_waitlist  NUMERIC  — average waitlist demand (confirmed 'waitlisted' +
--                            'pending_payment' bookings per game)
--
-- Reconciliation invariants:
--   Range filtering unchanged (same UTC predicates as KPIs — totals reconcile).
--   Grouping basis: game's scheduled start time (not booking creation timestamp).
--   Cancelled games excluded. Past games only (date_time <= v_retro_end).
--
-- DROP required because RETURNS TABLE adds two columns.

DROP FUNCTION IF EXISTS get_club_peak_times(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION get_club_peak_times(
  p_club_id    UUID,
  p_days       INT         DEFAULT 90,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  day_of_week   INT,
  hour_of_day   INT,
  avg_confirmed NUMERIC,
  game_count    BIGINT,
  avg_fill_rate NUMERIC,
  avg_waitlist  NUMERIC
)
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

  -- Resolve club timezone; fall back when absent or invalid IANA name.
  SELECT COALESCE(NULLIF(TRIM(c.timezone), ''), 'Australia/Perth') INTO v_tz
  FROM clubs c WHERE c.id = p_club_id;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN
    v_tz := 'Australia/Perth';
  END IF;

  -- Extract DOW and hour in local club timezone.
  -- AT TIME ZONE on a TIMESTAMPTZ returns a TIMESTAMP (local wall-clock),
  -- so EXTRACT reads the correct local day-of-week and hour.
  -- Range filtering uses raw UTC timestamps (same predicates as KPIs — reconciles).
  RETURN QUERY
  WITH game_stats AS (
    SELECT
      EXTRACT(DOW  FROM (g.date_time AT TIME ZONE v_tz))::INT AS dow,
      EXTRACT(HOUR FROM (g.date_time AT TIME ZONE v_tz))::INT AS hod,
      g.max_spots,
      -- Live confirmed count from bookings
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                           AS confirmed_count,
      -- Waitlist demand: 'waitlisted' + 'pending_payment'
      COUNT(b.id) FILTER (WHERE b.status IN ('waitlisted', 'pending_payment'))    AS waitlist_count
    FROM games g
    LEFT JOIN bookings b ON b.game_id = g.id
    WHERE g.club_id    = p_club_id
      AND g.status    != 'cancelled'
      AND g.date_time >= v_range_start
      AND g.date_time <= v_retro_end   -- past games only; grouping basis = scheduled start time
    GROUP BY
      g.id,
      g.max_spots,
      EXTRACT(DOW  FROM (g.date_time AT TIME ZONE v_tz)),
      EXTRACT(HOUR FROM (g.date_time AT TIME ZONE v_tz))
  )
  SELECT
    dow                                               AS day_of_week,
    hod                                               AS hour_of_day,
    ROUND(AVG(confirmed_count), 1)                    AS avg_confirmed,
    COUNT(*)::BIGINT                                  AS game_count,
    -- Fill rate: NULL when max_spots = 0 or NULL (excluded from avg gracefully)
    COALESCE(
      ROUND(
        AVG(
          CASE WHEN max_spots IS NOT NULL AND max_spots > 0
               THEN confirmed_count::NUMERIC / max_spots
               ELSE NULL END
        ), 4),
      0::NUMERIC)                                     AS avg_fill_rate,
    ROUND(AVG(waitlist_count), 1)                     AS avg_waitlist
  FROM game_stats
  GROUP BY dow, hod
  ORDER BY avg_confirmed DESC, game_count DESC
  LIMIT 5;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_peak_times(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
