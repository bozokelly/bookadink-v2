-- Protect clubs.subscription_tier from direct client writes
--
-- Problem: RLS on the clubs table permits authenticated users (including club owners)
-- to PATCH any column they have write access to, including subscription_tier. A
-- malicious actor could self-upgrade to 'pro' without going through Stripe by calling
-- PostgREST directly with a valid JWT.
--
-- Fix: a BEFORE UPDATE trigger that rejects any change to subscription_tier unless the
-- executing database role is service_role, postgres, or supabase_admin. These are the
-- only roles used by:
--   • create-club-subscription Edge Function  (service_role)
--   • stripe-webhook Edge Function             (service_role)
--   • derive_club_entitlements                 (service_role callers)
--   • direct SQL / migrations                  (postgres / supabase_admin)
--
-- Normal iOS PATCH calls (updateClubOwnerFields) do NOT include subscription_tier in
-- the payload (confirmed: ClubOwnerUpdateRow has no such field), so this trigger will
-- never fire for legitimate app traffic.
--
-- The trigger must NOT use SECURITY DEFINER — it must execute under the invoking role
-- so that current_user reflects who is actually running the UPDATE.
--
-- Safe to re-run (CREATE OR REPLACE + DROP IF EXISTS).
--
-- QA:
--   -- Should raise 42501 for an authenticated user:
--   UPDATE clubs SET subscription_tier = 'pro' WHERE id = '<any club uuid>';
--
--   -- Should succeed (service_role connection in SQL Editor):
--   UPDATE clubs SET subscription_tier = 'pro' WHERE id = '<any club uuid>';
--   UPDATE clubs SET subscription_tier = 'free' WHERE id = '<any club uuid>';  -- restore

CREATE OR REPLACE FUNCTION protect_subscription_tier()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.subscription_tier IS DISTINCT FROM NEW.subscription_tier
     AND current_user NOT IN ('service_role', 'postgres', 'supabase_admin')
  THEN
    RAISE EXCEPTION 'subscription_tier is managed by backend services and cannot be modified directly.'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_subscription_tier ON clubs;

CREATE TRIGGER trg_protect_subscription_tier
  BEFORE UPDATE OF subscription_tier ON clubs
  FOR EACH ROW
  EXECUTE FUNCTION protect_subscription_tier();
