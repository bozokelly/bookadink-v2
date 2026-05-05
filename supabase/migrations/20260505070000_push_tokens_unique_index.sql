-- Migration: push_tokens unique index for multi-device APNs fan-out
--
-- Why: iOS uploads each device's APNs token to push_tokens with the
-- `Prefer: resolution=merge-duplicates` header. Without a unique constraint
-- on (user_id, token), Postgres has nothing to merge against, so duplicate
-- rows accumulate (one per upload attempt) and PostgREST returns 409 once
-- the client retries. AppState.swift:1283 already references this gap in a
-- comment ("push_tokens has no unique constraint yet").
--
-- The Edge Function fan-out introduced alongside this migration reads
-- push_tokens and falls back to profiles.push_token when the table is empty.
-- A unique index ensures: (a) iOS merge-duplicates upserts collapse to a
-- single row per device, and (b) the fan-out never sends the same APNs
-- payload to a token twice for one event.
--
-- Idempotent: dedup pass keeps the lowest-ctid row per (user_id, token);
-- index creation is `IF NOT EXISTS`. Safe to re-apply.

-- Drop any duplicate (user_id, token) rows before adding the unique index.
-- ctid is a built-in physical row identifier — always present, no schema
-- assumption about a primary key column being named `id`.
DELETE FROM push_tokens t
WHERE t.ctid NOT IN (
  SELECT MIN(t2.ctid)
    FROM push_tokens t2
   WHERE t2.user_id = t.user_id
     AND t2.token = t.token
);

CREATE UNIQUE INDEX IF NOT EXISTS push_tokens_user_token_unique
  ON push_tokens(user_id, token);

COMMENT ON INDEX push_tokens_user_token_unique IS
  'Required by iOS merge-duplicates upsert and by the Edge Function multi-device APNs fan-out. Do not drop without first replacing the fan-out helper in supabase/functions/_shared/push-tokens.ts.';
