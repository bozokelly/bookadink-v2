-- Add reviewer_avatar_color_key to get_club_reviews so iOS/Android/Web
-- can render reviewer initials in the user's selected palette colour
-- without any per-platform derivation.

CREATE OR REPLACE FUNCTION get_club_reviews(p_club_id UUID)
RETURNS TABLE(
    id                       UUID,
    game_id                  UUID,
    user_id                  UUID,
    rating                   INT,
    comment                  TEXT,
    created_at               TIMESTAMPTZ,
    reviewer_name            TEXT,
    game_title               TEXT,
    reviewer_avatar_color_key TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        r.id,
        r.game_id,
        r.user_id,
        r.rating,
        r.comment,
        r.created_at,
        p.full_name          AS reviewer_name,
        g.title              AS game_title,
        p.avatar_color_key   AS reviewer_avatar_color_key
    FROM reviews r
    JOIN games g ON g.id = r.game_id AND g.club_id = p_club_id
    LEFT JOIN profiles p ON p.id = r.user_id
    ORDER BY r.created_at DESC
    LIMIT 50;
$$;

GRANT EXECUTE ON FUNCTION get_club_reviews(UUID) TO authenticated;
