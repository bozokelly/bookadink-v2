-- subscription_plans — server-authoritative plan catalogue
--
-- Clients (iOS, Android, Web) must NEVER hardcode Stripe price IDs or display prices.
-- They call get_subscription_plans() at bootstrap and use the returned values exclusively.
-- Changing a price or adding a new plan requires only a DB update — no app release needed.
--
-- Table: subscription_plans
--   plan_id          TEXT PK    — matches plan_type used in club_subscriptions / club_entitlements
--   display_name     TEXT       — shown in paywall UI ("Starter", "Pro")
--   stripe_price_id  TEXT       — Stripe Price API ID (price_...) — used in create-club-subscription
--   display_price    TEXT       — full localised price string shown to users ("A$19/mo")
--   billing_interval TEXT       — 'monthly' | 'annual'
--   sort_order       INT        — ascending sort for paywall card order
--   active           BOOL       — false = hidden from clients (deprecated plan)
--
-- RPC: get_subscription_plans()
--   Returns active plans ordered by sort_order.
--   Callable by authenticated users only (SELECT RLS + GRANT).
--   No parameters — plan definitions are global, not per-club.
--
-- Required by: iOS AppState.fetchSubscriptionPlans(),
--              Android SubscriptionPlansRepository,
--              ClubUpgradePaywallView, ClubPlanBillingSettingsView
--
-- After seeding: verify with SELECT * FROM get_subscription_plans();

CREATE TABLE IF NOT EXISTS subscription_plans (
  plan_id          TEXT        PRIMARY KEY,
  display_name     TEXT        NOT NULL,
  stripe_price_id  TEXT        NOT NULL,
  display_price    TEXT        NOT NULL,
  billing_interval TEXT        NOT NULL DEFAULT 'monthly',
  sort_order       INT         NOT NULL DEFAULT 0,
  active           BOOL        NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS: authenticated users may read active plans; writes are service_role only.
ALTER TABLE subscription_plans ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read active subscription plans"
  ON subscription_plans
  FOR SELECT
  USING (auth.role() = 'authenticated' AND active = true);

-- RPC returns all active plans in display order.
CREATE OR REPLACE FUNCTION get_subscription_plans()
RETURNS TABLE (
  plan_id          TEXT,
  display_name     TEXT,
  stripe_price_id  TEXT,
  display_price    TEXT,
  billing_interval TEXT,
  sort_order       INT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT plan_id, display_name, stripe_price_id, display_price, billing_interval, sort_order
  FROM   subscription_plans
  WHERE  active = true
  ORDER  BY sort_order ASC;
$$;

GRANT EXECUTE ON FUNCTION get_subscription_plans() TO authenticated;

-- Seed with current live plan definitions.
-- To update pricing: UPDATE subscription_plans SET stripe_price_id = '...', display_price = '...' WHERE plan_id = '...';
-- No app release required — clients read this table at every launch.
INSERT INTO subscription_plans (plan_id, display_name, stripe_price_id, display_price, billing_interval, sort_order)
VALUES
  ('starter', 'Starter', 'price_1THmtTLTCVKTs9sj7NrBMkgU', 'A$19/mo', 'monthly', 1),
  ('pro',     'Pro',     'price_1TDRF4LTCVKTs9sjeO6Z25jJ', 'A$49/mo', 'monthly', 2)
ON CONFLICT (plan_id) DO NOTHING;
