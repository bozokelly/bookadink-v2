# Club Role Lifecycle — Post-Deployment Verification

Targets the migrations:

- `20260504010000_club_role_lifecycle.sql` (RPCs + triggers + last-owner protection)
- `20260504020000_club_admins_lock_writes.sql` (RLS lock-down)
- `20260504030000_role_audit_and_logging.sql` (audit + RAISE LOG + push trigger — once landed)

Run sections in order. Each query has an **Expected** result. Any deviation is a bug — do **not** fix-and-continue without reporting.

> **Run mode:** Execute as `postgres` / `service_role` in the Supabase SQL Editor unless a section says otherwise. Sections marked **`AS authenticated`** must be run with a real user JWT (Supabase Studio "Run as user" or via PostgREST from the app).

---

## Pre-flight — schema + objects exist

```sql
-- 1. Required tables
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('clubs', 'club_admins', 'club_members', 'club_role_audit')
ORDER BY table_name;
-- Expected: 4 rows
```

```sql
-- 2. Required RPCs
SELECT proname,
       prosecdef AS is_security_definer,
       pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN (
    'promote_club_member_to_admin',
    'demote_club_admin_to_member',
    'transfer_club_ownership',
    'ensure_club_admins_owner_on_club_insert',
    'sync_club_admins_owner_on_club_update',
    'cascade_club_admins_on_member_removal',
    'protect_last_owner',
    'delete_club'
  )
ORDER BY proname;
-- Expected: 8 rows, all is_security_definer = true
```

```sql
-- 3. Required triggers
SELECT tgname, tgrelid::regclass AS on_table, pg_get_triggerdef(oid)
FROM pg_trigger
WHERE NOT tgisinternal
  AND tgname IN (
    'trg_ensure_club_admins_owner_on_insert',
    'trg_sync_club_admins_owner_on_update',
    'trg_cascade_club_admins_on_member_removal',
    'trg_protect_last_owner'
  )
ORDER BY tgname;
-- Expected: 4 rows, attached to clubs / clubs / club_members / club_admins respectively
```

```sql
-- 4. RLS policies on club_admins — direct writes must be GONE
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'club_admins'
ORDER BY cmd, policyname;
-- Expected (after 20260504020000):
--   No policy with cmd = 'INSERT'  (no row)
--   No policy with cmd = 'UPDATE'  (no row)
--   DELETE policies: ONLY "Users can delete own admin record"
--   SELECT policies: 3 retained (own / owner / sibling admins)
```

```sql
-- 5. Live function source matches migration intent
--    (CLAUDE.md flags migration-vs-live drift as a known hazard in this repo.)
SELECT proname, prosrc
FROM pg_proc
WHERE proname IN ('promote_club_member_to_admin', 'demote_club_admin_to_member',
                  'transfer_club_ownership', 'protect_last_owner', 'delete_club')
ORDER BY proname;
-- Expected: bodies match supabase/migrations/20260504010000_club_role_lifecycle.sql.
-- If any body differs, someone hand-edited via SQL Editor. Investigate before
-- trusting any subsequent test result.
```

---

## Sandbox setup (used by sections 4–9)

These tests need three real auth users. Edit the `WITH` block to point at three accounts you can log in as.

```sql
-- Sandbox: a clean test club + 3 known users.
-- All later sections reference :sandbox_club_id, :owner_id, :admin_id, :member_id.
-- Re-running this block tears down the previous sandbox first.

DO $$
DECLARE
    v_owner   UUID := '00000000-0000-0000-0000-000000000001';  -- replace with real auth.users.id
    v_admin   UUID := '00000000-0000-0000-0000-000000000002';  -- replace
    v_member  UUID := '00000000-0000-0000-0000-000000000003';  -- replace
    v_club_id UUID;
BEGIN
    -- Tear down any prior sandbox club for v_owner
    PERFORM delete_club(c.id)
    FROM clubs c
    WHERE c.created_by = v_owner AND c.name = 'ROLE-LIFECYCLE-SANDBOX';

    INSERT INTO clubs (name, image_url, created_by, win_condition)
    VALUES ('ROLE-LIFECYCLE-SANDBOX', '', v_owner, 'first_to_score')
    RETURNING id INTO v_club_id;

    -- Approve admin + member into the sandbox so RPCs accept them
    INSERT INTO club_members (club_id, user_id, status) VALUES
        (v_club_id, v_admin,  'approved'),
        (v_club_id, v_member, 'approved');

    RAISE NOTICE 'sandbox_club_id = %', v_club_id;
END $$;

-- Capture the club id for later sections
SELECT id AS sandbox_club_id FROM clubs WHERE name = 'ROLE-LIFECYCLE-SANDBOX';
```

