-- Add subscription_source to club_subscriptions
-- Tags every row with how the subscription was granted.
-- Values: 'stripe' | 'manual' | 'promo'
-- Default 'stripe' — all new Stripe-created rows get it automatically.
-- Back-fill: rows without a Stripe subscription ID are manual grants.
ALTER TABLE club_subscriptions
  ADD COLUMN IF NOT EXISTS subscription_source TEXT NOT NULL DEFAULT 'stripe'
  CHECK (subscription_source IN ('stripe', 'manual', 'promo'));

UPDATE club_subscriptions
SET subscription_source = 'manual'
WHERE stripe_subscription_id IS NULL
   OR stripe_subscription_id = '';
