-- Entitlements repair — 2026-04-25
--
-- Root cause: derive_club_entitlements() reads ONLY club_subscriptions for plan
-- resolution. When no active subscription row exists (Stripe webhook hasn't fired,
-- subscription is 'incomplete', or club was manually provisioned for dev/staging),
-- all clubs default to free-tier even though clubs.subscription_tier has the correct
-- value. clubs.subscription_tier is written exclusively by service_role Edge Functions
-- (create-club-subscription, stripe-webhook) so it is a safe fallback source.
--
-- This migration:
--   1. Updates derive_club_entitlements to fall back to clubs.subscription_tier
--      when no active club_subscriptions row is found.
--   2. Inserts missing club_entitlements rows for any clubs that don't have one.
--   3. Calls the updated function for every club whose subscription_tier is
--      'starter' or 'pro' so their entitlements are immediately corrected.
--
-- Safe to re-run. derive_club_entitlements is CREATE OR REPLACE; the backfill
-- loops are idempotent (ON CONFLICT or re-calling the same function).
--
-- Diagnostic queries (run in Supabase SQL Editor to verify before/after):
--
--   -- Compare clubs.subscription_tier vs current club_entitlements.plan_tier
--   SELECT c.id, c.name, c.subscription_tier,
--          e.plan_tier, e.analytics_access, e.can_accept_payments
--   FROM   clubs c
--   LEFT JOIN club_entitlements e ON e.club_id = c.id
--   ORDER BY c.name;
--
--   -- Clubs with tier mismatch (should return 0 rows after this migration)
--   SELECT c.id, c.name, c.subscription_tier, e.plan_tier
--   FROM   clubs c
--   JOIN   club_entitlements e ON e.club_id = c.id
--   WHERE  c.subscription_tier IN ('starter', 'pro')
--     AND  e.plan_tier = 'free';
--
--   -- Clubs with missing entitlement row (should return 0 rows after migration)
--   SELECT c.id, c.name, c.subscription_tier
--   FROM   clubs c
--   LEFT JOIN club_entitlements e ON e.club_id = c.id
--   WHERE  e.club_id IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Update derive_club_entitlements with clubs.subscription_tier fallback
-- ─────────────────────────────────────────────────────────────────────────────
-- The function signature is unchanged — only the plan-type resolution block gains
-- a fallback path. All existing callers (stripe-webhook, create-club-subscription)
-- continue to work without modification.

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
  v_max_members                INT     := 50;
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
  -- clubs.subscription_tier. This handles:
  --   • Dev/staging clubs manually provisioned without going through Stripe.
  --   • Timing gaps where the Stripe webhook hasn't fired yet.
  --   • Clubs on a legacy direct-provision path.
  --
  -- Security note: clubs.subscription_tier is written ONLY by service_role
  -- Edge Functions (create-club-subscription, stripe-webhook). An authenticated
  -- iOS user can PATCH it via PostgREST RLS, but calling derive_club_entitlements
  -- requires service_role — so a rogue client-side PATCH cannot self-escalate
  -- entitlements without a corresponding service_role trigger.
  IF v_plan_type = 'free' THEN
    SELECT COALESCE(NULLIF(TRIM(subscription_tier), ''), 'free')
      INTO v_plan_type
    FROM clubs
    WHERE id = p_club_id;
  END IF;

  -- Map resolved plan_type → entitlement values.
  -- THIS CASE BLOCK IS THE SINGLE SOURCE OF TRUTH for tier → feature mapping.
  CASE v_plan_type
    WHEN 'starter' THEN
      v_plan_tier                  := 'starter';
      v_max_active_games           := 20;
      v_max_members                := 200;
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
      v_max_members                := 50;
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
-- 2. Ensure every club has an entitlements row (idempotent)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO club_entitlements (club_id, updated_at)
SELECT id, now() FROM clubs
ON CONFLICT (club_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Backfill entitlements for all paid clubs
--    Calls the updated derive function so the tier → feature mapping stays in
--    one place. Runs for all clubs that have a non-free subscription_tier so
--    that any club currently stuck at plan_tier = 'free' is immediately repaired.
--    Free clubs are also seeded (step 2 above) but derive is not re-run for them
--    to avoid unnecessary writes.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id FROM clubs
    WHERE subscription_tier IN ('starter', 'pro')
  LOOP
    PERFORM derive_club_entitlements(r.id);
  END LOOP;
END;
$$;
