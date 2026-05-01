-- Phase 5B-1 — Platform Revenue + Subscription Dashboard
-- Internal-only. Run in Supabase Dashboard SQL Editor (as postgres).
-- Safe to re-run (CREATE OR REPLACE / IF NOT EXISTS throughout).
--
-- WHAT IS CREATED:
--   1. platform_plan_config     — maps plan_type → monthly price (seed and update as needed)
--   2. v_active_subscriptions   — live count of active/trialing subs by tier + MRR
--   3. v_platform_revenue       — platform fee income from bookings by period
--   4. v_subscription_events    — recent subscription lifecycle changes (last 90 days)
--   5. v_club_growth            — new clubs per calendar week
--
-- ACCESS:
--   All views have SELECT revoked from anon and authenticated roles.
--   Query them only from Supabase Studio (postgres role) or service_role Edge Functions.
--   They must NEVER be called from the iOS app.
--
-- ASSUMPTION:
--   clubs.created_at column exists. If it does not, v_club_growth will fail.
--   Verify with: SELECT column_name FROM information_schema.columns
--               WHERE table_name = 'clubs' AND column_name = 'created_at';

-- ---------------------------------------------------------------------------
-- 1. platform_plan_config
--    Stores monthly subscription price per plan tier.
--    Update these rows when Stripe prices change — all MRR views recalculate.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS platform_plan_config (
  plan_type           TEXT PRIMARY KEY,   -- 'starter' | 'pro'
  monthly_price_cents INT  NOT NULL,      -- price in cents (e.g. 4900 = $49.00 AUD)
  currency            TEXT NOT NULL DEFAULT 'AUD',
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed with placeholder prices. Update with real Stripe prices before relying on MRR.
INSERT INTO platform_plan_config (plan_type, monthly_price_cents) VALUES
  ('starter', 4900),   -- update to match your Stripe starter price
  ('pro',     9900)    -- update to match your Stripe pro price
ON CONFLICT (plan_type) DO NOTHING;

-- Internal table — no public access.
ALTER TABLE platform_plan_config ENABLE ROW LEVEL SECURITY;
REVOKE SELECT, INSERT, UPDATE, DELETE ON platform_plan_config FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. v_active_subscriptions
--    Current snapshot of active and trialing subscriptions.
--    One row per plan tier showing count, MRR, and club names.
--
--    MRR = count(active/trialing clubs on tier) × monthly_price_cents / 100
--    Trialing clubs count toward MRR (they have a payment method on file).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_active_subscriptions AS
SELECT
  cs.plan_type,
  COUNT(*)                                                       AS subscriber_count,
  COALESCE(pc.monthly_price_cents, 0)                           AS monthly_price_cents,
  COALESCE(pc.currency, 'AUD')                                  AS currency,
  -- MRR in cents
  COUNT(*) * COALESCE(pc.monthly_price_cents, 0)                AS mrr_cents,
  -- MRR as formatted decimal
  ROUND(COUNT(*) * COALESCE(pc.monthly_price_cents, 0) / 100.0, 2)
                                                                 AS mrr,
  -- Status breakdown within this tier
  COUNT(CASE WHEN cs.status = 'active'   THEN 1 END)            AS active_count,
  COUNT(CASE WHEN cs.status = 'trialing' THEN 1 END)            AS trialing_count,
  -- Club names for easy identification
  STRING_AGG(c.name, ', ' ORDER BY c.name)                      AS club_names
FROM   club_subscriptions cs
JOIN   clubs               c  ON c.id = cs.club_id
LEFT JOIN platform_plan_config pc ON pc.plan_type = cs.plan_type
WHERE  cs.status IN ('active', 'trialing')
GROUP BY cs.plan_type, pc.monthly_price_cents, pc.currency
ORDER BY mrr_cents DESC;

REVOKE SELECT ON v_active_subscriptions FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. v_platform_revenue
--    Platform fee income from confirmed Stripe bookings.
--    Three rows: last 30 days, last 90 days, all time.
--
--    Only counts: bookings.status = 'confirmed' AND payment_method = 'stripe'
--    Currency: most common fee_currency across all paid bookings (defaults to 'AUD').
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_platform_revenue AS
WITH paid_bookings AS (
  SELECT
    b.platform_fee_cents,
    b.club_payout_cents,
    b.created_at
  FROM   bookings b
  JOIN   games    g ON g.id = b.game_id
  WHERE  b.status         = 'confirmed'
    AND  b.payment_method = 'stripe'
    AND  b.platform_fee_cents IS NOT NULL
),
currency_default AS (
  SELECT COALESCE(
    (SELECT g2.fee_currency
     FROM   games    g2
     JOIN   bookings b2 ON b2.game_id = g2.id
     WHERE  b2.status = 'confirmed' AND b2.payment_method = 'stripe'
       AND  g2.fee_currency IS NOT NULL
     GROUP BY g2.fee_currency
     ORDER BY COUNT(*) DESC
     LIMIT 1),
    'AUD'
  ) AS currency
)
SELECT
  period,
  booking_count,
  ROUND(total_platform_fee_cents / 100.0, 2)  AS platform_fee_revenue,
  ROUND(total_club_payout_cents  / 100.0, 2)  AS club_payout_total,
  (SELECT currency FROM currency_default)      AS currency
FROM (
  SELECT 'last_30_days'::TEXT AS period,
         COUNT(*)::INT        AS booking_count,
         COALESCE(SUM(platform_fee_cents), 0)::NUMERIC AS total_platform_fee_cents,
         COALESCE(SUM(club_payout_cents),  0)::NUMERIC AS total_club_payout_cents
  FROM paid_bookings
  WHERE created_at >= now() - INTERVAL '30 days'

  UNION ALL

  SELECT 'last_90_days',
         COUNT(*)::INT,
         COALESCE(SUM(platform_fee_cents), 0)::NUMERIC,
         COALESCE(SUM(club_payout_cents),  0)::NUMERIC
  FROM paid_bookings
  WHERE created_at >= now() - INTERVAL '90 days'

  UNION ALL

  SELECT 'all_time',
         COUNT(*)::INT,
         COALESCE(SUM(platform_fee_cents), 0)::NUMERIC,
         COALESCE(SUM(club_payout_cents),  0)::NUMERIC
  FROM paid_bookings
) periods
ORDER BY
  CASE period
    WHEN 'last_30_days' THEN 1
    WHEN 'last_90_days' THEN 2
    WHEN 'all_time'     THEN 3
  END;

REVOKE SELECT ON v_platform_revenue FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. v_subscription_events
--    Subscription rows that changed status in the last 90 days.
--    Ordered by most recently updated — scan for churn and new sign-ups.
--
--    Useful columns:
--      club_name, plan_type, status, current_period_end, updated_at
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_subscription_events AS
SELECT
  c.name                              AS club_name,
  cs.plan_type,
  cs.status,
  cs.current_period_end,
  cs.updated_at,
  -- Categorise for easier filtering
  CASE
    WHEN cs.status IN ('active', 'trialing')                 THEN 'paying'
    WHEN cs.status = 'past_due'                              THEN 'at_risk'
    WHEN cs.status IN ('canceled', 'incomplete_expired')     THEN 'churned'
    ELSE 'other'
  END                                 AS event_category
FROM   club_subscriptions cs
JOIN   clubs               c ON c.id = cs.club_id
WHERE  cs.updated_at >= now() - INTERVAL '90 days'
ORDER  BY cs.updated_at DESC;

REVOKE SELECT ON v_subscription_events FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. v_club_growth
--    New clubs created per calendar week.
--    Requires clubs.created_at to exist.
--
--    Verify first:
--      SELECT column_name FROM information_schema.columns
--      WHERE table_name = 'clubs' AND column_name = 'created_at';
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_club_growth AS
SELECT
  DATE_TRUNC('week', created_at)::DATE   AS week_starting,
  COUNT(*)::INT                          AS new_clubs,
  -- Running total (approximate — use ORDER BY week for accuracy)
  SUM(COUNT(*)) OVER (ORDER BY DATE_TRUNC('week', created_at))::INT
                                         AS running_total
FROM   clubs
WHERE  created_at IS NOT NULL
GROUP  BY DATE_TRUNC('week', created_at)
ORDER  BY week_starting DESC;

REVOKE SELECT ON v_club_growth FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- QUICK REFERENCE — paste into Studio SQL Editor to inspect each view
-- ---------------------------------------------------------------------------
--
-- Active subscriptions + MRR:
--   SELECT * FROM v_active_subscriptions;
--
-- Total MRR across all tiers:
--   SELECT SUM(mrr) AS total_mrr, SUM(mrr_cents) AS total_mrr_cents
--   FROM v_active_subscriptions;
--
-- Platform fee revenue:
--   SELECT * FROM v_platform_revenue;
--
-- Recent subscription events (churn / upgrades):
--   SELECT * FROM v_subscription_events WHERE event_category IN ('churned', 'at_risk');
--
-- Club growth last 12 weeks:
--   SELECT * FROM v_club_growth LIMIT 12;
--
-- Update plan prices when Stripe prices change:
--   UPDATE platform_plan_config SET monthly_price_cents = 5900 WHERE plan_type = 'starter';
