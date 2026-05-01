-- Analytics: Top Games — add time-to-fill demand signal
--
-- Adds two new output columns:
--   filled_occurrence_count  BIGINT   — sessions in this pattern that reached capacity
--   avg_time_to_fill_minutes NUMERIC  — avg minutes from open to first fill (NULL when none filled)
--
-- Time-to-fill definition:
--   For each game instance: timestamp of the max_spots-th confirmed booking
--   minus COALESCE(games.publish_at, games.created_at).
--   - publish_at used when set (game became bookable at publish time)
--   - created_at used as fallback (game published immediately on creation)
--   - Only counted when filled_at > open_at (sanity guard against data anomalies)
--   - Games that never reach max_spots contribute NULL (excluded from AVG)
--   - avg_time_to_fill_minutes is NULL for patterns where no instance ever filled
--
-- Ranking (spec order, strongest signals first):
--   1. avg_confirmed           DESC  (raw demand)
--   2. avg_fill_rate           DESC  (efficiency)
--   3. avg_waitlist            DESC  (excess demand)
--   4. filled_occurrence_count DESC  (proven recurring demand)
--   5. avg_time_to_fill_minutes ASC NULLS LAST (fast-filling > slow-filling > never-filled)
--   6. occurrence_count        DESC  (recurrence tiebreaker)
--
-- All other definitions unchanged from 20260426_analytics_top_games_patterns.sql:
--   - Pattern grouping: LOWER(TRIM(title)) + DOW + hour + skill + format + venue
--   - Confirmed count: live bookings table (not games.confirmed_count snapshot)
--   - Waitlist: 'waitlisted' + 'pending_payment' statuses
--   - Revenue: club_payout_cents on Stripe-confirmed bookings
--   - Cancelled games: excluded (status != 'cancelled')
--   - Past games only: date_time <= v_retro_end
--   - Timezone: club IANA timezone (clubs.timezone), fallback Australia/Perth
--
-- DROP required because RETURNS TABLE adds two columns.

