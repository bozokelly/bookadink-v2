# Club Role Audit + Push — Post-Deployment Verification

Targets:

- `20260504010000_club_role_lifecycle.sql` (RPCs + sync triggers)
- `20260504020000_club_admins_lock_writes.sql` (RLS)
- `20260504025000_notification_type_role_changed.sql` (enum)
- `20260504030000_role_audit_and_logging.sql` (audit + push trigger)
- Edge Function: `role-change-push` (deployed `--no-verify-jwt`)
- iOS build with the duplicate-`triggerNotify` removals applied

Run sections in order. Each query has an **Expected** result. Any deviation is a bug — report before continuing.

> **There is no `push_notification_log` table in this project.** The Postgres `pg_net` extension exposes `net._http_request` (outbound POSTs from triggers) and `net._http_response` (Edge Function responses). The diagnostic queries below use those.

---

## Pre-flight

```sql
-- 0a. Audit table + push trigger present
SELECT EXISTS (
  SELECT 1 FROM information_schema.tables
  WHERE table_schema='public' AND table_name='club_role_audit'
) AS audit_table_exists,
EXISTS (
  SELECT 1 FROM pg_trigger
  WHERE tgname='trg_enqueue_role_change_push' AND NOT tgisinternal
) AS push_trigger_exists,
EXISTS (
  SELECT 1 FROM pg_type t JOIN pg_enum e ON e.enumtypid=t.oid
  WHERE t.typname='notification_type' AND e.enumlabel='role_changed'
) AS role_changed_enum_value_exists;
-- Expected: all three TRUE
```

```sql
-- 0b. Edge Function trigger URL hard-coded (placeholder must be replaced)
SELECT prosrc FROM pg_proc WHERE proname='enqueue_role_change_push';
-- Expected: contains v_supabase_url := 'https://<your project ref>.supabase.co';
--           NOT 'REPLACE-WITH-PROJECT-REF'.
-- If still REPLACE-WITH-*, the placeholder was never substituted; pushes will
-- POST to a 404 URL and silently fail. Fix before continuing.
```

```sql
-- 0c. RPCs were re-created with audit + RAISE LOG (these bodies should contain
--     'INSERT INTO club_role_audit' AND 'RAISE LOG ''club_role:')
SELECT proname,
       prosrc LIKE '%INSERT INTO club_role_audit%' AS has_audit_insert,
       prosrc LIKE '%RAISE LOG ''club_role:%'      AS has_log_line
FROM pg_proc
WHERE proname IN (
  'promote_club_member_to_admin',
  'demote_club_admin_to_member',
  'transfer_club_ownership',
  'ensure_club_admins_owner_on_club_insert',
  'cascade_club_admins_on_member_removal'
)
ORDER BY proname;
-- Expected: all 5 rows; has_audit_insert=true for all 5;
--           has_log_line=true for the first 3 (the trigger functions
--           don't necessarily log, but they MUST audit-insert).
```

---

## Section 1 — Audit log integrity

```sql
-- 1a. Recent audit entries with resolved names (50 most recent)
SELECT cra.created_at,
       cra.change_type,
       cra.old_role,
       cra.new_role,
       c.name      AS club_name,
       p_target.full_name AS target_name,
       p_actor.full_name  AS actor_name,
       cra.reason
FROM   club_role_audit cra
LEFT JOIN clubs    c        ON c.id = cra.club_id
LEFT JOIN profiles p_target ON p_target.id = cra.target_user_id
LEFT JOIN profiles p_actor  ON p_actor.id  = cra.actor_user_id
ORDER BY cra.created_at DESC
LIMIT 50;
-- Expected:
--   • change_type ∈ {promoted_to_admin, demoted_to_member, transferred_in,
--     transferred_out_to_admin, transferred_out_to_member, club_created,
--     member_removed_cascade}
--   • old_role / new_role consistent with change_type:
--       promoted_to_admin   → old='member' new='admin'
--       demoted_to_member   → old='admin'  new='member'
--       transferred_in      → old='admin' or 'member' new='owner'
--       transferred_out_to_admin → old='owner' new='admin'
--       transferred_out_to_member → old='owner' new='member'
--       club_created        → old=NULL    new='owner'
--       member_removed_cascade → old IN {'owner','admin'} new=NULL
--   • actor_user_id matches the human who clicked the button.
--     For club_created: actor = target = creator.
--     For member_removed_cascade: actor is the owner/admin who removed the member,
--       OR NULL if the user removed themselves (auth.uid() inside the trigger
--       reflects the caller of DELETE FROM club_members).
```

