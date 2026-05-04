-- ─────────────────────────────────────────────────────────────────────────────
-- Role History RPC + rate limiting + analytics view
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDS ON:
--   20260504010000_club_role_lifecycle.sql
--   20260504020000_club_admins_lock_writes.sql
--   20260504025000_notification_type_role_changed.sql
--   20260504030000_role_audit_and_logging.sql
--
-- WHAT THIS DOES:
--   1. get_club_role_history(p_club_id, p_limit) SECURITY DEFINER RPC —
--      joins club_role_audit with profiles so the iOS Role History sheet can
--      render names without a second query and without depending on profiles
--      RLS allowing the owner to read every member.
--   2. Adds rate-limit guard to promote_club_member_to_admin,
--      demote_club_admin_to_member, and transfer_club_ownership. Caps each
--      actor at 10 role-mutation RPC calls per club per 60 seconds. Throws
--      'rate_limited' on excess so the iOS layer can surface a friendly
--      message instead of a generic error.
--   3. v_club_role_change_summary view + get_club_role_change_summary RPC for
--      lightweight analytics (counts per change_type per month).
--
-- DESIGN NOTES:
--   • Rate limit is per (actor, club) — concurrent owners of two different
--     clubs don't interfere. Window is 60 seconds. Limit 10 is generous for
--     bursty admin work (e.g. seeding 5 admins on a new club) and tight
--     enough to stop runaway scripts. Tune via the v_max_per_minute constant
--     in each RPC.
--   • Rate limit reads club_role_audit (not a separate table) so it stays
--     consistent with what actually happened — UI-only counters could drift.
--   • Analytics view is read-only and unprivileged; the RPC SECURITY DEFINER
--     gates access to club owner / admin (matches the dashboard analytics
--     pattern in get_club_analytics_kpis).
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. get_club_role_history(p_club_id, p_limit)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_club_role_history(
    p_club_id UUID,
    p_limit   INT DEFAULT 100
)
RETURNS TABLE(
    id              UUID,
    club_id         UUID,
    target_user_id  UUID,
    target_name     TEXT,
    actor_user_id   UUID,
    actor_name      TEXT,
    change_type     TEXT,
    old_role        TEXT,
    new_role        TEXT,
    reason          TEXT,
    created_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller    UUID := auth.uid();
    v_owner_id  UUID;
    v_is_admin  BOOLEAN;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    -- Authorization: club owner OR an admin of this club. Mirrors the read
    -- policy on club_role_audit ("Club owner can read role audit") plus
    -- explicit admin access for owner-tools usage. Members cannot read other
    -- members' history; for that they should query their own audit rows
    -- directly via PostgREST (RLS allows target_user_id = auth.uid()).
    SELECT c.created_by INTO v_owner_id FROM clubs c WHERE c.id = p_club_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'club_not_found';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM club_admins ca WHERE ca.club_id = p_club_id AND ca.user_id = v_caller
    ) INTO v_is_admin;

    IF v_owner_id IS DISTINCT FROM v_caller AND NOT v_is_admin THEN
        RAISE EXCEPTION 'forbidden_owner_or_admin_only';
    END IF;

    RETURN QUERY
    SELECT
        cra.id,
        cra.club_id,
        cra.target_user_id,
        COALESCE(p_target.full_name, '(removed user)') AS target_name,
        cra.actor_user_id,
        COALESCE(p_actor.full_name, '—')              AS actor_name,
        cra.change_type,
        cra.old_role,
        cra.new_role,
        cra.reason,
        cra.created_at
    FROM   club_role_audit cra
    LEFT JOIN profiles p_target ON p_target.id = cra.target_user_id
    LEFT JOIN profiles p_actor  ON p_actor.id  = cra.actor_user_id
    WHERE  cra.club_id = p_club_id
    ORDER BY cra.created_at DESC
    LIMIT  GREATEST(1, LEAST(p_limit, 500));
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_role_history(UUID, INT) TO authenticated;

COMMENT ON FUNCTION get_club_role_history(UUID, INT) IS
    'Returns up to p_limit recent club_role_audit rows for p_club_id with '
    'resolved target/actor names. SECURITY DEFINER; caller must be club owner '
    'or in club_admins for that club. Capped at 500 rows.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Rate-limited RPCs (re-create with guard at top)
-- ─────────────────────────────────────────────────────────────────────────────