---

## Section 1 — Ownership consistency audit (CRITICAL)

```sql
-- Every club's created_by must match exactly one club_admins row with role='owner'.
SELECT c.id,
       c.name,
       c.created_by,
       array_agg(ca.user_id) FILTER (WHERE ca.role = 'owner') AS owner_user_ids
FROM clubs c
LEFT JOIN club_admins ca ON ca.club_id = c.id
GROUP BY c.id, c.name, c.created_by
HAVING NOT (array_agg(ca.user_id) FILTER (WHERE ca.role = 'owner') = ARRAY[c.created_by]);
-- Expected: 0 rows.
-- If any club appears: drift between clubs.created_by and club_admins.
-- The backfill in 20260504010000 §9 should have closed this — investigate
-- before continuing.
```

```sql
-- Every owner row must have a parent club.
SELECT ca.club_id, ca.user_id
FROM club_admins ca
LEFT JOIN clubs c ON c.id = ca.club_id
WHERE ca.role = 'owner' AND c.id IS NULL;
-- Expected: 0 rows.
```

```sql
-- No club has ≥ 2 owner rows.
SELECT club_id, COUNT(*) AS owner_count
FROM club_admins
WHERE role = 'owner'
GROUP BY club_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows.
```

---

## Section 2 — Last-owner protection

```sql
-- 2a. Direct DELETE of the only owner row (run as the owner via authenticated)
-- Expected: ERROR: cannot_remove_last_owner (raised by trg_protect_last_owner)
DELETE FROM club_admins
WHERE club_id = '<sandbox_club_id>'
  AND role = 'owner';
```

```sql
-- 2b. Owner self-removal via "Users can delete own admin record" policy
-- Run as :owner_id.
-- Expected: ERROR: cannot_remove_last_owner
DELETE FROM club_admins
WHERE club_id = '<sandbox_club_id>'
  AND user_id = '<owner_id>';
```

```sql
-- 2c. Confirm the owner row survived both rejections
SELECT user_id, role
FROM club_admins
WHERE club_id = '<sandbox_club_id>' AND role = 'owner';
-- Expected: 1 row, user_id = :owner_id
```

---

## Section 3 — Direct write enforcement (RLS lock-down)

Run **`AS authenticated`** with the owner's JWT. These should all fail.

```sql
-- 3a. Direct INSERT — blocked
-- Expected: 401 / 403 / "permission denied for table club_admins" / 42501
INSERT INTO club_admins (club_id, user_id, role)
VALUES ('<sandbox_club_id>', '<member_id>', 'admin');
```

```sql
-- 3b. Direct UPDATE — blocked
-- Expected: same as above; if it succeeds, the migration didn't apply
UPDATE club_admins SET role = 'admin'
WHERE club_id = '<sandbox_club_id>' AND user_id = '<owner_id>';
```

```sql
-- 3c. Direct DELETE of someone else — blocked
-- Expected: blocked (no policy matches; row count = 0 means RLS hid it)
DELETE FROM club_admins
WHERE club_id = '<sandbox_club_id>' AND user_id = '<admin_id>';
SELECT COUNT(*) FROM club_admins WHERE club_id = '<sandbox_club_id>' AND user_id = '<admin_id>';
-- Expected: row still exists if admin_id had been promoted (run section 4 first to create the row)
```

```sql
-- 3d. Self-DELETE for non-owner (the one retained policy) — allowed
-- Run as :admin_id (after promote in section 4)
DELETE FROM club_admins
WHERE club_id = '<sandbox_club_id>' AND user_id = '<admin_id>';
-- Expected: 1 row deleted; protect_last_owner does NOT fire because role <> 'owner'
```

---

## Section 4 — Role transition matrix

Run **`AS authenticated`** with the appropriate JWT for each row.

