-- Migration: drop legacy single-row UNIQUE(user_id) on push_tokens
--
-- Why: push_tokens was originally created with `user_id UUID UNIQUE` (auto-named
-- `push_tokens_user_id_key`), back when the table held one row per user. Once
-- iOS started uploading per-device tokens (iPhone + iPad), the second device's
-- INSERT trips:
--
--   duplicate key value violates unique constraint "push_tokens_user_id_key"
--
-- The 2026-05-05 migration added `push_tokens_user_token_unique ON (user_id,
-- token)` to support `Prefer: resolution=merge-duplicates`, but the older
-- `UNIQUE(user_id)` was never dropped — so iOS's PostgREST upsert merges on the
-- right index but still violates the wrong one. Result: iPad's token never
-- lands, multi-device fan-out only ever sees one row.
--
-- This migration drops the legacy constraint *and* its underlying index name,
-- in either order, while preserving `push_tokens_user_token_unique`. The
-- partial-failure safety here is important: if `push_tokens_user_id_key` was
-- defined as a table CONSTRAINT, dropping the constraint also drops the index
-- of the same name. If it was added as a bare INDEX (older hand-edits via SQL
-- Editor sometimes do this), the index needs an explicit DROP. We do both
-- with `IF EXISTS` so re-applying the migration is a no-op.
--
-- Hard constraints:
-- * `push_tokens_user_token_unique` MUST remain — it's how iOS's
--   merge-duplicates upsert and the Edge Function fan-out de-dup tokens.
-- * Existing token rows are preserved; this only loosens uniqueness.
-- * RLS policies on push_tokens are unaffected.

ALTER TABLE public.push_tokens
  DROP CONSTRAINT IF EXISTS push_tokens_user_id_key;

DROP INDEX IF EXISTS public.push_tokens_user_id_key;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_indexes
     WHERE schemaname = 'public'
       AND tablename  = 'push_tokens'
       AND indexname  = 'push_tokens_user_token_unique'
  ) THEN
    RAISE EXCEPTION
      'push_tokens_user_token_unique is missing — apply 20260505070000_push_tokens_unique_index.sql before this migration';
  END IF;
END $$;
