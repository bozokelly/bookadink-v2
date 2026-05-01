-- Pro-only game scheduling features
-- Adds can_use_recurring_games and can_use_delayed_publishing to club_entitlements.
-- Both are Pro-only. Free and Starter clubs get false.
-- derive_club_entitlements() is updated to populate the new columns.

-- 1. Add columns (idempotent)
ALTER TABLE club_entitlements
  ADD COLUMN IF NOT EXISTS can_use_recurring_games    BOOL NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_use_delayed_publishing BOOL NOT NULL DEFAULT false;

-- 2. Backfill existing Pro rows
UPDATE club_entitlements
SET    can_use_recurring_games    = true,
       can_use_delayed_publishing = true
WHERE  plan_tier = 'pro';

-- 3. Replace derive_club_entitlements to include the new columns.
--    This is the single source of truth for tier → feature mapping.
CREATE OR REPLACE FUNCTION derive_club_entitlements(p_club_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_type TEXT := 'free';
  v_status    TEXT := NULL;

  v_plan_tier                 TEXT    := 'free';
  v_max_active_games          INT     := 3;
  v_max_members               INT     := 50;
  v_can_accept_payments       BOOL    := false;
  v_analytics_access          BOOL    := false;
  v_can_use_recurring_games   BOOL    := false;
  v_can_use_delayed_publishing BOOL   := false;
BEGIN
  SELECT plan_type, status
  INTO   v_plan_type, v_status
  FROM   club_subscriptions
  WHERE  club_id = p_club_id
  LIMIT  1;

  IF v_status IS NULL OR v_status NOT IN ('active', 'trialing') THEN
    v_plan_type := 'free';
  END IF;

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
