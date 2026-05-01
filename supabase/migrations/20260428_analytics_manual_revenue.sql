-- Analytics: Manual/Cash Revenue Inclusion
--
-- Problem: analytics RPCs counted only payment_method='stripe' for revenue.
-- Cash/manual payments (payment_method='cash', fee_paid=true) were excluded,
-- even though they represent real money received by the club.
--
-- Fix: include cash-paid bookings in all revenue metrics. For cash bookings,
-- club_payout_cents=0 (never populated by Stripe), so revenue is derived
-- from games.fee_amount (the game's listed fee) converted to cents.
--
-- Revenue taxonomy after this migration:
--   Stripe revenue  = SUM(club_payout_cents)      WHERE payment_method='stripe'
--   Cash revenue    = SUM(fee_amount * 100)        WHERE payment_method='cash' AND fee_paid=true
--   Total revenue   = Stripe revenue + Cash revenue  ← curr_revenue_cents (primary KPI)
--   Gross revenue   = SUM(platform_fee+payout)Stripe + Cash revenue
--   Platform fee    = SUM(platform_fee_cents)      WHERE payment_method='stripe'  (unchanged)
--   Credits         = SUM(credits_applied_cents)   all confirmed                  (unchanged)
--   Cancellations   = Stripe-paid cancelled only                                  (unchanged)
--
-- New return columns added to get_club_analytics_kpis:
--   curr_manual_revenue_cents  — cash revenue current period
--   prev_manual_revenue_cents  — cash revenue prior period
--
-- New return column added to get_club_analytics_supplemental:
--   curr_cash_booking_count    — count of cash-paid confirmed bookings
--
-- Also fixes get_club_revenue_trend and get_club_top_games.
-- All DROPs are IF EXISTS — safe to re-run.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_club_analytics_kpis
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION get_club_analytics_kpis(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  curr_revenue_cents          BIGINT,   -- total club revenue: Stripe net + cash
  curr_booking_count          BIGINT,
  curr_fill_rate              NUMERIC,
  curr_active_players         BIGINT,
  prev_revenue_cents          BIGINT,   -- total club revenue prior period
  prev_booking_count          BIGINT,
  prev_fill_rate              NUMERIC,
  prev_active_players         BIGINT,
  cancellation_rate           NUMERIC,
  repeat_player_rate          NUMERIC,
  currency                    TEXT,
  as_of                       TIMESTAMPTZ,
  curr_gross_revenue_cents    BIGINT,   -- player-facing total: Stripe gross + cash
  curr_platform_fee_cents     BIGINT,   -- platform fee (Stripe only, no fee on cash)
  curr_credits_used_cents     BIGINT,
  prev_gross_revenue_cents    BIGINT,
  prev_platform_fee_cents     BIGINT,
  prev_credits_used_cents     BIGINT,
  curr_cancelled_gross_cents  BIGINT,   -- Stripe-paid cancelled bookings (credit refund exposure)
  curr_refund_count           BIGINT,   -- count of Stripe-paid cancellations
  curr_manual_revenue_cents   BIGINT,   -- cash revenue current period
  prev_manual_revenue_cents   BIGINT    -- cash revenue prior period
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
  -- Join games to get fee_amount for cash revenue calculation.
  -- manual_revenue: for cash bookings (payment_method='cash', fee_paid=true),
  -- revenue = game fee in cents (full fee goes to club, no platform cut).
  curr_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents,    0) AS payout,
           COALESCE(b.platform_fee_cents,   0) AS platform_fee,
           COALESCE(b.credits_applied_cents,0) AS credits,
           b.payment_method,
           b.fee_paid,
           CASE WHEN b.payment_method = 'cash' AND b.fee_paid = true
                THEN (COALESCE(g.fee_amount, 0) * 100)::BIGINT
                ELSE 0
           END AS manual_revenue
    FROM bookings b
    JOIN games g ON g.id = b.game_id
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM curr_games)
  ),
  prev_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents,    0) AS payout,
           COALESCE(b.platform_fee_cents,   0) AS platform_fee,
           COALESCE(b.credits_applied_cents,0) AS credits,
           b.payment_method,
           b.fee_paid,
           CASE WHEN b.payment_method = 'cash' AND b.fee_paid = true
                THEN (COALESCE(g.fee_amount, 0) * 100)::BIGINT
                ELSE 0
           END AS manual_revenue
    FROM bookings b
    JOIN games g ON g.id = b.game_id
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
    -- curr_revenue_cents: total club net revenue (Stripe payout + cash received)
    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') + SUM(manual_revenue) FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT COUNT(id) FROM curr_conf), 0)::BIGINT,
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM curr_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM curr_fills)::NUMERIC / (SELECT SUM(max_spots) FROM curr_fills), 4)
         ELSE 0::NUMERIC END,
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0)::BIGINT,

    -- prev_revenue_cents: total club net revenue prior period
    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') + SUM(manual_revenue) FROM prev_conf), 0)::BIGINT,
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

    -- curr_gross_revenue_cents: player-facing total (Stripe gross + cash amount paid)
    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') + SUM(manual_revenue) FROM curr_conf), 0)::BIGINT,
    -- platform fee remains Stripe-only (no platform cut on cash)
    COALESCE((SELECT SUM(platform_fee) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(credits) FROM curr_conf), 0)::BIGINT,

    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') + SUM(manual_revenue) FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(platform_fee) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(credits) FROM prev_conf), 0)::BIGINT,

    -- Stripe-paid cancellations (credit refund exposure — cash cancellations handled manually)
    COALESCE((SELECT SUM(gross) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT,
    COALESCE((SELECT COUNT(*) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT,

    -- Manual/cash revenue breakdown (separable from Stripe)
    COALESCE((SELECT SUM(manual_revenue) FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(manual_revenue) FROM prev_conf), 0)::BIGINT

  FROM (SELECT 1) AS d;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_club_analytics_supplemental
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_analytics_supplemental(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION get_club_analytics_supplemental(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  curr_member_joins             BIGINT,
  prev_member_joins             BIGINT,
  total_active_members          BIGINT,
  curr_new_players              BIGINT,
  curr_game_count               BIGINT,
  curr_no_show_count            BIGINT,
  curr_checked_count            BIGINT,
  curr_waitlist_count           BIGINT,
  curr_paid_bookings            BIGINT,   -- Stripe + cash-paid confirmed bookings
  curr_free_bookings            BIGINT,   -- credits, comp/admin, and free-game bookings
  avg_rev_per_player_cents      BIGINT,   -- (Stripe payout + cash revenue) / distinct paying players
  curr_no_show_rate             NUMERIC,
  curr_credit_booking_count     BIGINT,
  curr_comp_booking_count       BIGINT,
  curr_truly_free_booking_count BIGINT,
  curr_cash_booking_count       BIGINT    -- cash-paid confirmed bookings
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
    SELECT g.id FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_range_start AND g.date_time < v_range_end
  ),
  prev_games AS (
    SELECT g.id FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_prev_start AND g.date_time < v_range_start
  ),
  curr_past_games AS (
    SELECT g.id FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_range_start AND g.date_time <= v_retro_end
  ),
  curr_conf AS (
    SELECT b.user_id, b.game_id, b.payment_method,
           COALESCE(b.club_payout_cents, 0) AS payout,
           b.fee_paid,
           CASE WHEN b.payment_method = 'cash' AND b.fee_paid = true
                THEN (COALESCE(g.fee_amount, 0) * 100)::BIGINT
                ELSE 0
           END AS manual_revenue,
           b.created_at
    FROM bookings b
    JOIN games g ON g.id = b.game_id
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

    -- curr_paid_bookings: Stripe + cash (real money received by club)
    (SELECT COUNT(*) FROM curr_conf
     WHERE payment_method = 'stripe' OR (payment_method = 'cash' AND fee_paid = true))::BIGINT,

    -- curr_free_bookings: credits, comp/admin, and free-game bookings
    (SELECT COUNT(*) FROM curr_conf
     WHERE NOT (payment_method = 'stripe' OR (payment_method = 'cash' AND fee_paid = true)))::BIGINT,

    -- avg revenue per paying player (Stripe payout + cash revenue)
    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf
               WHERE payment_method = 'stripe' OR (payment_method = 'cash' AND fee_paid = true)) > 0
         THEN ROUND(
           ((SELECT SUM(payout) FROM curr_conf WHERE payment_method = 'stripe') +
            (SELECT SUM(manual_revenue) FROM curr_conf))::NUMERIC
           / (SELECT COUNT(DISTINCT user_id) FROM curr_conf
              WHERE payment_method = 'stripe' OR (payment_method = 'cash' AND fee_paid = true))
         )::BIGINT
         ELSE 0::BIGINT END,

    CASE WHEN (SELECT checked_cnt FROM att) > 0
         THEN ROUND((SELECT no_show_cnt FROM att)::NUMERIC / (SELECT checked_cnt FROM att), 4)
         ELSE NULL END,

    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'credits')::BIGINT,
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'admin')::BIGINT,
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method IS NULL)::BIGINT,

    -- cash-paid bookings (separable from Stripe in breakdown views)
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'cash' AND fee_paid = true)::BIGINT;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_supplemental(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_club_revenue_trend
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_revenue_trend(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);

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

  IF (v_retro_end - v_range_start) <= INTERVAL '30 days' THEN
    RETURN QUERY
    WITH
    day_series AS (
      SELECT generate_series(v_range_start::DATE, v_retro_end::DATE, '1 day'::INTERVAL)::DATE AS d
    ),
    game_stats AS (
      SELECT
        g.date_time::DATE AS d, g.id, g.max_spots,
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed') AS conf,
        -- Stripe club payout + cash fee amount = total club revenue per game
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) +
        COALESCE(SUM(
          CASE WHEN b.status = 'confirmed' AND b.payment_method = 'cash' AND b.fee_paid = true
               THEN (COALESCE(g.fee_amount, 0) * 100)::BIGINT
               ELSE 0
          END), 0) AS rev
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
               SUM(gs.conf)      FILTER (WHERE gs.max_spots IS NOT NULL AND gs.max_spots > 0)::NUMERIC
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
        COUNT(b.id) FILTER (WHERE b.status = 'confirmed') AS conf,
        COALESCE(SUM(b.club_payout_cents)
          FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) +
        COALESCE(SUM(
          CASE WHEN b.status = 'confirmed' AND b.payment_method = 'cash' AND b.fee_paid = true
               THEN (COALESCE(g.fee_amount, 0) * 100)::BIGINT
               ELSE 0
          END), 0) AS rev
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
-- 4. get_club_top_games
-- ─────────────────────────────────────────────────────────────────────────────
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
  filled_occurrence_count  BIGINT,
  avg_confirmed            NUMERIC,
  max_spots                INT,
  avg_fill_rate            NUMERIC,
  total_revenue_cents      BIGINT,
  avg_waitlist             NUMERIC,
  avg_time_to_fill_minutes NUMERIC,
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
  game_fills AS (
    SELECT
      rc.game_id,
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
      AND rc.rn       = g.max_spots
      AND rc.filled_at > COALESCE(g.publish_at, g.created_at)
  ),
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
      COUNT(b.id) FILTER (WHERE b.status = 'confirmed')                            AS confirmed_count,
      COUNT(b.id) FILTER (WHERE b.status IN ('waitlisted', 'pending_payment'))     AS waitlist_count,
      -- total revenue: Stripe club payout + cash received
      COALESCE(SUM(b.club_payout_cents)
        FILTER (WHERE b.status = 'confirmed' AND b.payment_method = 'stripe'), 0) +
      COALESCE(SUM(
        CASE WHEN b.status = 'confirmed' AND b.payment_method = 'cash' AND b.fee_paid = true
             THEN (COALESCE(g.fee_amount, 0) * 100)::BIGINT
             ELSE 0
        END), 0)                                                                    AS revenue_cents,
      gf.ttf_minutes
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
  patterns AS (
    SELECT
      MIN(gs.title)                                                  AS game_title,
      gs.dow                                                         AS day_of_week,
      gs.hod                                                         AS hour_of_day,
      COUNT(*)::BIGINT                                               AS occurrence_count,
      COUNT(*) FILTER (WHERE gs.ttf_minutes IS NOT NULL)::BIGINT    AS filled_occurrence_count,
      ROUND(AVG(gs.confirmed_count), 1)                              AS avg_confirmed,
      MODE() WITHIN GROUP (ORDER BY gs.max_spots)                    AS max_spots,
      ROUND(AVG(
        CASE WHEN gs.max_spots IS NOT NULL AND gs.max_spots > 0
             THEN gs.confirmed_count::NUMERIC / gs.max_spots
             ELSE NULL END
      ), 4)                                                          AS avg_fill_rate,
      SUM(gs.revenue_cents)::BIGINT                                  AS total_revenue_cents,
      ROUND(AVG(gs.waitlist_count), 1)                               AS avg_waitlist,
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
    p.avg_time_to_fill_minutes,
    p.skill_level,
    p.game_format
  FROM patterns p
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
