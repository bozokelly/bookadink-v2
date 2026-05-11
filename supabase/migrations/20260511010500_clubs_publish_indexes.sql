-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 2C Slice A — Additive indexes for the new draft-lifecycle columns.
-- Both additive, both safe to drop.
--
-- The partial index `idx_clubs_publish_step_in_progress` keeps the index
-- small because only rows mid-onboarding (rare) match the predicate. The
-- full-row index on `is_published` supports the future RLS gate's anon
-- branch (`WHERE is_published = TRUE`) and PostgREST anon discovery.
--
-- Companion preflight: memory/plans/phase2c_0_preflight.md
--
-- ROLLBACK:
--   DROP INDEX IF EXISTS idx_clubs_publish_step_in_progress;
--   DROP INDEX IF EXISTS idx_clubs_is_published;
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_clubs_is_published
  ON clubs (is_published);

CREATE INDEX IF NOT EXISTS idx_clubs_publish_step_in_progress
  ON clubs (publish_step)
  WHERE publish_step <> 'published';
