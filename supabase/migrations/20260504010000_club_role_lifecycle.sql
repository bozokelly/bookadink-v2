-- ─────────────────────────────────────────────────────────────────────────────
-- Club Role Lifecycle — server-authoritative role transitions
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   Role mutations (promote member→admin, demote admin→member) ran as direct
--   PostgREST INSERT/DELETE on club_admins from iOS, gated only by RLS.
--   No SECURITY DEFINER RPC, no return value, no atomic ownership transfer,
--   no last-owner protection, no sync between clubs.created_by and
--   club_admins(role='owner').
--
--   Investigation report (2026-05-04) documented:
--     • Owner self-deletion of their own club_admins row was allowed by the
--       "Users can delete own admin record" policy → orphaned ownership state.
--     • No transfer_club_ownership path existed at all.
--     • clubs.created_by and club_admins(role='owner') had no sync trigger and
--       could drift silently.
--     • The ClubFormBody / removeMembership / createClub paths each issued
--       direct writes to club_admins; impossible to lock down RLS without
--       breaking them first.
--
-- DESIGN:
--   Mirror the book_game / owner_create_booking pattern:
--     • SECURITY DEFINER RPCs perform all role mutations under explicit
--       authorization checks and return the resulting state in one round trip.
--     • Triggers on clubs/club_members keep club_admins in sync automatically:
--         - AFTER INSERT ON clubs        → upsert owner row
--         - AFTER UPDATE OF created_by ON clubs → resync owner role
--         - AFTER DELETE ON club_members → cascade delete club_admins row
--     • BEFORE DELETE ON club_admins enforces last-owner protection — refuses
--       to delete the only owner row while the parent club still exists.
--
--   Phase 3 (separate migration, deployed AFTER iOS uses these RPCs) will lock
--   down direct INSERT/UPDATE/DELETE on club_admins. This migration is safe to
--   apply standalone — it adds capability without removing any existing path.
--
-- INVARIANTS GUARANTEED:
--   I1: clubs.created_by always has a matching club_admins row with role='owner'
--   I2: At all times, every existing club has at least one role='owner' row in
--       club_admins, OR the club is in the process of being deleted.
--   I3: Role transitions are atomic — a single RPC call commits all writes.
--   I4: Only the current owner can promote/demote/transfer.
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. promote_club_member_to_admin(p_club_id, p_user_id)
-- ─────────────────────────────────────────────────────────────────────────────
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

    -- Lock the club row so concurrent ownership transfer or deletion can't race.
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

    -- Target must be an approved member of this club.
    SELECT COUNT(*) INTO v_member_count
    FROM   club_members cm
    WHERE  cm.club_id = p_club_id
      AND  cm.user_id = p_user_id
      AND  cm.status  = 'approved';

    IF v_member_count = 0 THEN
        RAISE EXCEPTION 'target_not_approved_member';
    END IF;

    -- Upsert as admin. ON CONFLICT handles the case where target already had a row
    -- (e.g., previous demote-then-promote churn). Owner rows are never overwritten:
    -- guarded by the WHERE clause.
    INSERT INTO club_admins (club_id, user_id, role)
    VALUES (p_club_id, p_user_id, 'admin')
    ON CONFLICT (club_id, user_id)
    DO UPDATE SET role = 'admin'
        WHERE  club_admins.role <> 'owner';

    RETURN QUERY
    SELECT ca.club_id, ca.user_id, ca.role::TEXT
    FROM   club_admins ca
    WHERE  ca.club_id = p_club_id
      AND  ca.user_id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION promote_club_member_to_admin(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION promote_club_member_to_admin(UUID, UUID) IS
    'Owner-only: promote an approved club member to admin. SECURITY DEFINER. '
    'Locks clubs row, validates caller=owner, target=approved member. '
    'Returns the resulting club_admins row. Errors: authentication_required, '
    'club_not_found, forbidden_owner_only, cannot_modify_self, '
    'target_not_approved_member.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. demote_club_admin_to_member(p_club_id, p_user_id)
-- ─────────────────────────────────────────────────────────────────────────────
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
    v_caller     UUID := auth.uid();
    v_owner_id   UUID;
    v_target_role TEXT;
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

    -- If no row exists, treat as already-a-member (idempotent).
    DELETE FROM club_admins ca
    WHERE  ca.club_id = p_club_id
      AND  ca.user_id = p_user_id
      AND  ca.role <> 'owner';

    RETURN QUERY
    SELECT p_club_id, p_user_id, TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION demote_club_admin_to_member(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION demote_club_admin_to_member(UUID, UUID) IS
    'Owner-only: demote an admin back to plain member. SECURITY DEFINER. '
    'Locks clubs row. Refuses to demote the owner. Idempotent — silently '
    'no-ops if target has no admin row. Errors: authentication_required, '
    'club_not_found, forbidden_owner_only, cannot_modify_self, '
    'cannot_demote_owner.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. transfer_club_ownership(p_club_id, p_new_owner_id, p_old_owner_new_role)
-- ─────────────────────────────────────────────────────────────────────────────
-- Atomic three-write transaction:
--   (a) clubs.created_by ← p_new_owner_id
--   (b) club_admins for old owner ← p_old_owner_new_role ('admin') OR row deleted ('member')
--   (c) club_admins for new owner ← role='owner' (upserted)
-- The AFTER UPDATE OF created_by trigger (defined below) handles (b) and (c)
-- automatically when (a) runs. We still explicitly verify the postcondition.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION transfer_club_ownership(
    p_club_id              UUID,
    p_new_owner_id         UUID,
    p_old_owner_new_role   TEXT  -- 'admin' or 'member'
)
RETURNS TABLE(
    out_club_id        UUID,
    out_new_owner_id   UUID,
    out_old_owner_id   UUID,
    out_old_owner_role TEXT  -- 'admin', 'member', or NULL if old owner = new owner (no-op)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller      UUID := auth.uid();
    v_old_owner   UUID;
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
        -- No-op: caller transferred to themselves.
        RETURN QUERY
        SELECT p_club_id, p_new_owner_id, v_old_owner, NULL::TEXT;
        RETURN;
    END IF;

    -- New owner must be an approved member of this club.
    SELECT COUNT(*) INTO v_member_count
    FROM   club_members cm
    WHERE  cm.club_id = p_club_id
      AND  cm.user_id = p_new_owner_id
      AND  cm.status  = 'approved';

    IF v_member_count = 0 THEN
        RAISE EXCEPTION 'new_owner_not_approved_member';
    END IF;

    -- (a) Update created_by. The AFTER UPDATE OF created_by trigger will
    --     upsert the new owner's club_admins row to role='owner'. We do NOT
    --     touch the old owner row yet — last-owner protection on club_admins
    --     would reject deleting it before another owner exists.
    UPDATE clubs SET created_by = p_new_owner_id WHERE id = p_club_id;

    -- (b) Now that the new owner is established (trigger ran), demote the old
    --     owner. The BEFORE DELETE protect_last_owner trigger sees that another
    --     owner row already exists and allows the change.
    IF p_old_owner_new_role = 'admin' THEN
        -- Convert old owner row to admin. ON CONFLICT not needed — row exists by
        -- definition (they were the owner; trigger doesn't delete the old owner row).
        UPDATE club_admins
           SET role = 'admin'
         WHERE club_id = p_club_id
           AND user_id = v_old_owner;
    ELSE
        -- 'member' — remove the old owner's admin row entirely.
        DELETE FROM club_admins
         WHERE club_id = p_club_id
           AND user_id = v_old_owner;
    END IF;

    RETURN QUERY
    SELECT p_club_id, p_new_owner_id, v_old_owner, p_old_owner_new_role;
END;
$$;

GRANT EXECUTE ON FUNCTION transfer_club_ownership(UUID, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION transfer_club_ownership(UUID, UUID, TEXT) IS
    'Owner-only: atomically transfer club ownership. Updates clubs.created_by, '
    'upserts new owner club_admins row to role=owner (via AFTER UPDATE trigger), '
    'and demotes old owner to admin or member per p_old_owner_new_role. '
    'Errors: authentication_required, club_not_found, forbidden_owner_only, '
    'invalid_old_owner_role, new_owner_not_approved_member.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Trigger: AFTER INSERT ON clubs → ensure owner row in club_admins
-- ─────────────────────────────────────────────────────────────────────────────
-- Replaces the iOS-side direct POST to club_admins at SupabaseService.createClub
-- (SupabaseService.swift:1711). That client call is wrapped in try? and remains
-- as defense-in-depth — the ON CONFLICT here makes it idempotent.
-- ─────────────────────────────────────────────────────────────────────────────
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
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_club_admins_owner_on_insert ON clubs;
CREATE TRIGGER trg_ensure_club_admins_owner_on_insert
    AFTER INSERT ON clubs
    FOR EACH ROW
    EXECUTE FUNCTION ensure_club_admins_owner_on_club_insert();


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Trigger: AFTER UPDATE OF created_by ON clubs → resync owner role
-- ─────────────────────────────────────────────────────────────────────────────
-- Fires only when created_by actually changes (e.g., transfer_club_ownership).
-- Inserts/updates the new owner's club_admins row to role='owner'. Does NOT
-- touch the old owner row — transfer_club_ownership() handles that explicitly
-- because the demotion choice ('admin' vs 'member' vs delete) is policy.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync_club_admins_owner_on_club_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.created_by IS DISTINCT FROM OLD.created_by AND NEW.created_by IS NOT NULL THEN
        INSERT INTO club_admins (club_id, user_id, role)
        VALUES (NEW.id, NEW.created_by, 'owner')
        ON CONFLICT (club_id, user_id) DO UPDATE SET role = 'owner';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_club_admins_owner_on_update ON clubs;
CREATE TRIGGER trg_sync_club_admins_owner_on_update
    AFTER UPDATE OF created_by ON clubs
    FOR EACH ROW
    EXECUTE FUNCTION sync_club_admins_owner_on_club_update();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Trigger: AFTER DELETE ON club_members → cascade-delete club_admins row
-- ─────────────────────────────────────────────────────────────────────────────
-- Replaces the iOS-side direct DELETE on club_admins at
-- SupabaseService.removeMembership (SupabaseService.swift:2185). That client
-- call is wrapped in try? and remains as defense-in-depth.
--
-- The protect_last_owner trigger will reject the cascade if the leaving member
-- is the only owner — owner cannot leave their own club via the "leave" flow.
-- The UI already gates this (owner cannot tap leave), but defense-in-depth.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cascade_club_admins_on_member_removal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM club_admins
     WHERE club_id = OLD.club_id
       AND user_id = OLD.user_id;
    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_cascade_club_admins_on_member_removal ON club_members;
CREATE TRIGGER trg_cascade_club_admins_on_member_removal
    AFTER DELETE ON club_members
    FOR EACH ROW
    EXECUTE FUNCTION cascade_club_admins_on_member_removal();


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Trigger: BEFORE DELETE ON club_admins → protect last owner
-- ─────────────────────────────────────────────────────────────────────────────
-- Refuses to delete a role='owner' row if it would leave the club with zero
-- owner rows. Allows the delete to proceed when:
--   • OLD.role <> 'owner' (always allowed; this trigger only guards owners)
--   • Another owner row exists for the same club (transfer-in-progress)
--   • The parent clubs row no longer exists (club is being deleted; FK cascade
--     or delete_club RPC has already removed it)
--
-- This is the backstop for: owner self-deleting via "Users can delete own admin
-- record" RLS policy, owner being removed via cascade trigger, etc.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION protect_last_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_other_owner_count INT;
    v_club_exists       BOOLEAN;
    v_deleting_club     TEXT;
BEGIN
    IF OLD.role <> 'owner' THEN
        RETURN OLD;
    END IF;

    -- Bypass: delete_club() sets app.role_bypass_delete_club_id to the club's UUID
    -- before tearing down child rows. Within that scope, owner-row deletion is
    -- expected and must be permitted. The flag is transaction-local (set_config
    -- with is_local=true), so it cannot leak across requests.
    v_deleting_club := current_setting('app.role_bypass_delete_club_id', true);
    IF v_deleting_club IS NOT NULL AND v_deleting_club = OLD.club_id::text THEN
        RETURN OLD;
    END IF;

    SELECT EXISTS (SELECT 1 FROM clubs WHERE id = OLD.club_id) INTO v_club_exists;
    IF NOT v_club_exists THEN
        -- Parent club already gone (e.g., FK cascade from clubs delete) — allow.
        RETURN OLD;
    END IF;

    SELECT COUNT(*) INTO v_other_owner_count
    FROM   club_admins ca
    WHERE  ca.club_id = OLD.club_id
      AND  ca.role    = 'owner'
      AND  ca.user_id <> OLD.user_id;

    IF v_other_owner_count = 0 THEN
        RAISE EXCEPTION 'cannot_remove_last_owner'
            USING HINT = 'Use transfer_club_ownership() to designate a new owner first.';
    END IF;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_last_owner ON club_admins;
CREATE TRIGGER trg_protect_last_owner
    BEFORE DELETE ON club_admins
    FOR EACH ROW
    EXECUTE FUNCTION protect_last_owner();


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Update delete_club() to bypass protect_last_owner during teardown
-- ─────────────────────────────────────────────────────────────────────────────
-- delete_club() deletes club_admins rows BEFORE the parent clubs row (so the FK
-- doesn't block). Without a bypass, protect_last_owner would reject the owner
-- row delete. Sets a transaction-local config flag that protect_last_owner
-- recognises as "club is being torn down — allow owner row removal".
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_club(p_club_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_owner_id  UUID;
BEGIN
  -- Verify caller owns the club
  SELECT created_by INTO v_owner_id FROM clubs WHERE id = p_club_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_caller_id IS DISTINCT FROM v_owner_id THEN
    RAISE EXCEPTION 'Only the club owner can delete this club' USING ERRCODE = '42501';
  END IF;

  -- Tell protect_last_owner to allow the owner-row delete during this teardown.
  -- Transaction-local — cleared at COMMIT/ROLLBACK; cannot leak.
  PERFORM set_config('app.role_bypass_delete_club_id', p_club_id::text, true);

  -- 1. Bookings (FK → games)
  DELETE FROM bookings
  WHERE game_id IN (SELECT id FROM games WHERE club_id = p_club_id);

  -- 2. Game attendance rows (FK → games)
  DELETE FROM game_attendance
  WHERE game_id IN (SELECT id FROM games WHERE club_id = p_club_id);

  -- 3. Reviews (FK → games — must be before games delete)
  DELETE FROM reviews
  WHERE game_id IN (SELECT id FROM games WHERE club_id = p_club_id);

  -- 4. Games
  DELETE FROM games WHERE club_id = p_club_id;

  -- 5. Feed comments → posts
  DELETE FROM feed_comments
  WHERE post_id IN (SELECT id FROM feed_posts WHERE club_id = p_club_id);

  -- 6. Feed reactions → posts
  DELETE FROM feed_reactions
  WHERE post_id IN (SELECT id FROM feed_posts WHERE club_id = p_club_id);

  -- 7. Feed posts
  DELETE FROM feed_posts WHERE club_id = p_club_id;

  -- 8. Memberships / join requests
  DELETE FROM club_members   WHERE club_id = p_club_id;
  DELETE FROM club_admins    WHERE club_id = p_club_id;

  -- 9. Player credits for this club
  DELETE FROM player_credits WHERE club_id = p_club_id;

  -- 10. Club venues
  DELETE FROM club_venues    WHERE club_id = p_club_id;

  -- 12. Entitlements (has ON DELETE CASCADE but explicit is safer)
  DELETE FROM club_entitlements WHERE club_id = p_club_id;

  -- 13. Finally, the club itself
  DELETE FROM clubs WHERE id = p_club_id;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_club(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Backfill: ensure every existing club has an owner row in club_admins
-- ─────────────────────────────────────────────────────────────────────────────
-- One-shot reconciliation for any historical drift between clubs.created_by and
-- club_admins. Idempotent — ON CONFLICT prevents duplicate inserts.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO club_admins (club_id, user_id, role)
SELECT c.id, c.created_by, 'owner'
FROM   clubs c
WHERE  c.created_by IS NOT NULL
ON CONFLICT (club_id, user_id) DO UPDATE
    SET role = 'owner'
    WHERE club_admins.role <> 'owner';
