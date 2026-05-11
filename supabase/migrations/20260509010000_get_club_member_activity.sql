-- Per-member activity aggregation for the Club Intelligence Members tab.
--
-- Returns one row per approved club member with current-period booking,
-- attendance, cancellation, and no-show counts plus a prior-period booking
-- count for "previously active → dormant" detection and the most recent
-- played-at timestamp.
--
-- This is intentionally lightweight — operator-facing aggregate intel only.
-- No per-game detail, no public exposure. Authorization is enforced via an
-- explicit caller-is-club-admin check (the RPC is SECURITY DEFINER so it
-- can join across bookings/games/profiles without depending on per-table
-- RLS for each member it returns).
--
-- Phase 2 Members intelligence:
--   - Most active (by attendance/booking count)
--   - Reliability watch (cancellations >= threshold)
--   - Previously active (prior period activity, current period zero, last
--     played stale)
--
-- Booking status is `booking_status` enum — every reference inside CTEs
-- casts via ::text (per CLAUDE.md hard constraint on enum comparison).
-- Game status is plain TEXT.
--
-- Idempotent: CREATE OR REPLACE FUNCTION.

CREATE OR REPLACE FUNCTION get_club_member_activity(
    p_club_id UUID,
    p_days INT DEFAULT 30
)
RETURNS TABLE(
    user_id UUID,
    full_name TEXT,
    avatar_color_key TEXT,
    booking_count INT,
    attendance_count INT,
    cancellation_count INT,
    no_show_count INT,
    last_played_at TIMESTAMPTZ,
    prior_booking_count INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller       UUID := auth.uid();
    v_is_admin     BOOLEAN;
    v_curr_start   TIMESTAMPTZ;
    v_prior_start  TIMESTAMPTZ;
    v_prior_end    TIMESTAMPTZ;
BEGIN
    IF v_caller IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    -- Authorization: caller must be an admin of this club, or its creator.
    SELECT EXISTS(
        SELECT 1
        FROM club_admins ca
        WHERE ca.club_id = p_club_id
          AND ca.user_id = v_caller
    ) INTO v_is_admin;

    IF NOT v_is_admin THEN
        IF NOT EXISTS(
            SELECT 1
            FROM clubs c
            WHERE c.id = p_club_id
              AND c.created_by = v_caller
        ) THEN
            RAISE EXCEPTION 'forbidden_admin_only';
        END IF;
    END IF;

    -- Clamp the period to a sane range. Prior window is 3x the current
    -- window, immediately preceding it — gives dormancy detection enough
    -- signal that "previously active" isn't noise from a single rare booking.
    p_days := GREATEST(LEAST(COALESCE(p_days, 30), 180), 7);
    v_curr_start  := now() - (p_days || ' days')::INTERVAL;
    v_prior_end   := v_curr_start;
    v_prior_start := v_curr_start - ((p_days * 3) || ' days')::INTERVAL;

    RETURN QUERY
    WITH approved_members AS (
        SELECT cm.user_id AS member_id
        FROM club_members cm
        WHERE cm.club_id = p_club_id
          AND cm.status = 'approved'
    ),
    -- Current-period booking + cancellation counts. Filtered to games that
    -- the club itself didn't cancel (those aren't player-driven cancels).
    curr_bookings AS (
        SELECT
            b.user_id,
            COUNT(*) FILTER (WHERE b.status::text = 'confirmed')::INT AS bcount,
            COUNT(*) FILTER (WHERE b.status::text = 'cancelled')::INT AS ccount
        FROM bookings b
        JOIN games g ON g.id = b.game_id
        WHERE g.club_id = p_club_id
          AND g.status != 'cancelled'
          AND g.date_time >= v_curr_start
        GROUP BY b.user_id
    ),
    -- Current-period attendance + no-show counts from check-in data.
    curr_attendance AS (
        SELECT
            ga.user_id,
            COUNT(*) FILTER (WHERE ga.attendance_status = 'attended')::INT AS acount,
            COUNT(*) FILTER (WHERE ga.attendance_status = 'no_show')::INT AS ncount
        FROM game_attendance ga
        JOIN games g ON g.id = ga.game_id
        WHERE g.club_id = p_club_id
          AND g.date_time >= v_curr_start
        GROUP BY ga.user_id
    ),
    -- Prior-period booking count: the (3 * p_days)-window immediately
    -- preceding the current period. Sample size for "was this member
    -- meaningfully active before they went quiet".
    prior_bookings AS (
        SELECT
            b.user_id,
            COUNT(*)::INT AS pcount
        FROM bookings b
        JOIN games g ON g.id = b.game_id
        WHERE g.club_id = p_club_id
          AND g.status != 'cancelled'
          AND b.status::text = 'confirmed'
          AND g.date_time >= v_prior_start
          AND g.date_time < v_prior_end
        GROUP BY b.user_id
    ),
    -- Most recent past confirmed game across all time. Used by the client
    -- to compute "last active N days ago" for the dormancy section.
    last_played AS (
        SELECT
            b.user_id,
            MAX(g.date_time) AS last_at
        FROM bookings b
        JOIN games g ON g.id = b.game_id
        WHERE g.club_id = p_club_id
          AND g.status != 'cancelled'
          AND b.status::text = 'confirmed'
          AND g.date_time < now()
        GROUP BY b.user_id
    )
    SELECT
        am.member_id,
        p.full_name,
        p.avatar_color_key,
        COALESCE(cb.bcount, 0),
        COALESCE(ca.acount, 0),
        COALESCE(cb.ccount, 0),
        COALESCE(ca.ncount, 0),
        lp.last_at,
        COALESCE(pb.pcount, 0)
    FROM approved_members am
    LEFT JOIN profiles p        ON p.id        = am.member_id
    LEFT JOIN curr_bookings cb  ON cb.user_id  = am.member_id
    LEFT JOIN curr_attendance ca ON ca.user_id = am.member_id
    LEFT JOIN prior_bookings pb ON pb.user_id  = am.member_id
    LEFT JOIN last_played lp    ON lp.user_id  = am.member_id;
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_member_activity(UUID, INT) TO authenticated;

COMMENT ON FUNCTION get_club_member_activity(UUID, INT) IS
'Per-member activity aggregation for the Club Intelligence Members tab.
Returns booking/attendance/cancellation/no-show counts in the current
period plus a prior-period booking count and most-recent last-played
timestamp. Authorization: caller must be in club_admins or be
clubs.created_by for the requested club.';
