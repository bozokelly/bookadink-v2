-- Delayed-publish notification idempotency
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   Games created with a future publish_at were never notified to club members.
--   Immediate-publish games (publish_at IS NULL) trigger game-published-notify
--   from the iOS createGameForClub path, but delayed games had no server-side
--   release worker — they just became visible at publish_at without any push.
--
-- DESIGN:
--   A new pg_cron job + RPC + Edge Function (game-publish-release) handles
--   the delayed path. This column is the single idempotency guard shared by
--   the immediate path (set after game-published-notify succeeds in iOS) and
--   the delayed path (set atomically by release_scheduled_games() RPC).
--
--   The RPC uses UPDATE ... RETURNING with the published_notification_sent_at
--   IS NULL filter so concurrent cron ticks cannot double-claim a game.
--
-- BACKFILL:
--   All existing rows where publish_at IS NULL OR publish_at <= now() are set
--   to now() so the cron worker does not retroactively notify members about
--   already-released games when it first runs.
--
-- SAFE TO RE-RUN:
--   ADD COLUMN IF NOT EXISTS + UPDATE WHERE … IS NULL is idempotent.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE games
    ADD COLUMN IF NOT EXISTS published_notification_sent_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN games.published_notification_sent_at IS
    'Set to now() when the new-game push/in-app fan-out has been dispatched. '
    'For immediate-publish games (publish_at IS NULL) this is set by the iOS '
    'create flow after game-published-notify returns. For delayed-publish '
    'games it is set atomically inside release_scheduled_games() before the '
    'fan-out runs, preventing duplicate notifications across cron ticks.';

-- Backfill: every game already visible to members should be marked notified
-- so the cron worker does not send a wave of historical "new game" notifications
-- the first time it runs.
UPDATE games
SET    published_notification_sent_at = COALESCE(published_notification_sent_at, now())
WHERE  published_notification_sent_at IS NULL
  AND  (publish_at IS NULL OR publish_at <= now());

-- Partial index optimised for the cron query: the worker scans a tiny set of
-- delayed games whose release time has arrived and that have not been notified.
CREATE INDEX IF NOT EXISTS idx_games_publish_release_pending
    ON games (publish_at)
    WHERE publish_at IS NOT NULL
      AND published_notification_sent_at IS NULL;
