-- Documents the club_subscriptions table (originally created via Supabase Studio).
-- Safe to run on an existing database — all statements are IF NOT EXISTS / CREATE OR REPLACE.
-- The subscription_source column is added by 20260425_subscription_source.sql (run first).

CREATE TABLE IF NOT EXISTS club_subscriptions (
  club_id                UUID        PRIMARY KEY REFERENCES clubs(id) ON DELETE CASCADE,
  stripe_subscription_id TEXT,
  plan_type              TEXT        NOT NULL DEFAULT 'free'
                         CHECK (plan_type IN ('free', 'starter', 'pro')),
  status                 TEXT        NOT NULL DEFAULT 'incomplete'
                         CHECK (status IN ('active', 'trialing', 'incomplete', 'past_due', 'canceled', 'canceling')),
  current_period_end     TIMESTAMPTZ,
  subscription_source    TEXT        NOT NULL DEFAULT 'stripe'
                         CHECK (subscription_source IN ('stripe', 'manual', 'promo')),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE club_subscriptions ENABLE ROW LEVEL SECURITY;

-- Club owners and admins can read their own club's subscription details.
DROP POLICY IF EXISTS "Club owners can read their subscription" ON club_subscriptions;
CREATE POLICY "Club owners can read their subscription"
  ON club_subscriptions FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM clubs    WHERE id = club_subscriptions.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_subscriptions.club_id AND user_id = auth.uid())
  );
