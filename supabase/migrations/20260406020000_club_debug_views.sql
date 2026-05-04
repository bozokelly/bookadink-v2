-- Phase 5C-1 — Per-Club Debug / Support Views
-- Internal-only. Run in Supabase Dashboard SQL Editor (as postgres).
-- Safe to re-run (CREATE OR REPLACE throughout).
-- Read-only. No data is modified.
--
-- WHAT IS CREATED:
--   1. v_club_debug_summary         — one row per club: identity + entitlements +
--                                     subscription + connect + live usage + limit status
--   2. get_club_recent_games(UUID)  — last 10 games for a club with booking counts
--   3. get_club_recent_bookings(UUID) — last 20 bookings across all games for a club
--
-- ACCESS:
--   v_club_debug_summary — SELECT revoked from anon/authenticated.
--                          Query from Studio or service_role only.
--   RPCs — EXECUTE granted to service_role for Edge Function access if needed.
--          Always callable from Studio (postgres role = superuser).
--
-- PRE-CHECK REQUIRED BEFORE RUNNING:
--   clubs.created_at is referenced in v_club_debug_summary.
--   If this column does not exist, CREATE VIEW will FAIL at compile time —
--   PostgreSQL does NOT silently substitute NULL for missing columns.
--
--   Run this first:
--     SELECT column_name FROM information_schema.columns
--     WHERE table_name = 'clubs' AND column_name = 'created_at';
--
--   If zero rows returned, choose one of:
--     Option A (preferred) — add the column, then run this migration:
--       ALTER TABLE clubs ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
--       (existing rows will receive now() as their value)
--
--     Option B — use the alternate view at the bottom of this file that omits created_at.
--
-- OTHER ASSUMPTIONS:
--   clubs.created_by      — confirmed (used in iOS queries)
--   club_members.status   — 'approved' | 'pending' confirmed in SupabaseService
--   profiles.full_name    — confirmed in SupabaseService select strings
--   club_stripe_accounts  — columns: club_id, stripe_account_id,
--                           onboarding_complete, payouts_enabled confirmed in connect-onboarding function
--   club_members.status   — 'approved' | 'pending' | etc.
--   profiles.full_name    — confirmed from SupabaseService select strings
--   club_stripe_accounts  — columns: club_id, stripe_account_id,
--                           onboarding_complete, payouts_enabled

-- ---------------------------------------------------------------------------
-- 1. v_club_debug_summary
--
--    One row per club. LEFT JOINs so clubs with missing entitlements,
--    subscriptions, or Stripe accounts still appear.
--
--    Designed for: SELECT * FROM v_club_debug_summary WHERE club_id = 'xxx';
--    or:           SELECT * FROM v_club_debug_summary WHERE club_name ILIKE '%foo%';
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_club_debug_summary AS

WITH active_games AS (
  -- Pre-aggregate active game count per club to avoid repeated correlated subqueries.
  SELECT club_id, COUNT(*)::INT AS count
  FROM   games
  WHERE  status    != 'cancelled'
    AND  date_time  > now()
  GROUP  BY club_id
),
approved_members AS (
  -- Pre-aggregate approved member count per club.
  SELECT club_id, COUNT(*)::INT AS count
  FROM   club_members
  WHERE  status = 'approved'
  GROUP  BY club_id
)

SELECT
  -- ── Identity ────────────────────────────────────────────────────────────
  c.id                                         AS club_id,
  c.name                                       AS club_name,
  c.created_at,
  c.created_by,

  -- ── Entitlements snapshot ───────────────────────────────────────────────
  ce.plan_tier,
  ce.analytics_access,
  ce.can_accept_payments,
  ce.max_active_games,
  ce.max_members,
  ce.updated_at                                AS entitlements_updated_at,

  -- ── Subscription snapshot ───────────────────────────────────────────────
  cs.stripe_subscription_id,
  cs.plan_type,
  cs.status                                    AS subscription_status,
  cs.current_period_end,

  -- ── Stripe Connect snapshot ─────────────────────────────────────────────
  csa.stripe_account_id,
  csa.onboarding_complete                      AS stripe_onboarding_complete,
  csa.payouts_enabled                          AS stripe_payouts_enabled,

  -- ── Live usage ──────────────────────────────────────────────────────────
  COALESCE(ag.count, 0)                        AS active_game_count,
  COALESCE(am.count, 0)                        AS approved_member_count,

  -- ── Limit status — instantly shows if club is blocked or approaching limit
  CASE
    WHEN ce.max_active_games IS NULL THEN 'no_entitlements'
    WHEN ce.max_active_games = -1    THEN 'unlimited'
    WHEN COALESCE(ag.count, 0) >= ce.max_active_games THEN 'AT_LIMIT'
    WHEN COALESCE(ag.count, 0) >= ce.max_active_games - 1 THEN 'near_limit'
    ELSE 'ok'
  END                                          AS active_games_limit_status,

  CASE
    WHEN ce.max_members IS NULL THEN 'no_entitlements'
    WHEN ce.max_members = -1    THEN 'unlimited'
    WHEN COALESCE(am.count, 0) >= ce.max_members THEN 'AT_LIMIT'
    WHEN COALESCE(am.count, 0) >= ce.max_members - 1 THEN 'near_limit'
    ELSE 'ok'
  END                                          AS member_limit_status