```sql
-- 1b. Constraint check: no rows violate the change_type ↔ role contract
SELECT id, change_type, old_role, new_role
FROM club_role_audit
WHERE
  (change_type = 'promoted_to_admin'        AND new_role <> 'admin')
  OR (change_type = 'demoted_to_member'     AND old_role <> 'admin')
  OR (change_type = 'transferred_in'        AND new_role <> 'owner')
  OR (change_type = 'transferred_out_to_admin'  AND (old_role <> 'owner' OR new_role <> 'admin'))
  OR (change_type = 'transferred_out_to_member' AND (old_role <> 'owner' OR new_role <> 'member'))
  OR (change_type = 'club_created'          AND new_role <> 'owner')
  OR (change_type = 'member_removed_cascade' AND new_role IS NOT NULL);
-- Expected: 0 rows
```

```sql
-- 1c. Foreign-key sanity — no audit rows pointing at a deleted club or user
SELECT cra.id, cra.club_id, cra.target_user_id
FROM   club_role_audit cra
LEFT JOIN clubs c ON c.id = cra.club_id
LEFT JOIN auth.users u ON u.id = cra.target_user_id
WHERE  c.id IS NULL OR u.id IS NULL;
-- Expected: 0 rows. The FK ON DELETE CASCADE on club_id and target_user_id
-- guarantees this; any row here means the trigger or RLS bypassed the FK.
```

---

## Section 2 — Ownership transfer audit (CRITICAL)

Run a real transfer end-to-end and check the audit shape. Re-use the sandbox from `club_role_lifecycle.md` §Sandbox setup.

```sql
-- 2a. Snapshot before
SELECT created_at, change_type, target_user_id, actor_user_id, old_role, new_role
FROM   club_role_audit
WHERE  club_id = '<sandbox_club_id>'
ORDER BY created_at DESC LIMIT 5;
```

```sql
-- 2b. Promote :admin_id (so they qualify as approved member with admin role)
SELECT promote_club_member_to_admin('<sandbox_club_id>', '<admin_id>');

-- 2c. Run the transfer (as :owner_id → :admin_id, old becomes 'admin')
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<admin_id>', 'admin');
```

```sql
-- 2d. Verify exactly TWO new audit rows from the transfer, in the same second
SELECT created_at,
       change_type,
       target_user_id,
       actor_user_id,
       old_role,
       new_role
FROM   club_role_audit
WHERE  club_id = '<sandbox_club_id>'
ORDER BY created_at DESC LIMIT 2;
-- Expected:
--   row1: change_type='transferred_in',         target=:admin_id, actor=:owner_id, new_role='owner'
--   row2: change_type='transferred_out_to_admin', target=:owner_id, actor=:owner_id, old_role='owner', new_role='admin'
--   Both rows: created_at within ~1ms of each other (same statement).
```

```sql
-- 2e. Repeat with member-form: transfer back, old owner becomes 'member'
-- Run as :admin_id (current owner)
SELECT * FROM transfer_club_ownership('<sandbox_club_id>', '<owner_id>', 'member');

SELECT created_at, change_type, target_user_id, old_role, new_role
FROM club_role_audit
WHERE club_id='<sandbox_club_id>'
ORDER BY created_at DESC LIMIT 2;
-- Expected:
--   row1: change_type='transferred_in', target=:owner_id, new_role='owner'
--   row2: change_type='transferred_out_to_member', target=:admin_id, old_role='owner', new_role='member'
```

---

## Section 3 — Trigger coverage (no silent mutations)

For each operation, count audit rows BEFORE and AFTER. The diff must be exactly the expected number.

```sql
-- Helper: snapshot count
SELECT COUNT(*) AS audit_count_before FROM club_role_audit WHERE club_id='<sandbox_club_id>';
```

