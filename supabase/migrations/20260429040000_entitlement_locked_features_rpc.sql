-- get_club_entitlements(p_club_id UUID)
-- Returns all entitlement columns plus a server-computed locked_features TEXT[] array.
-- This RPC is the single canonical entitlement payload for all clients (iOS, Android, web).
--
-- locked_features key values (stable strings — treat as API contract):
--   "payments"          — can_accept_payments = false
--   "analytics"         — analytics_access = false
--   "recurring_games"   — can_use_recurring_games = false
--   "delayed_publishing"— can_use_delayed_publishing = false
--
-- Numeric limits (max_active_games, max_members) are separate fields; -1 means unlimited.
-- iOS reads individual boolean columns via FeatureGateService for type safety.
-- Android/web may use locked_features array for simpler render logic.

CREATE OR REPLACE FUNCTION get_club_entitlements(p_club_id UUID)
RETURNS TABLE (
  club_id                    UUID,
  plan_tier                  TEXT,
  max_active_games           INT,
  max_members                INT,
  can_accept_payments        BOOL,
  analytics_access           BOOL,
  can_use_recurring_games    BOOL,
  can_use_delayed_publishing BOOL,
  locked_features            TEXT[],
  updated_at                 TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    e.club_id,
    e.plan_tier,
    e.max_active_games,
    e.max_members,
    e.can_accept_payments,
    e.analytics_access,
    e.can_use_recurring_games,
    e.can_use_delayed_publishing,
    ARRAY_REMOVE(ARRAY[
      CASE WHEN NOT e.can_accept_payments        THEN 'payments'           END,
      CASE WHEN NOT e.analytics_access           THEN 'analytics'          END,
      CASE WHEN NOT e.can_use_recurring_games    THEN 'recurring_games'    END,
      CASE WHEN NOT e.can_use_delayed_publishing THEN 'delayed_publishing' END
    ], NULL)::TEXT[] AS locked_features,
    e.updated_at
  FROM club_entitlements e
  WHERE e.club_id = p_club_id
$$;

GRANT EXECUTE ON FUNCTION get_club_entitlements(UUID) TO authenticated;
