-- ─────────────────────────────────────────────────────────────────────────────
-- Auto-insert owner into club_members on club creation
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDS ON: 20260504010000_club_role_lifecycle.sql (ensure_club_admins_owner_on_club_insert exists)
--
-- PROBLEM:
--   The iOS createClub flow (SupabaseService.swift:1727) manually inserts the
--   creator into club_members with status='approved'. Any other club-creation
--   path — admin SQL scripts, support tooling, future non-iOS clients — skips
--   that step. Result: the owner is in club_admins (via the AFTER INSERT
--   trigger on clubs) but NOT in club_members.
--
--   This breaks `transfer_club_ownership` when transferring BACK to the
--   original creator: the RPC's "approved member" check fails with
--   `new_owner_not_approved_member` because the creator never had a
--   club_members row.
--
--   Discovered during validation runs of 20260504030000 — the SQL-only
--   sandbox setup hit this gap, masking it as a "sandbox setup bug" until we
--   traced the iOS flow.
--
-- FIX:
--   Extend the existing AFTER INSERT trigger on clubs so it inserts into
--   club_members AS WELL AS club_admins. Atomic — both rows appear in the
--   same statement. Ensures every club, regardless of how it was created,
--   has a complete owner record.
--
-- COMPATIBILITY:
--   • iOS createClub still does its own try?-wrapped INSERT into club_members
--     at line 1727. ON CONFLICT DO UPDATE makes the trigger idempotent — both
--     paths end in the same state. Safe to leave the iOS call in place; it
--     can be removed in a later cleanup PR.
--   • Backfill block at the end repairs any historical clubs whose owner
--     never got a club_members row.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION ensure_club_admins_owner_on_club_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.created_by IS NOT NULL THEN
        -- Owner role row in club_admins (existing behaviour)
        INSERT INTO club_admins (club_id, user_id, role)
        VALUES (NEW.id, NEW.created_by, 'owner')
        ON CONFLICT (club_id, user_id) DO UPDATE SET role = 'owner';

        -- Owner membership row in club_members (NEW — closes the gap)
        INSERT INTO club_members (club_id, user_id, status)
        VALUES (NEW.id, NEW.created_by, 'approved')
        ON CONFLICT (club_id, user_id) DO UPDATE SET status = 'approved';

        -- Audit (existing behaviour)
        INSERT INTO club_role_audit (club_id, target_user_id, actor_user_id, change_type, old_role, new_role, reason)
        VALUES (NEW.id, NEW.created_by, NEW.created_by, 'club_created', NULL, 'owner', 'club_created');
    END IF;
    RETURN NEW;
END;
$$;

-- Backfill: any existing club whose owner is missing from club_members
INSERT INTO club_members (club_id, user_id, status)
SELECT c.id, c.created_by, 'approved'
FROM   clubs c
WHERE  c.created_by IS NOT NULL
  AND  NOT EXISTS (
    SELECT 1 FROM club_members cm
    WHERE  cm.club_id = c.id AND cm.user_id = c.created_by
  )
ON CONFLICT (club_id, user_id) DO NOTHING;
