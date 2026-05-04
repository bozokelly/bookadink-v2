-- ─────────────────────────────────────────────────────────────────────────────
-- Lock down direct writes on club_admins
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDENCY: 20260504010000_club_role_lifecycle.sql must be applied first.
--   • promote_club_member_to_admin / demote_club_admin_to_member /
--     transfer_club_ownership RPCs are the new write path.
--   • AFTER INSERT trigger on clubs creates the owner row automatically.
--   • AFTER DELETE trigger on club_members cascades admin row removal.
--   • iOS Phase 6 already routes all role mutations through the RPCs.
--
-- WHAT THIS DOES:
--   Drops the three "Club owner can …" INSERT/UPDATE/DELETE policies that
--   permitted direct PostgREST writes from authenticated clients. After this
--   migration, club_admins can only be written by:
--     • SECURITY DEFINER functions (RPCs + triggers — bypass RLS)
--     • The "Users can delete own admin record" policy (kept — guarded by the
--       protect_last_owner BEFORE DELETE trigger, so the only legitimate use
--       is an admin voluntarily relinquishing their non-owner role)
--
-- WHAT THIS DOES NOT TOUCH:
--   • SELECT policies — iOS still needs to read role state.
--   • The protect_last_owner trigger — already in place.
--   • Any other table.
--
-- COMPATIBILITY NOTES:
--   • SupabaseService.createClub (createClub at SupabaseService.swift:1711) had
--     a try? POST to club_admins to seed the owner row. After this migration
--     that POST silently fails — fine, because trg_ensure_club_admins_owner_on_insert
--     does the work. The iOS call should be removed in a follow-up cleanup PR.
--   • SupabaseService.removeMembership (SupabaseService.swift:2185) had a try?
--     DELETE to strip the admin row when a member leaves. Same story: silently
--     fails post-migration; trg_cascade_club_admins_on_member_removal handles
--     it. Safe to remove from iOS later.
--
-- ROLLBACK:
--   Re-running 20260415030000_rls_hardening.sql restores the dropped policies.
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Club owner can insert club admins" ON club_admins;
DROP POLICY IF EXISTS "Club owner can update club admins" ON club_admins;
DROP POLICY IF EXISTS "Club owner can delete club admins" ON club_admins;

-- Note: "Users can delete own admin record" intentionally retained.
-- Note: Both SELECT policies ("Users can read own admin status",
--       "Club owner can read club admins", "Club admins can read sibling admins")
--       are intentionally retained — read access is unchanged.

COMMENT ON TABLE club_admins IS
    'Role assignments for club owners and admins. Writes are gated to '
    'SECURITY DEFINER functions only: promote_club_member_to_admin, '
    'demote_club_admin_to_member, transfer_club_ownership, plus triggers '
    'on clubs (owner row sync) and club_members (cascade on removal). '
    'Direct INSERT/UPDATE/DELETE from authenticated clients is denied; '
    'see migration 20260504020000_club_admins_lock_writes.sql.';
