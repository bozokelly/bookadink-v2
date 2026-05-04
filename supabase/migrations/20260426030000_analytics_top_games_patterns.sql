-- Analytics: Top Games — pattern-based ranking
--
-- Replaces per-game-instance ranking with per-pattern grouping.
--
-- A "pattern" is the combination of:
--   LOWER(TRIM(title)) + day-of-week (local TZ) + hour-of-day (local TZ)
--   + skill_level + game_format + venue_id
--
-- This surfaces consistently popular recurring slots rather than one-off
-- high-attendance games. A weekly Tuesday 7pm that fills 12/12 every time
-- will rank above a one-off event with the same absolute confirmed count,
-- because tie-breaking favours occurrence_count.
--
-- Return schema changes (DROP required because RETURNS TABLE signature changes):
--   REMOVED: game_id UUID, game_date TIMESTAMPTZ  (instance-specific, meaningless for patterns)
--   ADDED:   day_of_week INT, hour_of_day INT, occurrence_count BIGINT,
--            avg_confirmed NUMERIC, avg_fill_rate NUMERIC,
--            avg_waitlist NUMERIC, skill_level TEXT, game_format TEXT
--   RENAMED: confirmed_count → avg_confirmed, fill_rate → avg_fill_rate,
--            revenue_cents → total_revenue_cents
--   RETAINED: game_title TEXT, max_spots INT (mode over pattern instances)
--
-- Ranking: avg_confirmed DESC, occurrence_count DESC, avg_fill_rate DESC
--   A pattern with the same average attendance as another ranks higher when
--   it has more occurrences (recurrence bias), preventing single events from
--   dominating.
--
-- Timezone: club IANA timezone (clubs.timezone), fallback Australia/Perth.
--   DOW and hour extraction use AT TIME ZONE so Perth 10pm games appear
--   on the correct local day, not UTC+8 → next UTC day.
--
-- Data source: live bookings table (not games.confirmed_count snapshot).
-- Waitlist: counts 'waitlisted' + 'pending_payment' statuses (mirrors
--   ManagePlayersView.waitlistTotal — promoted-not-yet-paid counts as demand).
--
-- Safe to re-run; DROP IF EXISTS is idempotent.

DROP FUNCTION IF EXISTS get_club_top_games(UUID, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION get_club_top_games(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_limit      INT         DEFAULT 5,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  game_title          TEXT,
  day_of_week         INT,
  hour_of_day         INT,
  occurrence_count    BIGINT,
  avg_confirmed       NUMERIC,
  max_spots           INT,
  avg_fill_rate       NUMERIC,
  total_revenue_cents BIGINT,
  avg_waitlist        NUMERIC,
  skill_level         TEXT,
  game_format         TEXT
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

  RETURN QUERY
  WITH
  -- Per-game-instance stats from live bookings
  game_stats AS (
    SELECT
      g.id,
      -- Representative title (before lower/trim used for grouping key)
      g.title::TEXT                                                                AS title,
      LOWER(TRIM(g.title::TEXT))                                                  AS title_key,
      EXTRACT(DOW  FROM (g.date_time AT TIME ZONE v_tz))::INT                     AS dow,
      EXTRACT(HOUR FROM (g.date_time AT TIME ZONE v_tz))::INT                     AS hod,
      g.max_spots,
      g.skill_level::TEXT,
      g.game_format::TEXT,
      g.venue_id,
      -- Live confirmed count from bookings (not games.confirmed_count snapshot)
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                           AS confirmed_count,
      -- Waitlist demand: 'waitlisted' + 'pending_payment' (promoted, awaiting pay)
      COUNT(b.id) FILTER (WHERE b.status IN ('waitlisted', 'pending_payment'))    AS waitlist_count,
      -- Club payout from Stripe-paid confirmed bookings
      COALESCE(SUM(b.club_payout_cents)
        FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) AS revenue_cents
    FROM games g
    LEFT JOIN bookings b ON b.game_id = g.id
    WHERE g.club_id    = p_club_id
      AND g.status    != 'cancelled'
      AND g.date_time >= v_range_start
      AND g.date_time <= v_retro_end   -- past games only
    GROUP BY
      g.id, g.title, g.max_spots, g.skill_level, g.game_format, g.venue_id,
      dow, hod
  ),
  -- Aggregate into patterns: same title_key + dow + hod + skill + format + venue
  patterns AS (
    SELECT
      MIN(gs.title)                                         AS game_title,
      gs.dow                                                AS day_of_week,
      gs.hod                                                AS hour_of_day,
      COUNT(*)::BIGINT                                      AS occurrence_count,
      ROUND(AVG(gs.confirmed_count), 1)                     AS avg_confirmed,
      -- Most-common capacity for this pattern
      MODE() WITHIN GROUP (ORDER BY gs.max_spots)           AS max_spots,
      -- Average fill rate (NULL when max_spots is 0 or NULL — excluded from avg)
      ROUND(
        AVG(
          CASE WHEN gs.max_spots IS NOT NULL AND gs.max_spots > 0
               THEN gs.confirmed_count::NUMERIC / gs.max_spots
               ELSE NULL END
        ), 4)                                               AS avg_fill_rate,
      SUM(gs.revenue_cents)::BIGINT                         AS total_revenue_cents,
      ROUND(AVG(gs.waitlist_count), 1)                      AS avg_waitlist,
      gs.skill_level,
      gs.game_format
    FROM game_stats gs
    GROUP BY
      gs.title_key, gs.dow, gs.hod,
      gs.skill_level, gs.game_format, gs.venue_id
  )
  SELECT
    p.game_title,
    p.day_of_week,
    p.hour_of_day,
    p.occurrence_count,
    p.avg_confirmed,
    p.max_spots,
    COALESCE(p.avg_fill_rate, 0),
    p.total_revenue_cents,
    COALESCE(p.avg_waitlist, 0),
    p.skill_level,
    p.game_format
  FROM patterns p
  -- Rank by average attendance first; break ties by recurrence (recurring > one-off),
  -- then fill rate as final tiebreaker.
  ORDER BY p.avg_confirmed DESC, p.occurrence_count DESC, p.avg_fill_rate DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_top_games(UUID, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
