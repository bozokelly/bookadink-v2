-- Analytics: Fix misleading "Refunded" metric
--
-- Problem: curr_cancelled_gross_cents was labelled "Refunded" in the iOS dashboard,
-- implying Stripe cash was returned to players. This is incorrect.
-- BookaDink has no Stripe cash refund flow. When an eligible booking is cancelled,
-- the player receives CLUB CREDITS — not a Stripe reversal.
--
-- The underlying SQL logic was always correct (summing cancelled Stripe gross as
-- "credit refund exposure"), but the column names implied cash refunds.
--
-- Fix: rename columns so the name matches the actual semantics:
--   curr_cancelled_gross_cents  → curr_credits_returned_cents
--   curr_refund_count           → curr_credit_return_count
--
-- SQL logic is UNCHANGED — only column names change.
--
-- Callers must decode "curr_credits_returned_cents" / "curr_credit_return_count"
-- instead of the old names. Old names are dropped with the function.
--
-- IMPORTANT: there is no Stripe cash refund architecture.
--   curr_credits_returned_cents = SUM(platform_fee + club_payout) for
--     status='cancelled' AND fee_paid=true AND payment_method='stripe'
--   This equals the gross Stripe amount returned as club credits.
--   Cash refunds = $0 always. Do NOT reintroduce a "Refunded" metric unless
--   a Stripe refund webhook is persisted to a dedicated table.

DROP FUNCTION IF EXISTS get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION get_club_analytics_kpis(
  p_club_id    UUID,
  p_days       INT         DEFAULT 30,
  p_start_date TIMESTAMPTZ DEFAULT NULL,
  p_end_date   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  curr_revenue_cents           BIGINT,   -- total club net revenue: Stripe payout + cash
  curr_booking_count           BIGINT,
  curr_fill_rate               NUMERIC,
  curr_active_players          BIGINT,
  prev_revenue_cents           BIGINT,   -- total club net revenue prior period
  prev_booking_count           BIGINT,
  prev_fill_rate               NUMERIC,
  prev_active_players          BIGINT,
  cancellation_rate            NUMERIC,
  repeat_player_rate           NUMERIC,
  currency                     TEXT,
  as_of                        TIMESTAMPTZ,
  curr_gross_revenue_cents     BIGINT,   -- player-facing total: Stripe gross + cash
  curr_platform_fee_cents      BIGINT,   -- platform fee (Stripe only, no fee on cash)
  curr_credits_used_cents      BIGINT,
  prev_gross_revenue_cents     BIGINT,
  prev_platform_fee_cents      BIGINT,
  prev_credits_used_cents      BIGINT,
  -- Renamed from curr_cancelled_gross_cents: credits returned to players (NOT a Stripe cash refund)
  curr_credits_returned_cents  BIGINT,
  -- Renamed from curr_refund_count: count of cancellations that triggered a credit return
  curr_credit_return_count     BIGINT,
  curr_manual_revenue_cents    BIGINT,   -- cash revenue current period
  prev_manual_revenue_cents    BIGINT    -- cash revenue prior period
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

    -- curr_gross_revenue_cents: player-facing total (Stripe gross + cash)
    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') + SUM(manual_revenue) FROM curr_conf), 0)::BIGINT,
    -- platform fee remains Stripe-only
    COALESCE((SELECT SUM(platform_fee) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(credits) FROM curr_conf), 0)::BIGINT,

    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') + SUM(manual_revenue) FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(platform_fee) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(credits) FROM prev_conf), 0)::BIGINT,

    -- curr_credits_returned_cents: gross of Stripe-paid bookings cancelled in period.
    -- This is the amount returned to players as CLUB CREDITS — NOT a Stripe cash refund.
    -- Cash refunds do not exist in this system. Do not rename this back to "refunded".
    COALESCE((SELECT SUM(gross) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT,

    -- curr_credit_return_count: number of cancellations that triggered a club-credit return.
    COALESCE((SELECT COUNT(*) FROM curr_all
              WHERE status = 'cancelled' AND fee_paid = true AND payment_method = 'stripe'), 0)::BIGINT,

    -- Manual/cash revenue breakdown
    COALESCE((SELECT SUM(manual_revenue) FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT SUM(manual_revenue) FROM prev_conf), 0)::BIGINT

  FROM (SELECT 1) AS d;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