| Operation (run as the appropriate user) | Expected delta | Audit `change_type` |
|---|---|---|
| `SELECT promote_club_member_to_admin(...);` | +1 | `promoted_to_admin` |
| `SELECT demote_club_admin_to_member(...);` (target IS admin) | +1 | `demoted_to_member` |
| `SELECT demote_club_admin_to_member(...);` (target NOT admin — idempotent no-op) | **0** | none |
| `SELECT transfer_club_ownership(..., 'admin');` | +2 | `transferred_in` + `transferred_out_to_admin` |
| `SELECT transfer_club_ownership(..., 'member');` | +2 | `transferred_in` + `transferred_out_to_member` |
| `INSERT INTO clubs(...) VALUES (...);` (new club) | +1 (on the new club's id) | `club_created` |
| `DELETE FROM club_members WHERE ...` (target had admin row) | +1 | `member_removed_cascade` |
| `DELETE FROM club_members WHERE ...` (target had no admin row) | **0** | none |
| `SELECT delete_club(...);` | varies — bulk audit rows for every admin row removed during teardown | `member_removed_cascade` per former admin |

```sql
-- 3a. Verify the demote no-op rule (idempotency must NOT pollute audit)
-- :member_id is plain member with no admin row.
SELECT COUNT(*) FROM club_role_audit WHERE club_id='<sandbox_club_id>' AND target_user_id='<member_id>';  -- before
SELECT demote_club_admin_to_member('<sandbox_club_id>', '<member_id>');                                    -- as :owner_id
SELECT COUNT(*) FROM club_role_audit WHERE club_id='<sandbox_club_id>' AND target_user_id='<member_id>';  -- after
-- Expected: same count both sides. The RPC RETURN OUT_DEMOTED=FALSE.
```

```sql
-- 3b. Verify any role mutation outside an RPC fails (RLS lock-down) AND
--     therefore writes nothing to audit.
-- Run as :owner_id via authenticated:
INSERT INTO club_admins (club_id, user_id, role) VALUES
  ('<sandbox_club_id>', '<random_uuid>', 'admin');
-- Expected: error (no policy matches). No audit row.
SELECT COUNT(*) FROM club_role_audit
WHERE club_id='<sandbox_club_id>'
  AND target_user_id='<random_uuid>';
-- Expected: 0
```

---

## Section 4 — Push notification trigger fires

```sql
-- 4a. Recent outbound HTTP requests from the trigger
SELECT id, method, url, headers->>'Content-Type' AS content_type, body, created
FROM   net._http_request
WHERE  url LIKE '%/functions/v1/role-change-push'
ORDER BY created DESC
LIMIT 20;
-- Expected:
--   • One row per audit insert that survived the self-event filter.
--   • Method = 'POST'.
--   • URL = 'https://<project-ref>.supabase.co/functions/v1/role-change-push'
--     (matches what's hard-coded in enqueue_role_change_push).
--   • body is JSON with audit_id / club_id / target_user_id / change_type /
--     old_role / new_role keys.
```

```sql
-- 4b. Cross-check: every recent NON-self-event audit row has a corresponding
--     net._http_request enqueued. (Self-events: actor_user_id = target_user_id
--     are filtered; club_created is the canonical example.)
WITH recent AS (
  SELECT cra.id, cra.club_id, cra.target_user_id, cra.actor_user_id, cra.created_at
  FROM   club_role_audit cra
  WHERE  cra.created_at > now() - INTERVAL '1 hour'
    AND  (cra.actor_user_id IS NULL OR cra.actor_user_id <> cra.target_user_id)
)
SELECT r.id AS audit_id,
       r.created_at,
       (SELECT COUNT(*) FROM net._http_request hr
        WHERE hr.url LIKE '%/functions/v1/role-change-push'
          AND hr.body::text LIKE '%' || r.id::text || '%') AS posts_for_this_audit
FROM   recent r
ORDER BY r.created_at DESC;
-- Expected: posts_for_this_audit = 1 for every row.
-- 0 means the trigger silently failed (check Postgres logs for the
-- 'enqueue_role_change_push failed' RAISE LOG line).
```

```sql
-- 4c. Edge Function response status
SELECT id, status_code, content::text, created
FROM   net._http_response
WHERE  created > now() - INTERVAL '1 hour'
ORDER BY created DESC LIMIT 20;
-- Expected:
--   • 200 with body like {"notified":true,"pushed":true|false,"reason":"..."}
--   • 200 reasons OK to see: "user_pref_off", "no_token", "stale_token_cleared",
--     "duplicate_with_membership_removed", "no_copy_for_change_type"
--   • 404 → URL placeholder wasn't replaced
--   • 401 → function deployed WITHOUT --no-verify-jwt
--   • 500 → function logic crashed; check Edge Function logs in Supabase Studio
```

---

## Section 5 — Push delivery validation

There is no `push_notification_log` table in this project. Use the in-app `notifications` table (the Edge Function inserts a row there before sending APNs) and Edge Function logs.

```sql
-- 5a. In-app notifications written by role-change-push in the last hour
SELECT created_at, user_id, type, title, body, reference_id
FROM   notifications
WHERE  type = 'role_changed'
  AND  created_at > now() - INTERVAL '1 hour'
ORDER BY created_at DESC LIMIT 20;
-- Expected:
--   • One row per non-self-event audit insert (modulo the
--     duplicate_with_membership_removed skip).
--   • title / body match the change_type-specific copy in
--     supabase/functions/role-change-push/index.ts → composeCopy().
--   • reference_id = the club_id (taps deep-link to the club).
```

```sql
-- 5b. APNs delivery — visible via Edge Function logs only
-- In Supabase Studio → Edge Functions → role-change-push → Logs:
--   Look for "APNs error:" lines (failures).
--   Look for the function's response body to confirm pushed=true.
-- No SQL view of APNs delivery exists; the Edge Function's response is
-- the authoritative signal. CLAUDE.md "Diagnostic playbook" §3 is the
-- canonical pattern.
```

```sql
-- 5c. Duplicate detection: same target gets two notifications in <2s for the
--     same audit_id should NEVER happen. (Reads through the notifications row
--     for tell-tale duplicate body strings.)
SELECT user_id, body, COUNT(*) AS dup_count, MAX(created_at)-MIN(created_at) AS span
FROM   notifications
WHERE  type = 'role_changed'
  AND  created_at > now() - INTERVAL '1 day'
GROUP BY user_id, body
HAVING COUNT(*) > 1 AND MAX(created_at)-MIN(created_at) < INTERVAL '2 seconds';
-- Expected: 0 rows. If any: the trigger fired twice OR the iOS triggerNotify
-- removal in this PR didn't ship — re-check AppState.setOwnerMemberAdminAccess
-- and AppState.transferClubOwnership for residual triggerNotify calls.
```

---

## Section 6 — Self-event filtering

```sql
-- 6a. Confirm the trigger filter is in the live source
SELECT prosrc FROM pg_proc WHERE proname='enqueue_role_change_push';
-- Expected: contains "IF NEW.actor_user_id IS NOT NULL AND NEW.actor_user_id = NEW.target_user_id"
```

```sql
-- 6b. Synthesize a self-event by creating a club (actor=target=creator)
INSERT INTO clubs (name, image_url, created_by, win_condition)
VALUES ('SELF-EVENT-TEST', '', '<owner_id>', 'first_to_score')
RETURNING id;
-- Capture the new club id, call it :sef_club.
```

```sql
-- 6c. Audit row exists; net._http_request DOES NOT have a POST for this audit
SELECT id, change_type, target_user_id, actor_user_id
FROM   club_role_audit
WHERE  club_id = :sef_club;
-- Expected: 1 row, change_type='club_created', target=actor=:owner_id

SELECT COUNT(*) FROM net._http_request
WHERE  url LIKE '%/functions/v1/role-change-push'
  AND  body::text LIKE '%' || :sef_club || '%'
  AND  created > now() - INTERVAL '5 minutes';
-- Expected: 0 (filter held)
```

```sql
-- 6d. Cleanup
SELECT delete_club(:sef_club);
```

---

## Section 7 — Notification accuracy (manual)

After a real transfer (§2), the new owner's device should show:

| Field | Expected |
|---|---|
| Push title | `"You're now the club owner"` |
| Push body | `"You have been made the owner of <Club Name>."` |
| Notification Center grouping | Other role events for the same club appear under the same thread (`thread-id: club.<club_id>`) |
| Tap behavior | Opens the club detail screen (deep-link uses `reference_id = club_id`) |
| In-app notifications row title | `"Ownership transferred to you"` |
| In-app notifications row body | `"You are now the owner of <Club Name>."` |

For the outgoing owner (transferred to admin):

| Field | Expected |
|---|---|
| Push title | `"Ownership transferred"` |
| Push body | `"You stepped down as owner of <Club Name> and are now an admin."` |

Spot-check copy against `supabase/functions/role-change-push/index.ts` → `composeCopy()` if anything looks off.

---

## Section 8 — Failure isolation

> **Test technique**: deploy a deliberately-failing version of the Edge Function for ~5 minutes, run a role change, observe, then redeploy the working version. Or temporarily move the trigger URL to a 404 by editing `enqueue_role_change_push` and reapplying it.

```sql
-- 8a. Easiest reversible test: temporarily replace the trigger URL with a 404 path
CREATE OR REPLACE FUNCTION enqueue_role_change_push()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_supabase_url CONSTANT TEXT := 'https://<project-ref>.supabase.co';
        v_anon_key     CONSTANT TEXT := '<anon key>';
BEGIN
    IF NEW.actor_user_id IS NOT NULL AND NEW.actor_user_id = NEW.target_user_id THEN RETURN NEW; END IF;
    PERFORM net.http_post(
      url := v_supabase_url || '/functions/v1/role-change-push-DOES-NOT-EXIST',
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_anon_key),
      body := jsonb_build_object('audit_id', NEW.id)
    );
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'enqueue_role_change_push failed: % (audit_id=%)', SQLERRM, NEW.id;
    RETURN NEW;
END $$;
```

```sql
-- 8b. Run a role change. The RPC must succeed and the audit row must commit.
SELECT promote_club_member_to_admin('<sandbox_club_id>', '<member_id>');
SELECT EXISTS (
  SELECT 1 FROM club_role_audit
  WHERE club_id='<sandbox_club_id>' AND target_user_id='<member_id>' AND change_type='promoted_to_admin'
    AND created_at > now() - INTERVAL '1 minute'
) AS audit_committed;
-- Expected: TRUE. Role mutation succeeded; audit was inserted; push failed silently.
```

```sql
-- 8c. Confirm push attempt registered as 404 in net._http_response
SELECT status_code FROM net._http_response
WHERE created > now() - INTERVAL '1 minute' ORDER BY created DESC LIMIT 5;
-- Expected: 404 (or 400) for the deliberately-broken request.
```

```sql
-- 8d. RESTORE the original trigger by reapplying 20260504030000_role_audit_and_logging.sql §4.
-- Verify with the Section 0b query that the URL is back to /role-change-push.
```

---

## Section 9 — Stale token handling

```sql
-- 9a. Set a fake/expired push token on a test user
UPDATE profiles SET push_token = 'a' || repeat('0', 63) WHERE id = '<member_id>';

-- 9b. Trigger a role change that sends them a push
SELECT promote_club_member_to_admin('<sandbox_club_id>', '<member_id>');

-- 9c. Wait ~5 seconds for the function to call APNs and observe
SELECT id, status_code, content::text, created
FROM net._http_response
WHERE created > now() - INTERVAL '1 minute' ORDER BY created DESC LIMIT 3;
-- Expected: 200 response with content containing "stale_token_cleared".

-- 9d. Token should now be NULL
SELECT push_token FROM profiles WHERE id='<member_id>';
-- Expected: NULL
```

> The function uses APNs status 410 → clears `profiles.push_token` and returns `{"notified":true,"pushed":false,"reason":"stale_token_cleared"}`. The user must re-launch the iOS app to re-register a fresh token.

---

## Section 10 — Cross-device sync (manual)

| Step | Device | Action | Expected |
|---|---|---|---|
| 10.1 | A (`:owner_id`) | Promote `:member_id` via the iOS UI | "is now an admin" toast on A |
| 10.2 | B (`:member_id`, app in background) | — | APNs banner: "You're now an admin · `<club name>` — you can now manage members and create games." |
| 10.3 | B | Tap the banner | App opens at the club detail screen |
| 10.4 | B | Without re-launch, switch to club tab | Owner-tools UI visible (admin role propagated; the push triggered an in-app notification + iOS opened with fresh data) |
| 10.5 | A | Demote `:member_id` | "Admin access removed" toast on A |
| 10.6 | B | — | APNs banner: "Admin access removed · You no longer have admin access in `<club name>`." |
| 10.7 | B | Open notifications inbox | Two `role_changed` rows: most recent first ("Admin access removed", then "Admin access granted") |

> If steps 10.2 / 10.6 don't fire: the device has no `profiles.push_token` registered, OR the token was cleared (§9) and not re-registered, OR `notification_preferences.role_change_push = false` for that user. Check via the queries in §5a.

---

## QA sequence

Run as a single sweep against the sandbox after sections 1–10 pass.

1. Reset sandbox.
2. Capture audit baseline: `SELECT COUNT(*) FROM club_role_audit WHERE club_id='<sandbox_club_id>';` (should be 1 — the `club_created` row).
3. Promote `member_id`. Audit count should be 2. One push to `member_id`. Owner gets no push (self-actor filter does not apply here — actor=`owner_id`, target=`member_id`).
4. Demote `member_id`. Audit count = 3. Push to `member_id`.
5. Promote `member_id` again. Audit count = 4. Push to `member_id`.
6. Transfer ownership to `member_id`, old owner becomes admin. Audit count = 6 (+2). Two pushes: one to `member_id` ("ownership transferred to you"), one to `owner_id` ("you stepped down").
7. Remove `member_id` from the club. Cascade deletes their `club_admins` row. Audit count = 7. Skip-with-reason `duplicate_with_membership_removed` in net._http_response (the existing iOS membership_removed notification is the user-facing path).
8. `delete_club(<sandbox>)`. Cascade clears all rows; `club_role_audit` rows for the club are removed via `ON DELETE CASCADE`. Audit count for that club_id = 0.
9. Section 5c duplicate-detection query returns 0 rows for the entire test window.

Every step must:
- Succeed or fail deterministically (no partial state)
- Produce exactly the audit count delta expected
- Produce exactly the push count expected (target = recipient; actor never receives a push for their own action)

---

## Failure-mode crib sheet

| Symptom | Likely cause | First diagnostic |
|---|---|---|
| Section 0a `push_trigger_exists=false` | Migration `20260504030000` not applied | `\df enqueue_role_change_push` |
| Section 0b prosrc still shows `REPLACE-WITH-*` | Placeholders never substituted | Edit migration file, re-apply (CREATE OR REPLACE is idempotent) |
| Section 1a missing rows for known actions | `INSERT INTO club_role_audit` line missing from RPC body | `SELECT prosrc FROM pg_proc WHERE proname='promote_club_member_to_admin';` |
| Section 2d only 1 audit row after transfer | Transfer RPC body missing the second VALUES tuple | Check `transfer_club_ownership` source |
| Section 4a empty | Trigger detached or `net.http_post` failing fast | `SELECT tgenabled FROM pg_trigger WHERE tgname='trg_enqueue_role_change_push';` should be 'O'. Then check Postgres logs for `enqueue_role_change_push failed:` |
| Section 4c shows 401 | Edge Function deployed WITH JWT verification | Redeploy with `--no-verify-jwt` |
| Section 4c shows 404 | URL placeholder not substituted OR function not deployed | Check function URL in trigger; deploy function |
| Section 5a empty but 4c shows 200 | Edge Function couldn't insert notification — most likely missing `'role_changed'` enum value | Re-apply `20260504025000_notification_type_role_changed.sql` |
| Section 5c finds duplicates | iOS `triggerNotify(type:"admin_promoted")` or `"ownership_transferred"` still in code | `grep -n triggerNotify BookadinkV2/App/AppState.swift` — should NOT find admin_promoted / ownership_transferred |
| Section 6c shows POST for self-event | Self-event filter missing or wrong | Check `enqueue_role_change_push` source |
| Section 8b audit_committed=false | Trigger function bubbled an exception (didn't EXCEPTION-swallow) | Compare current source against migration file's `EXCEPTION WHEN OTHERS` block |
| Section 9d push_token still set | Edge Function never returned 410 to APNs (token might be valid in sandbox env) | Use `APNS_USE_SANDBOX=true` in dev to mimic; or test from a real iOS install |
