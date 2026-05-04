-- Analytics: Revenue Session Breakdown — booking type counts
--
-- Extends get_club_analytics_kpis with:
--   curr_refund_count BIGINT  — Stripe-paid bookings that were cancelled in the period
--                               (these generate club-credit refunds to players)
--
-- Extends get_club_analytics_supplemental with:
--   curr_credit_booking_count  BIGINT  — confirmed bookings paid entirely by credits
--   curr_comp_booking_count    BIGINT  — confirmed comp/admin bookings (payment_method='admin')
--   curr_truly_free_booking_count BIGINT — confirmed bookings on free games (payment_method IS NULL)
--
-- Payment method taxonomy (from CLAUDE.md):
--   'stripe'  — card / Apple Pay (may have credits partially applied)
--   'credits' — paid entirely with credits, no Stripe charge
--   'admin'   — owner-added comp booking, no charge
--   NULL      — self-booked free game
--
-- No double-counting: a mixed Stripe+credits booking is counted only as 'stripe'.
-- curr_refund_count counts only the Stripe-paid cancellations (credits refunds).
-- The three new supplemental fields partition the non-stripe bookings.
--
-- DROP required because RETURNS TABLE adds new columns.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_club_analytics_kpis  (+curr_refund_count)
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);

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
  curr_cancelled_gross_cents  BIGINT,
  curr_refund_count           BIGINT    -- Stripe-paid cancellations → club-credit refunds
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

    -- Gross of Stripe-paid bookings cancelled in period (represents credit refund exposure)
    COALESCE((SELECT SUM(gross) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT,

    -- Count of Stripe-paid cancellations (one per credit-refund event)
    COALESCE((SELECT COUNT(*) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT

  FROM (SELECT 1) AS d;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_club_analytics_supplemental  (+3 booking-type counts)
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
  curr_paid_bookings            BIGINT,
  curr_free_bookings            BIGINT,
  avg_rev_per_player_cents      BIGINT,
  curr_no_show_rate             NUMERIC,
  curr_credit_booking_count     BIGINT,  -- confirmed bookings paid entirely with credits
  curr_comp_booking_count       BIGINT,  -- confirmed comp/admin bookings (no charge)
  curr_truly_free_booking_count BIGINT   -- confirmed bookings on free games (no payment method)
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
         ELSE NULL END,

    -- Booking type breakdown (partitions non-stripe confirmed bookings)
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'credits')::BIGINT,
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'admin')::BIGINT,
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method IS NULL)::BIGINT;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_supplemental(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
