-- Add audit columns for DUPR updates on profiles.
-- Tracks who last set the value and when, so admins can see the history.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS dupr_updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS dupr_updated_at TIMESTAMPTZ;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS dupr_updated_by_name TEXT;

-- Recreate the RPC to also write the audit columns.
-- Subquery resolves the updater's name inline to avoid PL/pgSQL SELECT INTO ambiguity.
-- SECURITY DEFINER so it can bypass profiles RLS to read the updater's full_name.
CREATE OR REPLACE FUNCTION admin_update_member_dupr(member_user_id UUID, new_rating DOUBLE PRECISION)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE profiles
  SET dupr_rating          = new_rating,
      dupr_updated_by      = auth.uid(),
      dupr_updated_at      = NOW(),
      dupr_updated_by_name = COALESCE(
        (SELECT full_name FROM profiles WHERE id = auth.uid()),
        'Admin'
      )
  WHERE id = member_user_id;
$$;

GRANT EXECUTE ON FUNCTION admin_update_member_dupr(UUID, DOUBLE PRECISION) TO authenticated;
