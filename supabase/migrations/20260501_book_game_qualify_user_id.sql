-- book_game(): qualify every column reference to fix 42702 user_id ambiguity
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   RETURNS TABLE(... user_id UUID, game_id UUID, status TEXT, waitlist_position INT ...)
--   declares those names as OUT variables in the PL/pgSQL function scope. Inside
--   the function body, several queries referenced columns with the same names
--   without qualifying them with a table alias:
--
--     SELECT 1 FROM club_members
--     WHERE  club_id = v_club_id
--       AND  user_id = p_user_id          -- 42702: ambiguous
--       AND  status  = 'approved'
--
--     SELECT 1 FROM club_admins
--     WHERE  club_id = v_club_id
--       AND  user_id = p_user_id          -- 42702: ambiguous
--
--     SELECT COUNT(*) FROM bookings
--     WHERE  game_id = p_game_id          -- 42702: ambiguous
--       AND  status::text IN (...)
--
--     SELECT COALESCE(MAX(waitlist_position), 0) + 1
--     FROM   bookings
--     WHERE  game_id = p_game_id          -- 42702: ambiguous
--       AND  status::text = 'waitlisted'
--
--   PostgreSQL's plpgsql_check_asserts (and runtime planner since PG 11)
--   throws 42702 the first time execution reaches an ambiguous reference.
--   Booking on a public club happened to skip the members-only gate so the
--   bug was hidden until the first members-only booking attempt.
--
-- FIX:
--   Alias every table inside this function and qualify every column reference
--   with the alias. This is the canonical defence against PL/pgSQL OUT-name
--   shadowing — see PG docs §43.10.4 "Variable Substitution".
--
-- BEHAVIOURAL CHANGE: none. Pure refactor of identifiers; logic is unchanged.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION book_game(
    p_game_id               UUID,
    p_user_id               UUID,
    p_fee_paid              BOOLEAN  DEFAULT FALSE,
    p_stripe_pi_id          TEXT     DEFAULT NULL,
    p_payment_method        TEXT     DEFAULT NULL,
    p_platform_fee_cents    INT      DEFAULT NULL,
    p_club_payout_cents     INT      DEFAULT NULL,
    p_credits_applied_cents INT      DEFAULT NULL,
    p_hold_for_payment      BOOLEAN  DEFAULT FALSE
)
RETURNS TABLE(
    id                       UUID,
    game_id                  UUID,
    user_id                  UUID,
    status                   TEXT,
    waitlist_position        INT,
    created_at               TIMESTAMPTZ,
    fee_paid                 BOOLEAN,
    paid_at                  TIMESTAMPTZ,
    stripe_payment_intent_id TEXT,
    payment_method           TEXT,
    platform_fee_cents       INT,
    club_payout_cents        INT,
    credits_applied_cents    INT,
    hold_expires_at          TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_spots     INT;
    v_requires_dupr BOOL;
    v_members_only  BOOL;
    v_club_id       UUID;
    v_confirmed_cnt INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID := gen_random_uuid();
    v_hold_mins     CONSTANT INT := 30;
    v_caller_dupr   TEXT;
    v_is_member     BOOL;
BEGIN
    IF p_user_id <> auth.uid() THEN
        RAISE EXCEPTION 'unauthorized';
    END IF;

    -- Lock the game row + read parent club fields together.
    SELECT g.max_spots, COALESCE(g.requires_dupr, FALSE), c.members_only, g.club_id
    INTO   v_max_spots, v_requires_dupr, v_members_only, v_club_id
    FROM   games g
    JOIN   clubs c ON c.id = g.club_id
    WHERE  g.id = p_game_id
    FOR UPDATE OF g;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Members-only gate. All column references qualified.
    IF v_members_only THEN
        SELECT EXISTS (
            SELECT 1
            FROM   club_members cm
            WHERE  cm.club_id   = v_club_id
              AND  cm.user_id   = p_user_id
              AND  cm.status::text = 'approved'
        ) INTO v_is_member;

        IF NOT v_is_member THEN
            SELECT EXISTS (
                SELECT 1 FROM clubs c WHERE c.id = v_club_id AND c.created_by = p_user_id
            ) OR EXISTS (
                SELECT 1 FROM club_admins ca WHERE ca.club_id = v_club_id AND ca.user_id = p_user_id
            ) INTO v_is_member;
        END IF;

        IF NOT v_is_member THEN
            RAISE EXCEPTION 'membership_required';
        END IF;
    END IF;

    -- DUPR gate.
    IF v_requires_dupr THEN
        SELECT trim(p.dupr_id)
        INTO   v_caller_dupr
        FROM   profiles p
        WHERE  p.id = p_user_id;

        IF v_caller_dupr IS NULL
           OR length(v_caller_dupr) < 6
           OR v_caller_dupr !~ '^[A-Z0-9-]+$'
           OR v_caller_dupr !~ '[0-9]' THEN
            RAISE EXCEPTION 'dupr_required';
        END IF;
    END IF;

    -- Capacity count under the lock. confirmed + pending_payment both physically
    -- hold a seat — see CLAUDE.md "Booking creation — server-authoritative".
    SELECT COUNT(*) INTO v_confirmed_cnt
    FROM   bookings b
    WHERE  b.game_id = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_confirmed_cnt >= v_max_spots THEN
        SELECT COALESCE(MAX(b.waitlist_position), 0) + 1 INTO v_waitlist_pos
        FROM   bookings b
        WHERE  b.game_id = p_game_id
          AND  b.status::text = 'waitlisted';

        v_status := 'waitlisted';
    ELSE
        v_waitlist_pos := NULL;
        v_status := CASE WHEN p_hold_for_payment THEN 'pending_payment' ELSE 'confirmed' END;
    END IF;

    -- INSERT column names are unambiguous (the column list is the INSERT target,
    -- not a SELECT/WHERE clause where OUT-name shadowing can apply).
    INSERT INTO bookings (
        id,
        game_id,
        user_id,
        status,
        waitlist_position,
        fee_paid,
        stripe_payment_intent_id,
        payment_method,
        platform_fee_cents,
        club_payout_cents,
        credits_applied_cents,
        hold_expires_at
    ) VALUES (
        v_booking_id,
        p_game_id,
        p_user_id,
        v_status::booking_status,
        v_waitlist_pos,
        p_fee_paid,
        p_stripe_pi_id,
        p_payment_method,
        p_platform_fee_cents,
        p_club_payout_cents,
        p_credits_applied_cents,
        CASE WHEN v_status = 'pending_payment'
             THEN now() + (v_hold_mins || ' minutes')::INTERVAL
             ELSE NULL
        END
    );

    RETURN QUERY
    SELECT
        b.id,
        b.game_id,
        b.user_id,
        b.status::TEXT,
        b.waitlist_position,
        b.created_at,
        b.fee_paid,
        b.paid_at,
        b.stripe_payment_intent_id,
        b.payment_method,
        b.platform_fee_cents,
        b.club_payout_cents,
        b.credits_applied_cents,
        b.hold_expires_at
    FROM bookings b
    WHERE b.id = v_booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION book_game(UUID, UUID, BOOLEAN, TEXT, TEXT, INT, INT, INT, BOOLEAN) TO authenticated;