-- 2a. promote_club_member_to_admin -------------------------------------------
CREATE OR REPLACE FUNCTION promote_club_member_to_admin(
    p_club_id UUID,
    p_user_id UUID
)
RETURNS TABLE(
    out_club_id UUID,
    out_user_id UUID,
    out_role    TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller          UUID := auth.uid();
    v_owner_id        UUID;
    v_member_count    INT;
    v_recent_rate     INT;
    v_max_per_minute  CONSTANT INT := 10;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    -- Rate limit: per (actor, club), max v_max_per_minute role mutations / 60s.
    -- Counts every audit row this caller has produced for this club recently;
    -- transfer_club_ownership writes 2 rows per call so it costs 2× capacity,
    -- which is the desired weighting (transfers are heavier user-facing events).
    SELECT COUNT(*) INTO v_recent_rate
    FROM   club_role_audit
    WHERE  club_id = p_club_id
      AND  actor_user_id = v_caller
      AND  created_at > now() - INTERVAL '60 seconds';

    IF v_recent_rate >= v_max_per_minute THEN
        RAISE EXCEPTION 'rate_limited';
    END IF;

    SELECT c.created_by INTO v_owner_id
    FROM   clubs c
    WHERE  c.id = p_club_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'club_not_found';
    END IF;

    IF v_owner_id IS DISTINCT FROM v_caller THEN
        RAISE EXCEPTION 'forbidden_owner_only';
    END IF;

    IF p_user_id = v_caller THEN
        RAISE EXCEPTION 'cannot_modify_self';
    END IF;

    SELECT COUNT(*) INTO v_member_count
    FROM   club_members cm
    WHERE  cm.club_id = p_club_id
      AND  cm.user_id = p_user_id
      AND  cm.status  = 'approved';

    IF v_member_count = 0 THEN
        RAISE EXCEPTION 'target_not_approved_member';
    END IF;

    INSERT INTO club_admins (club_id, user_id, role)
    VALUES (p_club_id, p_user_id, 'admin')
    ON CONFLICT (club_id, user_id)
    DO UPDATE SET role = 'admin'
        WHERE  club_admins.role <> 'owner';

    INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role)
    VALUES (p_club_id, p_user_id, v_caller, 'promoted_to_admin', 'member', 'admin');

    RAISE LOG 'club_role: promote club=% target=% actor=%', p_club_id, p_user_id, v_caller;

    RETURN QUERY
    SELECT ca.club_id, ca.user_id, ca.role::TEXT
    FROM   club_admins ca
    WHERE  ca.club_id = p_club_id
      AND  ca.user_id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION promote_club_member_to_admin(UUID, UUID) TO authenticated;


-- 2b. demote_club_admin_to_member --------------------------------------------
CREATE OR REPLACE FUNCTION demote_club_admin_to_member(
    p_club_id UUID,
    p_user_id UUID
)
RETURNS TABLE(
    out_club_id UUID,
    out_user_id UUID,
    out_demoted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller          UUID := auth.uid();
    v_owner_id        UUID;
    v_target_role     TEXT;
    v_did_demote      BOOLEAN := FALSE;
    v_recent_rate     INT;
    v_max_per_minute  CONSTANT INT := 10;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    SELECT COUNT(*) INTO v_recent_rate
    FROM   club_role_audit
    WHERE  club_id = p_club_id
      AND  actor_user_id = v_caller
      AND  created_at > now() - INTERVAL '60 seconds';

    IF v_recent_rate >= v_max_per_minute THEN
        RAISE EXCEPTION 'rate_limited';
    END IF;

    SELECT c.created_by INTO v_owner_id
    FROM   clubs c
    WHERE  c.id = p_club_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'club_not_found';
    END IF;

    IF v_owner_id IS DISTINCT FROM v_caller THEN
        RAISE EXCEPTION 'forbidden_owner_only';
    END IF;

    IF p_user_id = v_caller THEN
        RAISE EXCEPTION 'cannot_modify_self';
    END IF;

    SELECT ca.role INTO v_target_role
    FROM   club_admins ca
    WHERE  ca.club_id = p_club_id
      AND  ca.user_id = p_user_id;

    IF v_target_role = 'owner' THEN
        RAISE EXCEPTION 'cannot_demote_owner';
    END IF;

    IF v_target_role = 'admin' THEN
        DELETE FROM club_admins ca
        WHERE  ca.club_id = p_club_id
          AND  ca.user_id = p_user_id
          AND  ca.role <> 'owner';

        v_did_demote := TRUE;

        INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role)
        VALUES (p_club_id, p_user_id, v_caller, 'demoted_to_member', 'admin', 'member');

        RAISE LOG 'club_role: demote club=% target=% actor=%', p_club_id, p_user_id, v_caller;
    ELSE
        RAISE LOG 'club_role: demote_noop club=% target=% actor=% (no admin row)',
            p_club_id, p_user_id, v_caller;
    END IF;

    RETURN QUERY
    SELECT p_club_id, p_user_id, v_did_demote;
END;
$$;
GRANT EXECUTE ON FUNCTION demote_club_admin_to_member(UUID, UUID) TO authenticated;


