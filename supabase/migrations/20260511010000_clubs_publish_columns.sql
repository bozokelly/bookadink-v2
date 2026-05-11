-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 2C Slice A — Additive only. Adds the four club draft-lifecycle columns
-- without touching RLS, RPCs, or iOS code.
--
-- Every existing row is back-filled atomically to `is_published=TRUE` and
-- `publish_step='published'` via the column DEFAULT clauses on the same
-- ALTER TABLE statement. `published_at` is back-filled from `created_at` in
-- the same transaction so existing rows have a non-NULL publish timestamp.
--
-- Companion preflight: memory/plans/phase2c_0_preflight.md
--
-- INVARIANTS PRESERVED:
--   • The "Public can read clubs" SELECT policy from
--     20260415030000_rls_hardening.sql remains `USING (true)`. Discovery
--     for anon and authenticated callers is unchanged after this migration.
--   • iOS `fetchClubs` / `fetchClubDetail` SELECT strings are NOT yet updated.
--     PostgREST returns the same JSON shape it returned yesterday, because
--     the new columns are not enumerated in any iOS `select=` query string.
--   • No RPC reads or writes the new columns. The legacy `StartClubSheet`
--     INSERT path continues to produce immediately-public clubs (column
--     DEFAULT 'published' / TRUE fires for every INSERT that does not
--     enumerate these columns — including every iOS INSERT today).
--
-- VERIFICATION AFTER APPLY (all six must return their expected counts):
--   SELECT count(*) FROM clubs WHERE is_published IS NULL;                              -- 0
--   SELECT count(*) FROM clubs WHERE publish_step IS NULL;                              -- 0
--   SELECT count(*) FROM clubs WHERE publish_step NOT IN
--     ('draft','rules_set','branded','plan_chosen','first_game_created','published');   -- 0
--   SELECT count(*) FROM clubs WHERE published_at IS NULL;                              -- 0
--   SELECT count(*) FROM clubs WHERE published_at < created_at;                         -- 0
--   SELECT count(*) FROM clubs WHERE publish_step = 'published';                        -- == total clubs
--
-- ROLLBACK:
--   BEGIN;
--     ALTER TABLE clubs DROP CONSTRAINT IF EXISTS clubs_publish_step_check;
--     ALTER TABLE clubs
--       DROP COLUMN IF EXISTS draft_data,
--       DROP COLUMN IF EXISTS published_at,
--       DROP COLUMN IF EXISTS is_published,
--       DROP COLUMN IF EXISTS publish_step;
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

BEGIN;

ALTER TABLE clubs
  ADD COLUMN IF NOT EXISTS publish_step  TEXT        NOT NULL DEFAULT 'published',
  ADD COLUMN IF NOT EXISTS is_published  BOOLEAN     NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS published_at  TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS draft_data    JSONB       NULL;

-- Named CHECK constraint so a future step addition can drop / re-add cleanly.
ALTER TABLE clubs
  DROP CONSTRAINT IF EXISTS clubs_publish_step_check;

ALTER TABLE clubs
  ADD CONSTRAINT clubs_publish_step_check
  CHECK (publish_step IN (
    'draft',
    'rules_set',
    'branded',
    'plan_chosen',
    'first_game_created',
    'published'
  ));

-- Back-fill: every existing row gets a non-NULL published_at sourced from
-- created_at. New rows continue to receive NULL until publish_club() sets it
-- (a later slice). Idempotent — re-running this UPDATE is a no-op.
UPDATE clubs
   SET published_at = COALESCE(published_at, created_at)
 WHERE published_at IS NULL;

COMMIT;
