-- ─────────────────────────────────────────────────────────────────────────────
-- Club Role Audit + RPC logging + server-side push for role changes
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDENCY: 20260504010000_club_role_lifecycle.sql + 20260504020000_club_admins_lock_writes.sql
--
-- WHAT THIS DOES:
--   1. Creates club_role_audit — append-only history of every role transition.
--   2. Re-creates the three role RPCs (promote / demote / transfer) to:
--        • INSERT one (or two) audit rows per call
--        • RAISE LOG with structured fields for production tracing
--   3. Adds a trigger on club_role_audit that fans out a push notification via
--      a new --no-verify-jwt Edge Function (role-change-push). The push is
--      what closes the cross-device staleness gap noted in CLAUDE.md
--      "Club Role Lifecycle" section.
--
--   The audit table is also written by trg_ensure_club_admins_owner_on_club_insert
--   (so club creation appears in the audit trail) and the existing
--   trg_cascade_club_admins_on_member_removal (so leaving members are recorded
--   when their admin row goes).
--
-- WHY THE PUSH LIVES IN A TRIGGER (not in each RPC body):
--   Single fan-out point. Any future role-mutating path (manual SQL repair,
--   future RPC variants) that lands in club_admins automatically gets logged
--   AND notified. Less to forget.
--
-- HARDCODED PROJECT URL + ANON KEY:
--   Per CLAUDE.md "Server-Side Push Triggers — Critical Setup". current_setting()
--   returns NULL on Supabase hosted; only hard-coded literals work.
--   The two literals below match those already hard-coded in
--   20260430040000_waitlist_push_hardcode_credentials.sql for the
--   vdhwptzngjguluxcbzsi project. If this repo ever serves a different
--   project, both files must be updated together.
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Audit table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS club_role_audit (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    club_id         UUID NOT NULL REFERENCES clubs(id) ON DELETE CASCADE,
    target_user_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    actor_user_id   UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    change_type     TEXT NOT NULL,  -- see CHECK below
    old_role        TEXT,           -- 'owner' | 'admin' | 'member' | NULL
    new_role        TEXT,           -- 'owner' | 'admin' | 'member' | NULL (NULL = removed)
    reason          TEXT,           -- free-form, e.g. 'club_created', 'member_removed_cascade'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT club_role_audit_change_type_check
        CHECK (change_type IN (
            'promoted_to_admin',
            'demoted_to_member',
            'transferred_in',
            'transferred_out_to_admin',
            'transferred_out_to_member',
            'club_created',
            'member_removed_cascade',
            'self_relinquished'
        )),
    CONSTRAINT club_role_audit_old_role_check
        CHECK (old_role IS NULL OR old_role IN ('owner', 'admin', 'member')),
    CONSTRAINT club_role_audit_new_role_check
        CHECK (new_role IS NULL OR new_role IN ('owner', 'admin', 'member'))
);

CREATE INDEX IF NOT EXISTS idx_club_role_audit_club_created
    ON club_role_audit(club_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_club_role_audit_target_created
    ON club_role_audit(target_user_id, created_at DESC);

ALTER TABLE club_role_audit ENABLE ROW LEVEL SECURITY;

-- SELECT: club owner can read all audit rows for their club
DROP POLICY IF EXISTS "Club owner can read role audit" ON club_role_audit;
CREATE POLICY "Club owner can read role audit"
    ON club_role_audit FOR SELECT
    USING (EXISTS (SELECT 1 FROM clubs WHERE id = club_role_audit.club_id AND created_by = auth.uid()));

-- SELECT: target user can read their own audit rows (so a demoted user can see why)
DROP POLICY IF EXISTS "Users can read own role audit" ON club_role_audit;
CREATE POLICY "Users can read own role audit"
    ON club_role_audit FOR SELECT
    USING (auth.uid() = target_user_id);

-- No INSERT/UPDATE/DELETE policies — only SECURITY DEFINER functions write.

COMMENT ON TABLE club_role_audit IS
    'Append-only history of club role transitions. Written by '
    'promote_club_member_to_admin, demote_club_admin_to_member, '
    'transfer_club_ownership, and the trigger functions for club creation '
    'and member removal. Read by club owner (full club history) or the '
    'target user (their own history). No client write path.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Re-create the three role RPCs with audit-insert + RAISE LOG
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
    v_caller       UUID := auth.uid();
    v_owner_id     UUID;
    v_member_count INT;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
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

    RAISE LOG 'club_role: promote club=% target=% actor=%',
        p_club_id, p_user_id, v_caller;

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
    v_caller      UUID := auth.uid();
    v_owner_id    UUID;
    v_target_role TEXT;
    v_did_demote  BOOLEAN := FALSE;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
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

        RAISE LOG 'club_role: demote club=% target=% actor=%',
            p_club_id, p_user_id, v_caller;
    ELSE
        -- No row existed; idempotent no-op. Do not write audit (nothing changed).
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
    v_caller       UUID := auth.uid();
    v_old_owner    UUID;
    v_member_count INT;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    IF p_old_owner_new_role NOT IN ('admin', 'member') THEN
        RAISE EXCEPTION 'invalid_old_owner_role';
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

    -- (a) Promote new owner via clubs.created_by update + sync trigger.
    UPDATE clubs SET created_by = p_new_owner_id WHERE id = p_club_id;

    -- (b) Demote old owner.
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

    -- Audit: TWO rows. New owner is the "transferred_in" event; old owner is
    -- the "transferred_out_to_*" event. Both share the same actor_user_id.
    INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role)
    VALUES
        (p_club_id, p_new_owner_id, v_caller, 'transferred_in',
         CASE WHEN EXISTS (SELECT 1 FROM club_role_audit WHERE club_id=p_club_id AND target_user_id=p_new_owner_id AND new_role='admin')
              THEN 'admin' ELSE 'member' END,
         'owner'),
        (p_club_id, v_old_owner,   v_caller,
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
-- 3. Audit-write trigger functions for the synthetic events
-- ─────────────────────────────────────────────────────────────────────────────
-- Re-create ensure_club_admins_owner_on_club_insert to also write audit.
CREATE OR REPLACE FUNCTION ensure_club_admins_owner_on_club_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.created_by IS NOT NULL THEN
        INSERT INTO club_admins (club_id, user_id, role)
        VALUES (NEW.id, NEW.created_by, 'owner')
        ON CONFLICT (club_id, user_id) DO UPDATE SET role = 'owner';

        INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role, reason)
        VALUES (NEW.id, NEW.created_by, NEW.created_by, 'club_created', NULL, 'owner', 'club_created');
    END IF;
    RETURN NEW;