| # | Run as | Statement | Expected |
|---|---|---|---|
| 4.1 | `:owner_id` | `SELECT promote_club_member_to_admin('<sandbox_club_id>', '<member_id>');` | ✅ Returns row; `member_id` now has `club_admins.role='admin'` |
| 4.2 | `:owner_id` | `SELECT demote_club_admin_to_member('<sandbox_club_id>', '<member_id>');` | ✅ Returns row; `member_id` no longer in `club_admins` |
| 4.3 | `:admin_id` (already admin from 4.1 redo) | `SELECT promote_club_member_to_admin('<sandbox_club_id>', '<member_id>');` | ❌ `forbidden_owner_only` |
| 4.4 | `:admin_id` | `SELECT demote_club_admin_to_member('<sandbox_club_id>', '<owner_id>');` | ❌ `forbidden_owner_only` |
| 4.5 | `:owner_id` | `SELECT promote_club_member_to_admin('<sandbox_club_id>', '<owner_id>');` | ❌ `cannot_modify_self` |
| 4.6 | `:owner_id` | `SELECT demote_club_admin_to_member('<sandbox_club_id>', '<owner_id>');` | ❌ `cannot_modify_self` |
| 4.7 | `:owner_id` | `SELECT promote_club_member_to_admin('<sandbox_club_id>', '<random_non_member_uuid>');` | ❌ `target_not_approved_member` |
| 4.8 | `:owner_id` | Reset: `SELECT demote_club_admin_to_member('<sandbox_club_id>', '<admin_id>');` (idempotent if row missing) | ✅ Returns row, no error |

Verify after each row:

```sql
SELECT user_id, role FROM club_admins
WHERE club_id = '<sandbox_club_id>' ORDER BY role, user_id;
```

---

## Section 5 — Ownership transfer

```sql
-- Setup: ensure :admin_id is an admin (call promote first if needed)
SELECT promote_club_member_to_admin('<sandbox_club_id>', '<admin_id>');

-- 5a. Transfer to admin_id; old owner becomes 'admin'
-- Run as :owner_id
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<admin_id>', 'admin');
-- Expected: row with out_new_owner_id = :admin_id, out_old_owner_id = :owner_id, out_old_owner_role = 'admin'

-- 5b. Verify state
SELECT created_by FROM clubs WHERE id = '<sandbox_club_id>';
-- Expected: :admin_id

SELECT user_id, role FROM club_admins WHERE club_id = '<sandbox_club_id>' ORDER BY role, user_id;
-- Expected: :admin_id → 'owner', :owner_id → 'admin'. Exactly 1 'owner' row.

-- 5c. Transfer back; old owner (now :admin_id) becomes 'member' (row removed)
-- Run as :admin_id (the new owner)
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<owner_id>', 'member');
-- Expected: out_old_owner_role = 'member'

SELECT user_id, role FROM club_admins WHERE club_id = '<sandbox_club_id>' ORDER BY role, user_id;
-- Expected: only :owner_id remains, role='owner'. :admin_id has NO row (member status only).
```

```sql
-- 5d. Non-owner attempts transfer — rejected
-- Run as :admin_id (currently NOT owner)
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<member_id>', 'admin');
-- Expected: ERROR: forbidden_owner_only
```

```sql
-- 5e. Transfer to non-member — rejected
-- Run as :owner_id
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '00000000-0000-0000-0000-deadbeefcafe', 'admin');
-- Expected: ERROR: new_owner_not_approved_member
```

```sql
-- 5f. Invalid old-owner role — rejected
-- Run as :owner_id
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<admin_id>', 'banana');
-- Expected: ERROR: invalid_old_owner_role
```

```sql
-- 5g. Self-transfer is a no-op (not an error)
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<owner_id>', 'admin');
-- Expected: 1 row, out_old_owner_role = NULL, no state change
SELECT user_id, role FROM club_admins WHERE club_id = '<sandbox_club_id>' AND role='owner';
-- Expected: still :owner_id only
```

---

## Section 6 — Trigger integrity

```sql
-- 6a. Create a new club; owner row should appear automatically
DO $$
DECLARE v_id UUID;
BEGIN
    INSERT INTO clubs (name, image_url, created_by, win_condition)
    VALUES ('TRIGGER-TEST', '', '<owner_id>', 'first_to_score')
    RETURNING id INTO v_id;
    RAISE NOTICE 'new club id = %', v_id;
END $$;

SELECT ca.user_id, ca.role
FROM clubs c
JOIN club_admins ca ON ca.club_id = c.id
WHERE c.name = 'TRIGGER-TEST';
-- Expected: 1 row, user_id = :owner_id, role='owner'
-- (No iOS code touched club_admins — only trg_ensure_club_admins_owner_on_insert)
```

