-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — Phase 5A: read-only display RPC.
--
-- Exposes safe, display-shaped partnership data for a single game so the iOS
-- (and future web/Android) client can render the "registered players as pairs"
-- UI on a partnered game. RLS on booking_partnerships is intentionally
-- locked down (no policies), so a SECURITY DEFINER RPC is the only read
-- surface.
--
-- WHAT THIS RPC RETURNS:
--   One row per active (pending|complete) partnership in the requested game,
--   ordered by creation time (stable display). Cancelled partnerships are
--   filtered out. Each row carries:
--     - partnership_id, status, created_at
--     - player A booking + user_id + display name + DUPR rating
--     - player B booking + user_id + display name + DUPR rating
--       (NULL when pending and no partner is paired yet)
--     - requested_partner_user_id + name (the "intent" — who the requester
--       wanted to pair with). On complete rows this equals player_b's user;
--       on pending rows it is set when the caller used p_partner_user_id
--       and NULL when the caller used p_allocate_partner.
--
-- WHAT IT DOES NOT RETURN:
--   Email, phone, emergency contacts, dupr_id strings — same privacy posture
--   as the existing get_club_reviews RPC.
--
-- DUPR RATING EXPOSURE:
--   Only included when the game has `requires_dupr = TRUE`. Mirrors the
--   existing client convention that DUPR ratings are only shown on
--   DUPR-required games (NULL'd at source for non-DUPR games — the client
--   need not gate display itself).
--
-- AUTHORISATION:
--   Authenticated callers only. RLS on booking_partnerships remains
--   enabled with zero policies; this RPC is the only authenticated read
--   path. Anon callers receive `authentication_required`.
--   Within the authenticated set, no further role gating — the partnership
--   row IS the public game roster expressed differently, so any
--   authenticated user who could view the player list on a solo game
--   can view the partnership list on the partnered version.
--
-- INVARIANTS PRESERVED:
--   • Every column reference is alias-qualified per CLAUDE.md
--     RETURNS-TABLE rules (bp., ba., bb., pa., pb., rp., g.).
--   • No write to any table; no side effects.
--   • RLS on booking_partnerships unchanged (still enabled, no policies).
--   • RPC bypasses RLS via SECURITY DEFINER.
--   • bookings + profiles RLS bypassed inside the function so partner names
--     resolve cleanly for all viewers (mirrors get_club_reviews).
--
-- VERIFICATION AFTER APPLY:
--   SELECT pg_get_function_identity_arguments(oid)
--     FROM pg_proc WHERE proname='get_game_partnerships';
--   --   p_game_id uuid
--
--   SELECT pg_get_function_result(oid)
--     FROM pg_proc WHERE proname='get_game_partnerships';
--   --   TABLE(...13 columns...)
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.get_game_partnerships(UUID);
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_game_partnerships(p_game_id UUID)
RETURNS TABLE (
    partnership_id              UUID,
    status                      TEXT,
    player_a_booking_id         UUID,
    player_a_user_id            UUID,
    player_a_name               TEXT,
    player_a_dupr_rating        NUMERIC,
    player_b_booking_id         UUID,
    player_b_user_id            UUID,
    player_b_name               TEXT,
    player_b_dupr_rating        NUMERIC,
    requested_partner_user_id   UUID,
    requested_partner_name      TEXT,
    created_at                  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
    v_caller_id     UUID := auth.uid();
    v_requires_dupr BOOL;
    v_game_exists   BOOL;
BEGIN
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    SELECT TRUE, COALESCE(g.requires_dupr, FALSE)
    INTO   v_game_exists, v_requires_dupr
    FROM   games g
    WHERE  g.id = p_game_id;

    -- Missing game: return an empty result set rather than raising. The
    -- client may call this against any game id; a "no rows" reply is the
    -- right shape both for genuine misses and for partnered games that
    -- simply have no pairings yet.
    IF v_game_exists IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        bp.id                                                       AS partnership_id,
        bp.status                                                   AS status,
        bp.player_a_booking_id                                      AS player_a_booking_id,
        ba.user_id                                                  AS player_a_user_id,
        pa.full_name                                                AS player_a_name,
        CASE WHEN v_requires_dupr THEN pa.dupr_rating ELSE NULL END AS player_a_dupr_rating,
        bp.player_b_booking_id                                      AS player_b_booking_id,
        bb.user_id                                                  AS player_b_user_id,
        pb.full_name                                                AS player_b_name,
        CASE WHEN v_requires_dupr THEN pb.dupr_rating ELSE NULL END AS player_b_dupr_rating,
        bp.requested_partner_user_id                                AS requested_partner_user_id,
        rp.full_name                                                AS requested_partner_name,
        bp.created_at                                               AS created_at
    FROM        booking_partnerships bp
    LEFT JOIN   bookings  ba ON ba.id = bp.player_a_booking_id
    LEFT JOIN   bookings  bb ON bb.id = bp.player_b_booking_id
    LEFT JOIN   profiles  pa ON pa.id = ba.user_id
    LEFT JOIN   profiles  pb ON pb.id = bb.user_id
    LEFT JOIN   profiles  rp ON rp.id = bp.requested_partner_user_id
    WHERE       bp.game_id = p_game_id
      AND       bp.status  IN ('pending', 'complete')
    ORDER BY    bp.created_at ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_game_partnerships(UUID) TO authenticated;
