-- get_pending_review_prompt: server-authoritative review eligibility check.
-- Returns the single highest-priority game that the calling user is eligible to review.
-- Eligibility:
--   1. Confirmed booking for the game (status = 'confirmed')
--   2. Game ended more than 24 hours ago
--   3. Game ended less than 30 days ago (avoids resurfacing very old games)
--   4. No review already submitted (reviews table, unique on user+game)
--   5. No explicit dismiss signal (game_review_request notification with read = true)
--
-- The cron-based send-review-prompts notification flow is unchanged and continues
-- to deliver push notifications. This RPC is a pull-based fallback so the prompt
-- surfaces even if the push was missed, dismissed, or the cron job is delayed.

CREATE OR REPLACE FUNCTION get_pending_review_prompt(p_user_id UUID)
RETURNS TABLE(
    game_id        UUID,
    game_title     TEXT,
    game_date_time TIMESTAMPTZ,
    club_id        UUID,
    club_name      TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        g.id          AS game_id,
        g.title       AS game_title,
        g.date_time   AS game_date_time,
        g.club_id     AS club_id,
        c.name        AS club_name
    FROM bookings b
    JOIN games  g ON g.id  = b.game_id
    JOIN clubs  c ON c.id  = g.club_id
    WHERE b.user_id  = p_user_id
      AND p_user_id  = auth.uid()           -- RLS guard: caller must own the query
      AND b.status   = 'confirmed'
      -- Game must have ended more than 24 hours ago
      AND (g.date_time + (g.duration_minutes * INTERVAL '1 minute')) < now() - INTERVAL '24 hours'
      -- Don't resurface games older than 30 days
      AND (g.date_time + (g.duration_minutes * INTERVAL '1 minute')) > now() - INTERVAL '30 days'
      -- User hasn't already submitted a review for this game
      AND NOT EXISTS (
          SELECT 1 FROM reviews r
          WHERE r.game_id = g.id
            AND r.user_id = p_user_id
      )
      -- User hasn't explicitly dismissed this prompt
      AND NOT EXISTS (
          SELECT 1 FROM notifications n
          WHERE n.user_id      = p_user_id
            AND n.type         = 'game_review_request'
            AND n.reference_id = g.id
            AND n.read         = true
      )
    ORDER BY g.date_time DESC
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_pending_review_prompt(UUID) TO authenticated;

-- dismiss_review_prompt: marks a review prompt as dismissed for the calling user.
-- Idempotent. Updates the existing notification to read=true, or inserts a read=true
-- sentinel row if send-review-prompts hasn't run yet. Both outcomes exclude the game
-- from future get_pending_review_prompt calls.
CREATE OR REPLACE FUNCTION dismiss_review_prompt(p_game_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
BEGIN
    UPDATE notifications
    SET read = true
    WHERE user_id      = v_user_id
      AND type         = 'game_review_request'
      AND reference_id = p_game_id;

    -- If no notification row existed (cron hasn't run), insert a dismissed sentinel.
    IF NOT FOUND THEN
        INSERT INTO notifications (user_id, type, reference_id, title, body, read)
        VALUES (v_user_id, 'game_review_request', p_game_id, '', '', true);
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION dismiss_review_prompt(UUID) TO authenticated;
