-- Analytics Revenue Breakdown — extends get_club_analytics_kpis
-- DROP required because the RETURNS TABLE signature changes (new columns).
DROP FUNCTION IF EXISTS get_club_analytics_kpis(UUID, INT);

--
-- Adds to the KPI response:
--   curr_gross_revenue_cents    — player-facing Stripe total (platform_fee + club_payout)
--   curr_platform_fee_cents     — app/platform fee portion of Stripe revenue
--   curr_credits_used_cents     — total credits_applied_cents on confirmed bookings
--   prev_gross_revenue_cents    — prior-period equivalents
--   prev_platform_fee_cents
--   prev_credits_used_cents
--   curr_cancelled_gross_cents  — gross of Stripe-paid bookings later cancelled in the period
--
-- Also fixes: prev_revenue_cents now correctly filters payment_method = 'stripe'
-- (Previously it summed all club_payout_cents; in practice the effect was zero since
--  non-Stripe payouts are always 0, but the filter is now consistent with curr_revenue_cents.)
--
-- Safe to re-run (CREATE OR REPLACE). All access checks are preserved.

CREATE OR REPLACE FUNCTION get_club_analytics_kpis(
  p_club_id UUID,
  p_days    INT DEFAULT 30
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
  -- Revenue breakdown additions
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
  -- Games in current period (past only — KPIs are retrospective)
  curr_games AS (
    SELECT g.id, g.max_spots
    FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_curr_start AND g.date_time <= now()
  ),
  -- Games in previous period
  prev_games AS (
    SELECT g.id, g.max_spots
    FROM games g
    WHERE g.club_id = p_club_id AND g.status != 'cancelled'
      AND g.date_time >= v_prev_start AND g.date_time < v_curr_start
  ),
  -- Confirmed bookings — current period
  curr_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents,    0) AS payout,
           COALESCE(b.platform_fee_cents,   0) AS platform_fee,
           COALESCE(b.credits_applied_cents,0) AS credits,
           b.payment_method
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM curr_games)
  ),
  -- Confirmed bookings — previous period
  prev_conf AS (
    SELECT b.id, b.user_id, b.game_id,
           COALESCE(b.club_payout_cents,    0) AS payout,
           COALESCE(b.platform_fee_cents,   0) AS platform_fee,
           COALESCE(b.credits_applied_cents,0) AS credits,
           b.payment_method
    FROM bookings b
    WHERE b.status = 'confirmed' AND b.game_id IN (SELECT id FROM prev_games)
  ),
  -- All bookings in current period (for cancellation rate and cancelled-revenue)
  curr_all AS (
    SELECT b.id, b.status,
           b.fee_paid,
           b.payment_method,
           COALESCE(b.platform_fee_cents, 0) + COALESCE(b.club_payout_cents, 0) AS gross
    FROM bookings b
    WHERE b.game_id IN (SELECT id FROM curr_games)
  ),
  -- Per-game fill data (current)
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
  -- Games each player attended (current period, for repeat rate)
  player_game_counts AS (
    SELECT user_id, COUNT(DISTINCT game_id) AS n
    FROM curr_conf GROUP BY user_id
  )
  SELECT
    -- ── Existing KPI columns ──────────────────────────────────────────────────
    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,
    COALESCE((SELECT COUNT(id)   FROM curr_conf), 0)::BIGINT,
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM curr_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM curr_fills)::NUMERIC
                  / (SELECT SUM(max_spots) FROM curr_fills), 4)
         ELSE 0::NUMERIC END,
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0)::BIGINT,

    -- Previous period revenue (now correctly filtered to Stripe only)
    COALESCE((SELECT SUM(payout) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,
    COALESCE((SELECT COUNT(id)   FROM prev_conf), 0)::BIGINT,
    CASE WHEN COALESCE((SELECT SUM(max_spots) FROM prev_fills), 0) > 0
         THEN ROUND((SELECT SUM(conf) FROM prev_fills)::NUMERIC
                  / (SELECT SUM(max_spots) FROM prev_fills), 4)
         ELSE 0::NUMERIC END,
    COALESCE((SELECT COUNT(DISTINCT user_id) FROM prev_conf), 0)::BIGINT,

    CASE WHEN (SELECT COUNT(*) FROM curr_all) > 0
         THEN ROUND(
           (SELECT COUNT(*) FROM curr_all WHERE status = 'cancelled')::NUMERIC
           / (SELECT COUNT(*) FROM curr_all), 4)
         ELSE 0::NUMERIC END,

    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf) > 0
         THEN ROUND(
           (SELECT COUNT(*) FROM player_game_counts WHERE n > 1)::NUMERIC
           / NULLIF((SELECT COUNT(DISTINCT user_id) FROM curr_conf), 0), 4)
         ELSE 0::NUMERIC END,

    COALESCE(
      (SELECT g2.fee_currency FROM games g2
       JOIN bookings b2 ON b2.game_id = g2.id
       WHERE g2.club_id = p_club_id AND b2.payment_method = 'stripe' AND g2.fee_currency IS NOT NULL
       ORDER BY b2.created_at DESC LIMIT 1),
      'AUD'
    ),
    now(),

    -- ── Revenue breakdown additions ───────────────────────────────────────────

    -- Gross Stripe revenue (what players actually paid)
    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,

    -- Platform/app fee portion
    COALESCE((SELECT SUM(platform_fee) FILTER (WHERE payment_method = 'stripe') FROM curr_conf), 0)::BIGINT,

    -- Credits applied across all confirmed bookings (Stripe + credit-only)
    COALESCE((SELECT SUM(credits) FROM curr_conf), 0)::BIGINT,

    -- Previous period: gross Stripe revenue
    COALESCE((SELECT SUM(platform_fee + payout) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,

    -- Previous period: platform fee
    COALESCE((SELECT SUM(platform_fee) FILTER (WHERE payment_method = 'stripe') FROM prev_conf), 0)::BIGINT,

    -- Previous period: credits used
    COALESCE((SELECT SUM(credits) FROM prev_conf), 0)::BIGINT,

    -- Gross of Stripe-paid bookings that were cancelled in the period
    -- (represents revenue that was returned as club credits to players)
    COALESCE((SELECT SUM(gross) FROM curr_all
              WHERE status = 'cancelled'
                AND fee_paid = true
                AND payment_method = 'stripe'), 0)::BIGINT

  FROM (SELECT 1) AS d;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_kpis(UUID, INT) TO authenticated;
