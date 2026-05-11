-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — Phase 2 (P2): book_game() partnered branch.
--
-- Adds two new optional parameters to book_game() and a partnered branch that
-- inserts a `pending` row into booking_partnerships when the requester books
-- into a partnered game. Solo games are untouched — the new params are
-- ignored (when omitted) or rejected (when set on a solo game), so every
-- existing iOS / Android / web caller continues to work without change.
--
-- WHAT THIS MIGRATION DOES:
--   1. CREATE OR REPLACE book_game() with two trailing parameters:
--        p_partner_user_id  UUID    DEFAULT NULL
--        p_allocate_partner BOOLEAN DEFAULT FALSE
--      Trailing position + defaults means existing 9-param callers compile
--      and execute identically.
--   2. Reads `g.partnership_mode` in the same FOR UPDATE snapshot that
--      currently reads max_spots / requires_dupr / publish_at. No new locks.
--   3. If the game is partnered:
--        • Exactly one of (p_partner_user_id, p_allocate_partner) must be set.
--        • Self-pair is rejected.
--        • If a partner_user_id is given, the partner must (a) exist in
--          profiles, (b) hold no non-cancelled booking in this game, and
--          (c) satisfy the same DUPR gate the caller already has to pass.
--      If the game is solo, p_partner_user_id / p_allocate_partner being
--      set is rejected (defensive — surfaces a clean error if the wrong
--      RPC shape is sent against a solo game).
--   4. After the regular bookings INSERT, when the requester's status lands
--      in {confirmed, pending_payment}, inserts a `pending` row into
--      booking_partnerships with player_a = requester's new booking,
--      player_b = NULL, requested_by = requester. P3 (manual pair RPC)
--      and P4 (auto-match cron) handle the linking from there.
--
-- WHAT THIS MIGRATION DOES NOT DO:
--   • Does not auto-link two pending partnerships. Even when a requester
--     specifies p_partner_user_id = X, no UPDATE is issued against an
--     existing partnership row "intended" for X — the schema has no
--     `intended_partner_user_id` column and we don't want to silently
--     steal a partnership that another caller was holding. P3 is the
--     explicit linking RPC.
--   • Does not insert a partnership row when the requester is waitlisted.
--     Waitlisted seats are aspirational; coupling waitlist promotion to
--     partnership-completion belongs in a later slice that touches
--     promote_top_waitlisted.
--   • Does not change cancellation, hold expiry, credit return, or
--     waitlist promotion logic. The existing trigger / cron paths see
--     the new booking_partnerships rows as opaque data they neither
--     read nor modify.
--   • Does not introduce the auth.uid() / members-only gate from the
--     never-applied migration 20260501020000. The live function has
--     neither and this slice preserves that absence verbatim.
--
-- BODY PROVENANCE:
--   Live prosrc captured 2026-05-11 from production
--   (post-20260510010000_book_game_publish_gate). The solo path through
--   the function is byte-identical to the live body except:
--     • Two new variables in DECLARE (v_partnership_mode, v_partner_dupr,
--       v_partner_active_cnt).
--     • One extra column (`g.partnership_mode`) in the FOR UPDATE SELECT.
--     • Two new gated IF blocks before and after the bookings INSERT.
--   The capacity calculation, waitlist position math, status assignment,
--   bookings INSERT shape, hold_expires_at expression, and RETURN QUERY
--   shape are unchanged.
--
-- INVARIANTS PRESERVED (cross-checked against CLAUDE.md rules):
--   • Every column reference inside the function is alias-qualified
--     (g., b., bp., p.) — RETURNS TABLE OUT variables (id, game_id,
--     user_id, status, waitlist_position) cannot shadow.
--   • Single FOR UPDATE on the games row remains the only lock; counting
--     `confirmed + pending_payment` for capacity is unchanged.
--   • v_hold_mins still sources from get_waitlist_hold_minutes() — the
--     centralized helper from 20260504070000.
--   • Booking status values, enum cast (`v_status::booking_status`),
--     and the hold_expires_at expression are byte-identical.
--   • No new trigger, no new cron, no new function.
--
-- NEW ERROR CODES (raised as plain EXCEPTION messages, mapped on iOS later):
--   partner_required                 — partnered game, neither flag set
--   partner_choice_conflict          — partnered game, both flags set
--   partner_is_self                  — p_partner_user_id == p_user_id
--   partner_not_found                — p_partner_user_id has no profile
--   partner_already_in_game          — partner has a non-cancelled booking
--                                       (confirmed | pending_payment | waitlisted)
--   partner_dupr_required            — partnered DUPR game, partner has no DUPR ID
--   partner_not_supported_for_solo_game — partner flags set on a solo game
--
-- VERIFICATION AFTER APPLY:
--   -- A. Signature has the two new params.
--   SELECT pg_get_function_identity_arguments(oid)
--     FROM pg_proc WHERE proname='book_game';
--   --   p_game_id uuid, p_user_id uuid, p_fee_paid boolean, p_stripe_pi_id text,
--   --   p_payment_method text, p_platform_fee_cents integer, p_club_payout_cents integer,
--   --   p_credits_applied_cents integer, p_hold_for_payment boolean,
--   --   p_partner_user_id uuid, p_allocate_partner boolean
--
--   -- B. Return shape unchanged (still 14 columns).
--   SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname='book_game';
--
--   -- C. Body references the new column.
--   SELECT (regexp_matches(prosrc, 'partnership_mode', 'g')) IS NOT NULL
--     FROM pg_proc WHERE proname='book_game';
--
--   -- D. Solo behaviour — existing rows + book_game shape unchanged.
--   SELECT count(*) FROM games WHERE partnership_mode='solo';
--   --   == 109 (or whatever it was before; this slice doesn't touch row data)
--
-- ROLLBACK:
--   Re-apply the previous body. The simplest path is to reset the function
--   to the post-publish-gate version — copy the body verbatim from
--   supabase/migrations/20260510010000_book_game_publish_gate.sql and re-run
--   it. That restores the 9-param signature and removes the partnered
--   branch. The booking_partnerships table (P1) is unaffected by rollback.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.book_game(
    p_game_id                UUID,
    p_user_id                UUID,
    p_fee_paid               BOOLEAN DEFAULT FALSE,
    p_stripe_pi_id           TEXT    DEFAULT NULL,
    p_payment_method         TEXT    DEFAULT NULL,
    p_platform_fee_cents     INT     DEFAULT NULL,
    p_club_payout_cents      INT     DEFAULT NULL,
    p_credits_applied_cents  INT     DEFAULT NULL,
    p_hold_for_payment       BOOLEAN DEFAULT FALSE,
    p_partner_user_id        UUID    DEFAULT NULL,
    p_allocate_partner       BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
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
SET search_path TO 'public'
AS $function$
DECLARE
    v_max_spots          INT;
    v_requires_dupr      BOOL;
    v_publish_at         TIMESTAMPTZ;
    v_partnership_mode   TEXT;
    v_confirmed_cnt      INT;
    v_waitlist_pos       INT;
    v_status             TEXT;
    v_booking_id         UUID := gen_random_uuid();
    v_hold_mins          INT  := get_waitlist_hold_minutes();
    v_caller_dupr        TEXT;
    v_partner_dupr       TEXT;
    v_partner_active_cnt INT;
BEGIN
    -- Lock the games row to prevent concurrent over-booking and pin the
    -- partnership_mode value alongside the other gating snapshot.
    SELECT g.max_spots,
           COALESCE(g.requires_dupr, FALSE),
           g.publish_at,
           COALESCE(g.partnership_mode, 'solo')
    INTO   v_max_spots,
           v_requires_dupr,
           v_publish_at,
           v_partnership_mode
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Publish gate (unchanged from 20260510010000).
    IF v_publish_at IS NOT NULL AND v_publish_at > now() THEN
        RAISE EXCEPTION 'not_yet_published';
    END IF;

    -- ──────────────────────────────────────────────────────────────────────
    -- Partnership gating (P2 addition). Runs BEFORE the requester DUPR
    -- check + capacity check so an invalid partner request never produces
    -- a booking row that has to be rolled back. The solo branch (which
    -- includes the vast majority of live calls) is one IF-test long.
    -- ──────────────────────────────────────────────────────────────────────
    IF v_partnership_mode = 'partnered' THEN
        IF p_partner_user_id IS NULL AND p_allocate_partner = FALSE THEN
            RAISE EXCEPTION 'partner_required';
        END IF;

        IF p_partner_user_id IS NOT NULL AND p_allocate_partner = TRUE THEN
            RAISE EXCEPTION 'partner_choice_conflict';
        END IF;

        IF p_partner_user_id IS NOT NULL THEN
            -- Self-pair: reject. (Cheap check; runs before profile lookup so
            -- the misuse case never hits the profiles table.)
            IF p_partner_user_id = p_user_id THEN
                RAISE EXCEPTION 'partner_is_self';
            END IF;

            -- Partner must have a profile.
            IF NOT EXISTS (
                SELECT 1 FROM profiles p
                WHERE p.id = p_partner_user_id
            ) THEN
                RAISE EXCEPTION 'partner_not_found';
            END IF;

            -- Partner must not already hold a non-cancelled booking in
            -- this game. The strict reading of the spec ("Reject partner
            -- if already booked into same game") rules out auto-linking
            -- in P2 — P3's manual pair RPC is the path for linking two
            -- already-booked users.
            SELECT COUNT(*)
            INTO   v_partner_active_cnt
            FROM   bookings b
            WHERE  b.game_id = p_game_id
              AND  b.user_id = p_partner_user_id
              AND  b.status::text IN ('confirmed', 'pending_payment', 'waitlisted');

            IF v_partner_active_cnt > 0 THEN
                RAISE EXCEPTION 'partner_already_in_game';
            END IF;

            -- Partner DUPR gate — mirrors the caller DUPR gate exactly.
            IF v_requires_dupr THEN
                SELECT trim(p.dupr_id)
                INTO   v_partner_dupr
                FROM   profiles p
                WHERE  p.id = p_partner_user_id;

                IF v_partner_dupr IS NULL OR length(v_partner_dupr) < 6 THEN
                    RAISE EXCEPTION 'partner_dupr_required';
                END IF;
            END IF;
        END IF;
        -- p_allocate_partner = TRUE: nothing to validate; the auto-match
        -- cron (P4, future) will pair against another pending row later.
    ELSE
        -- Solo game: surface a clean error if the wrong RPC shape arrives.
        IF p_partner_user_id IS NOT NULL OR p_allocate_partner = TRUE THEN
            RAISE EXCEPTION 'partner_not_supported_for_solo_game';
        END IF;
    END IF;

    -- Caller's DUPR gate (unchanged).
    IF v_requires_dupr THEN
        SELECT trim(p.dupr_id)
        INTO   v_caller_dupr
        FROM   profiles p
        WHERE  p.id = p_user_id;

        IF v_caller_dupr IS NULL OR length(v_caller_dupr) < 6 THEN
            RAISE EXCEPTION 'dupr_required';
        END IF;
    END IF;

    -- Capacity: invariant is `confirmed + pending_payment <= max_spots`.
    SELECT COUNT(*)
    INTO   v_confirmed_cnt
    FROM   bookings b
    WHERE  b.game_id = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_confirmed_cnt >= v_max_spots THEN
        SELECT COALESCE(MAX(b.waitlist_position), 0) + 1
        INTO   v_waitlist_pos
        FROM   bookings b
        WHERE  b.game_id      = p_game_id
          AND  b.status::text = 'waitlisted';

        v_status := 'waitlisted';
    ELSE
        v_waitlist_pos := NULL;
        v_status := CASE WHEN p_hold_for_payment THEN 'pending_payment' ELSE 'confirmed' END;
    END IF;

    -- Booking INSERT (unchanged shape). The INSERT column list refers to the
    -- bookings table directly, so OUT-variable shadowing does not apply.
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

    -- ──────────────────────────────────────────────────────────────────────
    -- Partnership row creation (P2 addition).
    --
    -- Only fires when:
    --   • the game is partnered, AND
    --   • the requester's booking is actually holding a seat
    --     (confirmed or pending_payment).
    --
    -- Waitlisted bookings do NOT get a partnership row — the seat is not
    -- yet held, so coupling waitlist promotion to partnership completion
    -- belongs in a slice that also touches promote_top_waitlisted.
    -- ──────────────────────────────────────────────────────────────────────
    IF v_partnership_mode = 'partnered'
       AND v_status IN ('confirmed', 'pending_payment') THEN
        INSERT INTO booking_partnerships (
            game_id,
            player_a_booking_id,
            player_b_booking_id,
            status,
            requested_by
        ) VALUES (
            p_game_id,
            v_booking_id,
            NULL,
            'pending',
            p_user_id
        );
    END IF;

    -- Return shape (unchanged).
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
$function$;