```sql
-- 6b. Update created_by; new owner row should appear
UPDATE clubs SET created_by = '<admin_id>'
WHERE name = 'TRIGGER-TEST';

SELECT ca.user_id, ca.role
FROM clubs c
JOIN club_admins ca ON ca.club_id = c.id
WHERE c.name = 'TRIGGER-TEST'
ORDER BY role;
-- Expected: 2 rows. :admin_id → 'owner' (new), :owner_id → 'owner' (old, not auto-cleaned —
-- that's transfer_club_ownership's job, not the bare trigger's). The trigger only adds.
-- Cleanup:
SELECT delete_club((SELECT id FROM clubs WHERE name = 'TRIGGER-TEST'));
```

```sql
-- 6c. Remove a member; their admin row (if any) should cascade-delete
INSERT INTO club_members (club_id, user_id, status) VALUES
  ('<sandbox_club_id>', '<member_id>', 'approved')
ON CONFLICT (club_id, user_id) DO UPDATE SET status='approved';

SELECT promote_club_member_to_admin('<sandbox_club_id>', '<member_id>');
SELECT EXISTS (SELECT 1 FROM club_admins WHERE club_id='<sandbox_club_id>' AND user_id='<member_id>') AS before_remove;

DELETE FROM club_members WHERE club_id='<sandbox_club_id>' AND user_id='<member_id>';

SELECT EXISTS (SELECT 1 FROM club_admins WHERE club_id='<sandbox_club_id>' AND user_id='<member_id>') AS after_remove;
-- Expected: before_remove = true, after_remove = false (cascade fired)
```

---

## Section 7 — Multi-device consistency (manual)

Pre-req: log `:admin_id` into BOTH iOS device A and device B with the same account.

| Step | Device | Action | Expected |
|---|---|---|---|
| 7.1 | A (owner) | Promote `:member_id` to admin in Manage Members | "is now an admin" toast |
| 7.2 | A (owner) | Reopen the member sheet | Shows "Admin" pill, "Remove Admin" button |
| 7.3 | B (`member_id`) | Open the app cold | Owner-tools menu visible in club, admin-only screens unlocked |
| 7.4 | A | Demote `:member_id` | "Admin access removed" toast |
| 7.5 | B | Background app, foreground without relaunching | After ≤30s the role refresh on next view-appearance hides admin UI; if not, re-open the club tab — `clubAdminRoleByClubID` re-fetches |
| 7.6 | B | Cold launch | Admin UI gone (DB truth via `fetchAllAdminRoles`) |

> Once `20260504030000` lands and the `role-change-push` Edge Function is deployed, step 7.5 should reflect within seconds via a server-driven push that triggers a refresh on device B without requiring a foreground/background cycle. Until then, the gap is "next view-appearance" not "instant".

---

## Section 8 — Mid-session ownership transfer (manual)