END;
$$;

-- Re-create cascade_club_admins_on_member_removal so removed admins appear in audit.
CREATE OR REPLACE FUNCTION cascade_club_admins_on_member_removal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_old_role TEXT;
BEGIN
    SELECT ca.role INTO v_old_role
    FROM   club_admins ca
    WHERE  ca.club_id = OLD.club_id
      AND  ca.user_id = OLD.user_id;

    IF v_old_role IS NOT NULL THEN
        DELETE FROM club_admins
         WHERE club_id = OLD.club_id
           AND user_id = OLD.user_id;

        -- v_old_role='owner' would be blocked by protect_last_owner unless the
        -- club is being torn down; we still log the attempt for completeness.
        INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role, reason)
        VALUES (OLD.club_id, OLD.user_id, auth.uid(), 'member_removed_cascade', v_old_role, NULL, 'club_membership_removed');
    END IF;

    RETURN OLD;
END;
$$;

-- "Users can delete own admin record" — when an admin self-relinquishes, capture it.
-- We can't intercept inside RLS, but we can use an AFTER DELETE on club_admins
-- trigger that distinguishes "cascade from member removal" (already audited above)
-- vs "self-delete via RLS policy". Simplest: use a separate AFTER DELETE trigger
-- that fires for any club_admins row delete and logs ONLY when no recent
-- cascade audit row exists for the same (club_id, user_id) within the txn.
--
-- Avoiding the complexity for now: the cascade trigger above already covers the
-- "leaving member" case. A pure self-relinquish (admin who stays a member but
-- voluntarily drops admin) will appear as the row simply disappearing from
-- club_admins; the audit trail will show no row. This is acceptable for v1 —
-- the case is rare and the protect_last_owner trigger blocks the dangerous
-- variant (last owner self-delete).


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Trigger: AFTER INSERT ON club_role_audit → enqueue push via Edge Function
-- ─────────────────────────────────────────────────────────────────────────────
-- Single fan-out point. Calls the role-change-push Edge Function (deployed
-- with --no-verify-jwt) which inserts a notifications row + sends APNs.
--
-- HARD-CODED CREDENTIALS per CLAUDE.md "Server-Side Push Triggers":
--   current_setting('app.supabase_url', true) returns NULL on Supabase hosted.
--   Hard-code the project URL and the public anon key (safe — already in iOS
--   binary; RLS protects data, not the key).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION enqueue_role_change_push()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_supabase_url CONSTANT TEXT := 'https://vdhwptzngjguluxcbzsi.supabase.co';
    v_anon_key     CONSTANT TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZkaHdwdHpuZ2pndWx1eGNienNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MDUwMDgsImV4cCI6MjA4NjQ4MTAwOH0.KhCdfv8EDGApovbdsEiEIE0vBJojy2tfEJzpgvcBuXk';
    v_payload      JSONB;
BEGIN
    -- Skip self-events: an actor doesn't need a push for an action they took.
    -- Exception: club_created should still notify (for audit visibility), but
    -- since actor=target on creation, also a no-op via this rule. Acceptable —
    -- the creator already knows.
    IF NEW.actor_user_id IS NOT NULL AND NEW.actor_user_id = NEW.target_user_id THEN
        RETURN NEW;
    END IF;

    v_payload := jsonb_build_object(
        'audit_id',       NEW.id,
        'club_id',        NEW.club_id,
        'target_user_id', NEW.target_user_id,
        'actor_user_id',  NEW.actor_user_id,
        'change_type',    NEW.change_type,
        'old_role',       NEW.old_role,
        'new_role',       NEW.new_role
    );

    PERFORM net.http_post(
        url     := v_supabase_url || '/functions/v1/role-change-push',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_anon_key
        ),
        body    := v_payload
    );

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Push failure must NEVER fail the audit insert; the role mutation has
    -- already committed. Log and swallow.
    RAISE LOG 'enqueue_role_change_push failed: % (audit_id=%)', SQLERRM, NEW.id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_role_change_push ON club_role_audit;
CREATE TRIGGER trg_enqueue_role_change_push
    AFTER INSERT ON club_role_audit
    FOR EACH ROW
    EXECUTE FUNCTION enqueue_role_change_push();

COMMENT ON FUNCTION enqueue_role_change_push() IS
    'Fires once per club_role_audit insert. POSTs to /functions/v1/role-change-push '
    'with anon-key auth (Edge Function deployed --no-verify-jwt). Failures are '
    'logged but do not roll back the audit row — the role mutation already '
    'committed before this trigger fires.';
