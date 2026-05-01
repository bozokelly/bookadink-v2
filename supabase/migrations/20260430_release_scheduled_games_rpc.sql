-- Delayed game release: pg_cron + RPC
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   Games with a future publish_at became visible to members at the publish
--   time, but no push / in-app notification was ever dispatched. Only the
--   immediate-publish path (publish_at IS NULL) called game-published-notify.
--
-- DESIGN:
--   release_scheduled_games() — SECURITY DEFINER RPC that atomically claims
--   every game whose publish_at has arrived and whose notification has not
--   been sent. The claim is the idempotency guard:
--
--     UPDATE games
--        SET published_notification_sent_at = now()
--      WHERE publish_at IS NOT NULL
--        AND publish_at <= now()
--        AND published_notification_sent_at IS NULL
--      RETURNING …
--
--   PostgreSQL row locks ensure two concurrent cron ticks cannot both claim
--   the same row — the second tick sees published_notification_sent_at IS
--   NOT NULL and skips it.
--
--   The Edge Function `game-publish-release` calls this RPC, then for every
--   returned row fans out via the same _shared/notify-new-game.ts module
--   used by the immediate-publish path. Identical payload format, identical
--   member targeting, identical APNs grouping.
--
-- PREREQUISITES:
--   pg_cron extension enabled (Supabase Dashboard → Database → Extensions).
--   pg_net extension enabled (same location).
--   app.supabase_url + app.supabase_anon_key DB settings configured (same
--     settings used by promote_top_waitlisted and revert_expired_holds…).
--   games.published_notification_sent_at column added by
--     20260430_game_published_notification_idempotency.sql.
--
-- SAFE TO RE-RUN:
--   CREATE OR REPLACE is idempotent.
--   cron.schedule() replaces any existing job with the same name.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION release_scheduled_games()
RETURNS TABLE(
    game_id            UUID,
    game_title         TEXT,
    game_date_time     TIMESTAMPTZ,
    club_id            UUID,
    club_name          TEXT,
    created_by_user_id UUID,
    skill_level        TEXT,
    club_timezone      TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    WITH claimed AS (
        UPDATE games g
        SET    published_notification_sent_at = now()
        WHERE  g.publish_at IS NOT NULL
          AND  g.publish_at <= now()
          AND  g.published_notification_sent_at IS NULL
        RETURNING
            g.id,
            g.title,
            g.date_time,
            g.club_id,
            -- COALESCE so a NULL created_by (legacy / admin) does not break
            -- the .neq filter in the fan-out — any non-existent UUID is fine.
            COALESCE(g.created_by, '00000000-0000-0000-0000-000000000000'::UUID) AS created_by,
            g.skill_level
    )
    SELECT
        c.id                  AS game_id,
        c.title::text         AS game_title,
        c.date_time           AS game_date_time,
        c.club_id             AS club_id,
        cl.name::text         AS club_name,
        c.created_by          AS created_by_user_id,
        c.skill_level::text   AS skill_level,
        cl.timezone::text     AS club_timezone
    FROM   claimed c
    JOIN   clubs cl ON cl.id = c.club_id;
END;
$$;

REVOKE ALL ON FUNCTION release_scheduled_games() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION release_scheduled_games() TO service_role;

COMMENT ON FUNCTION release_scheduled_games() IS
    'Atomically claims every game whose publish_at has arrived and whose '
    'published_notification_sent_at IS NULL, returning the rows needed by '
    'the game-publish-release Edge Function to fan out new-game notifications. '
    'The UPDATE is the idempotency guard: concurrent cron ticks cannot double-claim.';

-- ── Schedule: run every 2 minutes ─────────────────────────────────────────────
-- Cadence rationale: 2 minutes keeps the user-perceived delay between
-- publish_at and notification arrival under ~3 minutes worst-case (one tick
-- could just have missed the row), while keeping the cron load minimal.
-- Tighten to 1 minute later if needed without code changes.
SELECT cron.schedule(
    'game-publish-release',
    '*/2 * * * *',
    $cron$SELECT net.http_post(url := current_setting('app.supabase_url', true) || '/functions/v1/game-publish-release', headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || current_setting('app.supabase_anon_key', true)), body := '{}'::jsonb)$cron$
);