| Step | Device | Action | Expected |
|---|---|---|---|
| 8.1 | A (owner) | Open `:admin_id`'s member sheet | "Transfer Ownership" button visible |
| 8.2 | A | Tap → "Transfer — I'll stay as Admin" | "Club ownership transferred" toast; sheet dismisses |
| 8.3 | A | Open the club detail tab | "Owner" pill GONE; "Admin" pill present; create-game still allowed (admin retains create permission); Plan & Billing tab gated |
| 8.4 | A | Try Transfer Ownership again | Button no longer visible (you're not owner) |
| 8.5 | B (`admin_id`) | Cold launch | "Owner" badge present; full owner-tools menu visible |

```sql
-- 8.6 SQL spot check after step 8.2
SELECT created_by FROM clubs WHERE id='<sandbox_club_id>';  -- :admin_id
SELECT user_id, role FROM club_admins WHERE club_id='<sandbox_club_id>' ORDER BY role;
-- Expected: :admin_id='owner', :owner_id='admin'. Single 'owner' row.
```

```sql
-- 8.7 Transfer back so subsequent sections work as expected
-- Run as :admin_id (current owner)
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<owner_id>', 'admin');
```

---

## Section 9 — Destructive flow (delete club)

```sql
-- 9a. Verify delete_club works through the protect_last_owner bypass
-- Run as :owner_id
SELECT delete_club('<sandbox_club_id>');
-- Expected: VOID returned, no error. The transaction-local
-- app.role_bypass_delete_club_id config allows owner-row removal.

-- 9b. Confirm cascade
SELECT
  (SELECT COUNT(*) FROM clubs WHERE id='<sandbox_club_id>')        AS clubs_remaining,
  (SELECT COUNT(*) FROM club_admins WHERE club_id='<sandbox_club_id>') AS admins_remaining,
  (SELECT COUNT(*) FROM club_members WHERE club_id='<sandbox_club_id>') AS members_remaining;
-- Expected: 0, 0, 0
```

```sql
-- 9c. Non-owner cannot delete
-- Run as :admin_id (re-create a sandbox first if you tore it down)
SELECT delete_club('<sandbox_club_id>');
-- Expected: ERROR 42501 'Only the club owner can delete this club'
```

```sql
-- 9d. Bypass flag does not leak across transactions
-- After 9a finished:
SELECT current_setting('app.role_bypass_delete_club_id', true);
-- Expected: NULL or '' (the is_local=true scope ended at COMMIT)
```

---

## QA sequence — long-running scenario

Run end-to-end once after sections 1–9 pass. Each must succeed; no partial state.

1. Recreate sandbox.
2. Promote `member_id` → admin → demote → promote again. Verify each step server-side.
3. Transfer ownership `owner_id` → `admin_id` (admin role for old). Then back, with old becoming member.
4. Promote `admin_id` (now plain member) → admin. Demote. Re-add via promote.
5. Self-leave as admin: as `admin_id`, `DELETE FROM club_members WHERE user_id='<admin_id>' AND club_id='<sandbox_club_id>'`. Verify cascade trigger removes the admin row too.
6. Self-leave as member: as `member_id`, same. Verify no club_admins row existed and no error.
7. Delete the sandbox club via `delete_club`.
8. Verify `club_role_audit` (once §3 of the audit migration lands) recorded all of the above with the correct actor_user_id, change_type, and timestamps. Cross-check counts against the manual sequence.

---

## Cleanup

```sql
-- Removes any sandbox clubs left behind by aborted runs.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT id FROM clubs WHERE name IN ('ROLE-LIFECYCLE-SANDBOX', 'TRIGGER-TEST') LOOP
        PERFORM delete_club(r.id);
    END LOOP;
END $$;
```

---

## Failure-mode crib sheet

| Symptom | Likely cause | First diagnostic |
|---|---|---|
| Section 1 returns rows | Backfill in `20260504010000` §9 didn't run, or live DB diverged | `SELECT prosrc FROM pg_proc WHERE proname='ensure_club_admins_owner_on_club_insert';` then re-run the backfill block |
| Section 2 succeeds (no error raised) | `trg_protect_last_owner` missing or detached | `SELECT * FROM pg_trigger WHERE tgname='trg_protect_last_owner';` |
| Section 3 succeeds (writes go through) | RLS lock-down migration not applied | Re-check policies with the pre-flight §4 query |
| Section 4.5/4.6 succeed | RPC body missing the `cannot_modify_self` check | `SELECT prosrc FROM pg_proc WHERE proname='promote_club_member_to_admin';` |
| Section 5b shows two owner rows | `transfer_club_ownership` failed between trigger fire and old-owner update; rolled back partially | Check Postgres logs for `RAISE EXCEPTION`; transaction should have been atomic — investigate concurrent activity |
| Section 6c after_remove = true | `trg_cascade_club_admins_on_member_removal` not attached or disabled | `SELECT tgenabled FROM pg_trigger WHERE tgname='trg_cascade_club_admins_on_member_removal';` |
| Section 7.6 device B still shows admin | iOS bootstrap `fetchAllAdminRoles` failed silently | Check `AppState` debug log; check user JWT not expired |
| Section 9a errors with `cannot_remove_last_owner` | `delete_club` is the OLD version (without `set_config` line) | `SELECT prosrc FROM pg_proc WHERE proname='delete_club';` — re-apply `20260504010000` §8 |