FROM   clubs               c
LEFT JOIN club_entitlements  ce  ON ce.club_id  = c.id
LEFT JOIN club_subscriptions cs  ON cs.club_id  = c.id
LEFT JOIN club_stripe_accounts csa ON csa.club_id = c.id
LEFT JOIN active_games       ag  ON ag.club_id  = c.id
LEFT JOIN approved_members   am  ON am.club_id  = c.id

ORDER BY c.name;

-- Revoke public access — operator queries via Studio or service_role only.
REVOKE SELECT ON v_club_debug_summary FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. get_club_recent_games(p_club_id UUID)
--
--    Last 10 games for a club ordered by date descending.
--    Includes per-game booking breakdown (confirmed / cancelled / total).
--    Useful for: "what games has this club run recently and how full were they?"
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_club_recent_games(p_club_id UUID)
RETURNS TABLE (
  game_id             UUID,
  title               TEXT,
  date_time           TIMESTAMPTZ,
  status              TEXT,
  max_spots           INT,
  publish_at          TIMESTAMPTZ,
  confirmed_count     INT,
  cancelled_count     INT,
  total_bookings      INT,
  fill_pct            NUMERIC    -- confirmed / max_spots as 0.0–1.0; NULL if max_spots <= 0
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g.id                                                          AS game_id,
    g.title,
    g.date_time,
    g.status,
    g.max_spots,
    g.publish_at,
    COUNT(CASE WHEN b.status = 'confirmed'  THEN 1 END)::INT     AS confirmed_count,
    COUNT(CASE WHEN b.status = 'cancelled'  THEN 1 END)::INT     AS cancelled_count,
    COUNT(b.id)::INT                                              AS total_bookings,
    CASE
      WHEN g.max_spots > 0
      THEN ROUND(
             COUNT(CASE WHEN b.status = 'confirmed' THEN 1 END)::NUMERIC
             / g.max_spots,
             4
           )
      ELSE NULL
    END                                                           AS fill_pct
  FROM   games    g
  LEFT JOIN bookings b ON b.game_id = g.id
  WHERE  g.club_id = p_club_id
  GROUP  BY g.id, g.title, g.date_time, g.status, g.max_spots, g.publish_at
  ORDER  BY g.date_time DESC
  LIMIT  10;
$$;

GRANT EXECUTE ON FUNCTION get_club_recent_games(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. get_club_recent_bookings(p_club_id UUID)
--
--    Last 20 bookings across all games for a club, ordered by created_at desc.
--    Joins to games for title/date and profiles for player name.
--    Useful for: "what payment activity has happened here / why is this booking broken?"
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_club_recent_bookings(p_club_id UUID)
RETURNS TABLE (
  booking_id              UUID,
  game_id                 UUID,
  game_title              TEXT,
  game_date               TIMESTAMPTZ,
  user_id                 UUID,
  player_name             TEXT,
  booking_status          TEXT,
  payment_method          TEXT,
  fee_paid                BOOL,
  club_payout_cents       INT,
  platform_fee_cents      INT,
  credits_applied_cents   INT,
  booking_created_at      TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    b.id                    AS booking_id,
    g.id                    AS game_id,
    g.title                 AS game_title,
    g.date_time             AS game_date,
    b.user_id,
    p.full_name             AS player_name,
    b.status                AS booking_status,
    b.payment_method,
    b.fee_paid,
    b.club_payout_cents,
    b.platform_fee_cents,
    b.credits_applied_cents,
    b.created_at            AS booking_created_at
  FROM   bookings  b
  JOIN   games     g ON g.id  = b.game_id
  LEFT JOIN profiles p ON p.id = b.user_id
  WHERE  g.club_id = p_club_id
  ORDER  BY b.created_at DESC
  LIMIT  20;
$$;

GRANT EXECUTE ON FUNCTION get_club_recent_bookings(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- QUICK REFERENCE — paste into Studio SQL Editor
-- ---------------------------------------------------------------------------
--
-- Full snapshot for a specific club (replace UUID):
--   SELECT * FROM v_club_debug_summary
--   WHERE club_id = '00000000-0000-0000-0000-000000000000';
--
-- Find a club by name (partial match):
--   SELECT * FROM v_club_debug_summary
--   WHERE club_name ILIKE '%sunset%';
--
-- Show all clubs at their active-game limit:
--   SELECT club_id, club_name, active_game_count, max_active_games
--   FROM v_club_debug_summary
--   WHERE active_games_limit_status = 'AT_LIMIT';
--
-- Show all clubs with no entitlement row (likely new clubs before migration ran):
--   SELECT club_id, club_name FROM v_club_debug_summary
--   WHERE plan_tier IS NULL;
--
-- Show all clubs with past_due or incomplete subscription:
--   SELECT club_id, club_name, subscription_status, current_period_end
--   FROM v_club_debug_summary
--   WHERE subscription_status IN ('past_due', 'incomplete');
--
-- Recent games for a club:
--   SELECT * FROM get_club_recent_games('00000000-0000-0000-0000-000000000000');
--
-- Recent bookings for a club (payment audit trail):
--   SELECT * FROM get_club_recent_bookings('00000000-0000-0000-0000-000000000000');
--
-- Payment breakdown for a club (totals from recent 20):
--   SELECT
--     payment_method,
--     COUNT(*) AS count,
--     SUM(club_payout_cents)     AS total_payout_cents,
--     SUM(platform_fee_cents)    AS total_platform_cents,
--     SUM(credits_applied_cents) AS total_credits_cents
--   FROM get_club_recent_bookings('00000000-0000-0000-0000-000000000000')
--   GROUP BY payment_method;

-- ---------------------------------------------------------------------------
-- OPTION B — alternate v_club_debug_summary WITHOUT clubs.created_at
--
-- Use ONLY if clubs.created_at does not exist and you cannot add the column.
-- Drop the primary view first if it was already created:
--   DROP VIEW IF EXISTS v_club_debug_summary;
-- Then run this block.
-- ---------------------------------------------------------------------------

/*
CREATE OR REPLACE VIEW v_club_debug_summary AS

WITH active_games AS (
  SELECT club_id, COUNT(*)::INT AS count
  FROM   games
  WHERE  status    != 'cancelled'
    AND  date_time  > now()
  GROUP  BY club_id
),
approved_members AS (
  SELECT club_id, COUNT(*)::INT AS count
  FROM   club_members
  WHERE  status = 'approved'
  GROUP  BY club_id
)

SELECT
  c.id                                         AS club_id,
  c.name                                       AS club_name,
  -- created_at omitted: column does not exist in clubs table
  c.created_by,
  ce.plan_tier,
  ce.analytics_access,
  ce.can_accept_payments,
  ce.max_active_games,
  ce.max_members,
  ce.updated_at                                AS entitlements_updated_at,
  cs.stripe_subscription_id,
  cs.plan_type,
  cs.status                                    AS subscription_status,
  cs.current_period_end,
  csa.stripe_account_id,
  csa.onboarding_complete                      AS stripe_onboarding_complete,
  csa.payouts_enabled                          AS stripe_payouts_enabled,
  COALESCE(ag.count, 0)                        AS active_game_count,
  COALESCE(am.count, 0)                        AS approved_member_count,
  CASE
    WHEN ce.max_active_games IS NULL THEN 'no_entitlements'
    WHEN ce.max_active_games = -1    THEN 'unlimited'
    WHEN COALESCE(ag.count, 0) >= ce.max_active_games THEN 'AT_LIMIT'
    WHEN COALESCE(ag.count, 0) >= ce.max_active_games - 1 THEN 'near_limit'
    ELSE 'ok'
  END                                          AS active_games_limit_status,
  CASE
    WHEN ce.max_members IS NULL THEN 'no_entitlements'
    WHEN ce.max_members = -1    THEN 'unlimited'
    WHEN COALESCE(am.count, 0) >= ce.max_members THEN 'AT_LIMIT'
    WHEN COALESCE(am.count, 0) >= ce.max_members - 1 THEN 'near_limit'
    ELSE 'ok'
  END                                          AS member_limit_status
FROM   clubs               c
LEFT JOIN club_entitlements  ce  ON ce.club_id  = c.id
LEFT JOIN club_subscriptions cs  ON cs.club_id  = c.id
LEFT JOIN club_stripe_accounts csa ON csa.club_id = c.id
LEFT JOIN active_games       ag  ON ag.club_id  = c.id
LEFT JOIN approved_members   am  ON am.club_id  = c.id
ORDER BY c.name;

REVOKE SELECT ON v_club_debug_summary FROM anon, authenticated;
*/
