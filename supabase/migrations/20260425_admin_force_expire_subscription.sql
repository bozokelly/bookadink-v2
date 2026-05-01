-- Dev/admin-only helper: force a club's subscription period to expire immediately.
--
-- Use this in the Supabase SQL Editor to test the downgrade/expiry flow without
-- waiting for a real billing period to end.
--
-- NEVER expose this to authenticated users or call it from iOS client code.
-- The REVOKE statements below enforce this at the DB level.
--
-- Usage (SQL Editor, runs as postgres):
--   SELECT admin_force_expire_subscription('<club_id_uuid>');
--
-- To restore: UPDATE club_subscriptions SET status='active', current_period_end=<future>
--             WHERE club_id='<uuid>'; SELECT derive_club_entitlements('<uuid>');

CREATE OR REPLACE FUNCTION admin_force_expire_subscription(p_club_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'admin_force_expire_subscription is restricted to admin roles'
      USING ERRCODE = '42501';
  END IF;

  UPDATE club_subscriptions
  SET status             = 'canceled',
      current_period_end = NOW() - INTERVAL '1 second',
      updated_at         = NOW()
  WHERE club_id = p_club_id;

  IF NOT FOUND THEN
    RETURN 'no subscription row found for club ' || p_club_id;
  END IF;

  -- Must update subscription_tier BEFORE calling derive_club_entitlements,
  -- because derive reads clubs.subscription_tier as its fallback source.
  UPDATE clubs SET subscription_tier = 'free' WHERE id = p_club_id;

  PERFORM derive_club_entitlements(p_club_id);

  RETURN 'expired: club ' || p_club_id || ' → free tier';
END;
$$;

-- Explicitly block all non-admin roles — authenticated users cannot call this.
REVOKE ALL ON FUNCTION admin_force_expire_subscription(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION admin_force_expire_subscription(UUID) FROM authenticated;
