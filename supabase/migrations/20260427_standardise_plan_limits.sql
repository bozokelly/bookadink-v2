-- Standardise subscription plan limits — 2026-04-27
--
-- New canonical limits:
--   Free:    max_active_games = 3,  max_members = 20
--   Starter: max_active_games = 10, max_members = 100
--   Pro:     unlimited (-1)  (unchanged)
--
-- Changes:
--   1. Update derive_club_entitlements() with correct tier limits.
--   2. Alter club_entitlements.max_members DEFAULT from 50 → 20.
--   3. Add get_plan_tier_limits() RPC — returns all tier definitions so iOS/Android/Web
--      can render paywalls from server data instead of hardcoding limit numbers.
--   4. Backfill ALL clubs so existing entitlement rows match the new limits.
--
-- Safe to re-run. All DDL uses CREATE OR REPLACE / ALTER COLUMN … SET DEFAULT.
-- Backfill is idempotent — derive_club_entitlements uses ON CONFLICT DO UPDATE.
--
-- Diagnostic queries (run after migration to verify):
--
--   -- Confirm all free clubs have max_members = 20
--   SELECT id, name, e.max_active_games, e.max_members, e.plan_tier
--   FROM clubs c JOIN club_entitlements e ON e.club_id = c.id
--   WHERE e.plan_tier = 'free'
--   ORDER BY name;
--
--   -- Confirm starter clubs have 10 games / 100 members
--   SELECT id, name, e.max_active_games, e.max_members
--   FROM clubs c JOIN club_entitlements e ON e.club_id = c.id
--   WHERE e.plan_tier = 'starter';
--
--   -- Confirm plan definitions match spec
--   SELECT * FROM get_plan_tier_limits();

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Update derive_club_entitlements with correct limits
-- ─────────────────────────────────────────────────────────────────────────────
-- THIS CASE BLOCK IS THE SINGLE SOURCE OF TRUTH for tier → feature mapping.
-- Any change to plan limits must happen here first, then iOS/Android/Web will
-- pick up the change via get_plan_tier_limits() on next app launch.

CREATE OR REPLACE FUNCTION derive_club_entitlements(p_club_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_type TEXT := 'free';
  v_status    TEXT := NULL;

  v_plan_tier                  TEXT    := 'free';
  v_max_active_games           INT     := 3;
  v_max_members                INT     := 20;
  v_can_accept_payments        BOOL    := false;
  v_analytics_access           BOOL    := false;
  v_can_use_recurring_games    BOOL    := false;
  v_can_use_delayed_publishing BOOL    := false;
BEGIN
  -- Primary source: club_subscriptions (Stripe-managed).
  SELECT plan_type, status
  INTO   v_plan_type, v_status
  FROM   club_subscriptions
  WHERE  club_id = p_club_id
  LIMIT  1;

  -- Treat non-active Stripe statuses as unprovisioned (not necessarily free).
  -- 'canceling' = cancel_at_period_end set, still within paid period → keep features.
  IF v_status IS NULL OR v_status NOT IN ('active', 'trialing', 'canceling') THEN
    v_plan_type := 'free';
  END IF;

  -- Fallback: if no active Stripe subscription row was found, check
  -- clubs.subscription_tier. This handles dev/staging clubs manually provisioned
  -- without going through Stripe, and timing gaps where the webhook hasn't fired.
  -- Security: clubs.subscription_tier is written ONLY by service_role Edge Functions.
  IF v_plan_type = 'free' THEN
    SELECT COALESCE(NULLIF(TRIM(subscription_tier), ''), 'free')
      INTO v_plan_type
    FROM clubs
    WHERE id = p_club_id;
  END IF;

  -- Map resolved plan_type → entitlement values.
  CASE v_plan_type
    WHEN 'starter' THEN
      v_plan_tier                  := 'starter';
      v_max_active_games           := 10;
      v_max_members                := 100;
      v_can_accept_payments        := true;
      v_analytics_access           := false;
      v_can_use_recurring_games    := false;
      v_can_use_delayed_publishing := false;
    WHEN 'pro' THEN
      v_plan_tier                  := 'pro';
      v_max_active_games           := -1;
      v_max_members                := -1;
      v_can_accept_payments        := true;
      v_analytics_access           := true;
      v_can_use_recurring_games    := true;
      v_can_use_delayed_publishing := true;
    ELSE
      -- 'free' or any unknown value → safe defaults, no paid features.
      v_plan_tier                  := 'free';
      v_max_active_games           := 3;
      v_max_members                := 20;
      v_can_accept_payments        := false;
      v_analytics_access           := false;
      v_can_use_recurring_games    := false;
      v_can_use_delayed_publishing := false;
  END CASE;

  INSERT INTO club_entitlements (
    club_id, plan_tier, max_active_games, max_members,
    can_accept_payments, analytics_access,
    can_use_recurring_games, can_use_delayed_publishing,
    updated_at
  ) VALUES (
    p_club_id, v_plan_tier, v_max_active_games, v_max_members,
    v_can_accept_payments, v_analytics_access,
    v_can_use_recurring_games, v_can_use_delayed_publishing,
    now()
  )
  ON CONFLICT (club_id) DO UPDATE SET
    plan_tier                  = EXCLUDED.plan_tier,
    max_active_games           = EXCLUDED.max_active_games,
    max_members                = EXCLUDED.max_members,
    can_accept_payments        = EXCLUDED.can_accept_payments,
    analytics_access           = EXCLUDED.analytics_access,
    can_use_recurring_games    = EXCLUDED.can_use_recurring_games,
    can_use_delayed_publishing = EXCLUDED.can_use_delayed_publishing,
    updated_at                 = EXCLUDED.updated_at;
END;
$$;

GRANT EXECUTE ON FUNCTION derive_club_entitlements(UUID) TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Update club_entitlements.max_members DEFAULT to match free tier
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE club_entitlements
  ALTER COLUMN max_members SET DEFAULT 20;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Add get_plan_tier_limits() — iOS/Android/Web read this at launch
--    Returns one row per plan tier with the canonical limit values.
--    No parameters — plan definitions are global constants, not per-club.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_plan_tier_limits()
RETURNS TABLE (
  plan_tier                  TEXT,
  max_active_games           INT,
  max_members                INT,
  can_accept_payments        BOOL,
  analytics_access           BOOL,
  can_use_recurring_games    BOOL,
  can_use_delayed_publishing BOOL
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM (VALUES
    ('free'::TEXT,    3,   20, false, false, false, false),
    ('starter'::TEXT, 10, 100, true,  false, false, false),
    ('pro'::TEXT,     -1,  -1, true,  true,  true,  true)
  ) AS t(
    plan_tier, max_active_games, max_members,
    can_accept_payments, analytics_access,
    can_use_recurring_games, can_use_delayed_publishing
  )
$$;

GRANT EXECUTE ON FUNCTION get_plan_tier_limits() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Backfill ALL clubs with updated limits
--    Re-runs derive_club_entitlements for every club so existing rows reflect
--    the new values. Pro clubs (unlimited) are unaffected. Free clubs move from
--    max_members=50 → 20. Starter clubs move from 20 games/200 members → 10/100.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT id FROM clubs
  LOOP
    PERFORM derive_club_entitlements(r.id);
  END LOOP;
END;
$$;