DROP FUNCTION IF EXISTS get_club_top_games(UUID, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION get_club_top_games(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_limit      INT         DEFAULT 5,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  game_title               TEXT,
  day_of_week              INT,
  hour_of_day              INT,
  occurrence_count         BIGINT,
  filled_occurrence_count  BIGINT,    -- sessions that reached full capacity
  avg_confirmed            NUMERIC,
  max_spots                INT,
  avg_fill_rate            NUMERIC,
  total_revenue_cents      BIGINT,
  avg_waitlist             NUMERIC,
  avg_time_to_fill_minutes NUMERIC,   -- NULL when no pattern instances ever filled
  skill_level              TEXT,
  game_format              TEXT
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

  SELECT COALESCE(NULLIF(TRIM(c.timezone), ''), 'Australia/Perth') INTO v_tz
  FROM clubs c WHERE c.id = p_club_id;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN
    v_tz := 'Australia/Perth';
  END IF;

  RETURN QUERY
  WITH
  -- Find the moment each game first reached capacity.
  -- ROW_NUMBER over confirmed bookings ordered by created_at gives fill order.
  -- The booking where rn = max_spots is the fill event.
  -- Sanity guard: filled_at must be after the game opened (publish_at or created_at).
  game_fills AS (
    SELECT
      rc.game_id,
      -- Floor at 0: a negative result means anomalous timestamps; treat as instant fill.
      GREATEST(
        EXTRACT(EPOCH FROM (rc.filled_at - COALESCE(g.publish_at, g.created_at))) / 60.0,
        0.0
      ) AS ttf_minutes
    FROM (
      SELECT
        b.game_id,
        b.created_at AS filled_at,
        ROW_NUMBER() OVER (PARTITION BY b.game_id ORDER BY b.created_at ASC) AS rn
      FROM bookings b
      WHERE b.status = 'confirmed'
    ) rc
    JOIN games g ON g.id = rc.game_id
    WHERE g.club_id    = p_club_id
      AND g.status    != 'cancelled'
      AND g.date_time >= v_range_start
      AND g.date_time <= v_retro_end
      AND g.max_spots IS NOT NULL AND g.max_spots > 0
      AND rc.rn       = g.max_spots                                  -- exact fill booking
      AND rc.filled_at > COALESCE(g.publish_at, g.created_at)       -- opened before filled
  ),
  -- Per-game-instance stats from live bookings (not games.confirmed_count snapshot)
  game_stats AS (
    SELECT
      g.id,
      g.title::TEXT                                                                 AS title,
      LOWER(TRIM(g.title::TEXT))                                                   AS title_key,
      EXTRACT(DOW  FROM (g.date_time AT TIME ZONE v_tz))::INT                      AS dow,
      EXTRACT(HOUR FROM (g.date_time AT TIME ZONE v_tz))::INT                      AS hod,
      g.max_spots,
      g.skill_level::TEXT,
      g.game_format::TEXT,
      g.venue_id,
      -- Live counts from bookings (not snapshot)
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                            AS confirmed_count,
      COUNT(b.id) FILTER (WHERE b.status IN ('waitlisted', 'pending_payment'))     AS waitlist_count,
      COALESCE(SUM(b.club_payout_cents)
        FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0)  AS revenue_cents,
      gf.ttf_minutes   -- NULL when game never reached capacity
    FROM games g
    LEFT JOIN bookings b    ON b.game_id  = g.id
    LEFT JOIN game_fills gf ON gf.game_id = g.id
    WHERE g.club_id    = p_club_id
      AND g.status    != 'cancelled'
      AND g.date_time >= v_range_start
      AND g.date_time <= v_retro_end
    GROUP BY
      g.id, g.title, g.max_spots, g.skill_level, g.game_format, g.venue_id,
      dow, hod, gf.ttf_minutes
  ),
  -- Aggregate instances into patterns:
  --   same LOWER(TRIM(title)) + dow + hod + skill_level + game_format + venue_id
  patterns AS (
    SELECT
      MIN(gs.title)                                                  AS game_title,
      gs.dow                                                         AS day_of_week,
      gs.hod                                                         AS hour_of_day,
      COUNT(*)::BIGINT                                               AS occurrence_count,
      -- Instances that reached capacity (ttf_minutes IS NOT NULL)
      COUNT(*) FILTER (WHERE gs.ttf_minutes IS NOT NULL)::BIGINT    AS filled_occurrence_count,
      ROUND(AVG(gs.confirmed_count), 1)                              AS avg_confirmed,
      -- Most-common capacity for display
      MODE() WITHIN GROUP (ORDER BY gs.max_spots)                    AS max_spots,
      ROUND(AVG(
        CASE WHEN gs.max_spots IS NOT NULL AND gs.max_spots > 0
             THEN gs.confirmed_count::NUMERIC / gs.max_spots
             ELSE NULL END
      ), 4)                                                          AS avg_fill_rate,
      SUM(gs.revenue_cents)::BIGINT                                  AS total_revenue_cents,
      ROUND(AVG(gs.waitlist_count), 1)                               AS avg_waitlist,
      -- AVG ignores NULLs — only filled instances contribute.
      -- Result is NULL when no instances in this pattern ever filled.
      ROUND(AVG(gs.ttf_minutes))                                     AS avg_time_to_fill_minutes,
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
    p.filled_occurrence_count,
    p.avg_confirmed,
    p.max_spots,
    COALESCE(p.avg_fill_rate, 0),
    p.total_revenue_cents,
    COALESCE(p.avg_waitlist, 0),
    p.avg_time_to_fill_minutes,   -- intentionally NULL when no instances filled
    p.skill_level,
    p.game_format
  FROM patterns p
  -- Rank by demand strength (spec order); unfilled patterns fall behind filled ones.
  ORDER BY
    p.avg_confirmed            DESC,
    p.avg_fill_rate            DESC,
    p.avg_waitlist             DESC,
    p.filled_occurrence_count  DESC,
    p.avg_time_to_fill_minutes ASC NULLS LAST,
    p.occurrence_count         DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_top_games(UUID, INT, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