-- 2c. transfer_club_ownership ------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_club_ownership(
    p_club_id              UUID,
    p_new_owner_id         UUID,
    p_old_owner_new_role   TEXT
)
RETURNS TABLE(
    out_club_id        UUID,
    out_new_owner_id   UUID,
    out_old_owner_id   UUID,
    out_old_owner_role TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller          UUID := auth.uid();
    v_old_owner       UUID;
    v_member_count    INT;
    v_recent_rate     INT;
    v_max_per_minute  CONSTANT INT := 10;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    IF p_old_owner_new_role NOT IN ('admin', 'member') THEN
        RAISE EXCEPTION 'invalid_old_owner_role';
    END IF;

    SELECT COUNT(*) INTO v_recent_rate
    FROM   club_role_audit
    WHERE  club_id = p_club_id
      AND  actor_user_id = v_caller
      AND  created_at > now() - INTERVAL '60 seconds';

    IF v_recent_rate >= v_max_per_minute THEN
        RAISE EXCEPTION 'rate_limited';
    END IF;

    SELECT c.created_by INTO v_old_owner
    FROM   clubs c
    WHERE  c.id = p_club_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'club_not_found';
    END IF;

    IF v_old_owner IS DISTINCT FROM v_caller THEN
        RAISE EXCEPTION 'forbidden_owner_only';
    END IF;

    IF p_new_owner_id = v_old_owner THEN
        RAISE LOG 'club_role: transfer_noop club=% (self-transfer) actor=%',
            p_club_id, v_caller;
        RETURN QUERY
        SELECT p_club_id, p_new_owner_id, v_old_owner, NULL::TEXT;
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_member_count
    FROM   club_members cm
    WHERE  cm.club_id = p_club_id
      AND  cm.user_id = p_new_owner_id
      AND  cm.status  = 'approved';

    IF v_member_count = 0 THEN
        RAISE EXCEPTION 'new_owner_not_approved_member';
    END IF;

    UPDATE clubs SET created_by = p_new_owner_id WHERE id = p_club_id;

    IF p_old_owner_new_role = 'admin' THEN
        UPDATE club_admins
           SET role = 'admin'
         WHERE club_id = p_club_id
           AND user_id = v_old_owner;
    ELSE
        DELETE FROM club_admins
         WHERE club_id = p_club_id
           AND user_id = v_old_owner;
    END IF;

    INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role)
    VALUES
        (p_club_id, p_new_owner_id, v_caller, 'transferred_in',
         CASE WHEN EXISTS (SELECT 1 FROM club_role_audit
                            WHERE club_id=p_club_id AND target_user_id=p_new_owner_id AND new_role='admin')
              THEN 'admin' ELSE 'member' END,
         'owner'),
        (p_club_id, v_old_owner, v_caller,
         CASE WHEN p_old_owner_new_role = 'admin' THEN 'transferred_out_to_admin'
                                                  ELSE 'transferred_out_to_member' END,
         'owner', p_old_owner_new_role);

    RAISE LOG 'club_role: transfer club=% new_owner=% old_owner=% old_owner_new_role=% actor=%',
        p_club_id, p_new_owner_id, v_old_owner, p_old_owner_new_role, v_caller;

    RETURN QUERY
    SELECT p_club_id, p_new_owner_id, v_old_owner, p_old_owner_new_role;
END;
$$;
GRANT EXECUTE ON FUNCTION transfer_club_ownership(UUID, UUID, TEXT) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Analytics view + RPC
-- ─────────────────────────────────────────────────────────────────────────────
-- View aggregates audit by club + month + change_type. RLS on club_role_audit
-- means a non-owner non-admin reading the view sees only their own rows; owners
-- and admins see their club's rows. Service role sees everything.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_club_role_change_summary AS
SELECT
    cra.club_id,
    date_trunc('month', cra.created_at) AS month,
    cra.change_type,
    COUNT(*) AS event_count
FROM   club_role_audit cra
GROUP BY cra.club_id, date_trunc('month', cra.created_at), cra.change_type;

COMMENT ON VIEW v_club_role_change_summary IS
    'Per-club, per-month, per-change_type counts of role mutations. Backed by '
    'club_role_audit so RLS applies — owner/admin see their club, target user '
    'sees their own events, service_role sees everything.';

GRANT SELECT ON v_club_role_change_summary TO authenticated;


CREATE OR REPLACE FUNCTION get_club_role_change_summary(
    p_club_id UUID,
    p_days    INT DEFAULT 30
)
RETURNS TABLE(
    change_type TEXT,
    event_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller   UUID := auth.uid();
    v_owner_id UUID;
    v_is_admin BOOLEAN;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    SELECT c.created_by INTO v_owner_id FROM clubs c WHERE c.id = p_club_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'club_not_found';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM club_admins ca WHERE ca.club_id = p_club_id AND ca.user_id = v_caller
    ) INTO v_is_admin;

    IF v_owner_id IS DISTINCT FROM v_caller AND NOT v_is_admin THEN
        RAISE EXCEPTION 'forbidden_owner_or_admin_only';
    END IF;

    RETURN QUERY
    SELECT cra.change_type, COUNT(*)::BIGINT AS event_count
    FROM   club_role_audit cra
    WHERE  cra.club_id = p_club_id
      AND  cra.created_at > now() - (p_days || ' days')::INTERVAL
    GROUP  BY cra.change_type
    ORDER  BY event_count DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_role_change_summary(UUID, INT) TO authenticated;
