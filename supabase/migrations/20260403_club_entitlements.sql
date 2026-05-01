-- Phase 4 Part 2A — Club Entitlements Foundation
-- Run once in Supabase SQL Editor.
-- Safe to re-run (all statements are idempotent).

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS club_entitlements (
  club_id             UUID        PRIMARY KEY REFERENCES clubs(id) ON DELETE CASCADE,
  plan_tier           TEXT        NOT NULL DEFAULT 'free',
  max_active_games    INT         NOT NULL DEFAULT 3,
  max_members         INT         NOT NULL DEFAULT 50,
  can_accept_payments BOOL        NOT NULL DEFAULT false,
  analytics_access    BOOL        NOT NULL DEFAULT false,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS: club owner can read their own club's entitlements.
ALTER TABLE club_entitlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Club owner can read own entitlements" ON club_entitlements;
CREATE POLICY "Club owner can read own entitlements"
  ON club_entitlements FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM clubs
      WHERE clubs.id = club_entitlements.club_id
        AND clubs.created_by = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Club admin can read own club entitlements" ON club_entitlements;
CREATE POLICY "Club admin can read own club entitlements"
  ON club_entitlements FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM club_admins
      WHERE club_admins.club_id = club_entitlements.club_id
        AND club_admins.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Resolver function — THE ONLY PLACE entitlement logic exists.
--    Called by stripe-webhook and create-club-subscription after any
--    subscription state change. Never called from iOS.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION derive_club_entitlements(p_club_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_type TEXT   := 'free';
  v_status    TEXT   := NULL;

  -- Derived values
  v_plan_tier           TEXT    := 'free';
  v_max_active_games    INT     := 3;
  v_max_members         INT     := 50;
  v_can_accept_payments BOOL    := false;
  v_analytics_access    BOOL    := false;
BEGIN
  -- Read current subscription for this club.
  -- If no row exists, all variables remain at free-tier defaults.
  SELECT plan_type, status
  INTO   v_plan_type, v_status
  FROM   club_subscriptions
  WHERE  club_id = p_club_id
  LIMIT  1;

  -- Treat non-active statuses (incomplete, past_due, canceled, NULL) as free.
  IF v_status IS NULL OR v_status NOT IN ('active', 'trialing') THEN
    v_plan_type := 'free';
  END IF;

  -- Map plan_type → entitlement values.
  -- THIS CASE BLOCK IS THE SINGLE SOURCE OF TRUTH for tier → feature mapping.
  -- Do not duplicate this logic anywhere else.
  CASE v_plan_type
    WHEN 'starter' THEN
      v_plan_tier           := 'starter';
      v_max_active_games    := 20;
      v_max_members         := 200;
      v_can_accept_payments := true;
      v_analytics_access    := false;
    WHEN 'pro' THEN
      v_plan_tier           := 'pro';
      v_max_active_games    := -1;   -- unlimited
      v_max_members         := -1;   -- unlimited
      v_can_accept_payments := true;
      v_analytics_access    := true;
    ELSE
      -- 'free' or any unknown value — safe defaults, no paid features
      v_plan_tier           := 'free';
      v_max_active_games    := 3;
      v_max_members         := 50;
      v_can_accept_payments := false;
      v_analytics_access    := false;
  END CASE;

  -- Upsert — idempotent, safe to call multiple times for the same club.
  INSERT INTO club_entitlements (
    club_id, plan_tier, max_active_games, max_members,
    can_accept_payments, analytics_access, updated_at
  ) VALUES (
    p_club_id, v_plan_tier, v_max_active_games, v_max_members,
    v_can_accept_payments, v_analytics_access, now()
  )
  ON CONFLICT (club_id) DO UPDATE SET
    plan_tier           = EXCLUDED.plan_tier,
    max_active_games    = EXCLUDED.max_active_games,
    max_members         = EXCLUDED.max_members,
    can_accept_payments = EXCLUDED.can_accept_payments,
    analytics_access    = EXCLUDED.analytics_access,
    updated_at          = EXCLUDED.updated_at;
END;
$$;

-- Allow the service role (Edge Functions) to call this function.
GRANT EXECUTE ON FUNCTION derive_club_entitlements(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Seed existing clubs
--    All clubs get free-tier defaults. Active-subscription clubs are then
--    upgraded by the loop below.
-- ---------------------------------------------------------------------------

INSERT INTO club_entitlements (club_id, updated_at)
SELECT id, now() FROM clubs
ON CONFLICT (club_id) DO NOTHING;

-- Upgrade any club that already has an active subscription.
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT club_id FROM club_subscriptions
    WHERE status IN ('active', 'trialing')
  LOOP
    PERFORM derive_club_entitlements(r.club_id);
  END LOOP;
END;
$$;
