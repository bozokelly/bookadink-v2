-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — P2.1 corrective: book_game() completes pending
-- partnerships when the intended partner books in.
--
-- Replaces the P2 partnered branch with logic that:
--   • Records `requested_partner_user_id` on the new pending partnership
--     when the caller specifies p_partner_user_id (intent is preserved).
--   • Allows the intended partner to later call book_game with p_partner_user_id
--     pointing back at the original requester — the function detects the
--     matching pending partnership and completes it (UPDATE sets player_b
--     and flips status to 'complete') instead of creating a second row.
--   • Rejects third-party hijack attempts (Player C trying to claim Player
--     A's pending partnership) by requiring requested_partner_user_id to
--     match the caller's user_id.
--   • Rejects double-reservation (Player C trying to also reserve Player B
--     when A already has a pending partnership intending B).
--   • Rejects pairing with a partner already in a complete partnership.
--
-- WHAT CHANGED VS. P2 (20260511030000):
--   • Removed the blanket "partner_already_in_game" rejection when
--     p_partner_user_id has any active booking.
--   • Added v_partner_booking_id, v_partner_complete_cnt, v_existing_pending_id,
--     v_completing_existing, v_intent_reserved_cnt locals.
--   • Added pre-INSERT lookups for the partner's active booking, any
--     complete partnership they sit in, and any matching pending row
--     to complete.
--   • Added pre-INSERT check for double-reservation against the new
--     unique index (`one_active_partnership_per_intended_partner`).
--   • After the bookings INSERT, branches between UPDATE (complete the
--     existing pending row) and INSERT (create a fresh pending row with
--     requested_partner_user_id populated).
--   • Moved the partner DUPR check above the partner-booking lookup so
--     DUPR-invalid requests fail before any partnership work.
--
-- WHAT DID NOT CHANGE:
--   • Function signature (still 11 params; signature byte-identical to P2).
--   • RETURNS TABLE shape.
--   • The FOR UPDATE games row lock + the capacity invariant (confirmed +
--     pending_payment ≤ max_spots).
--   • v_hold_mins still sources from get_waitlist_hold_minutes().
--   • Solo path is byte-identical: v_partnership_mode='solo' falls through
--     to the same INSERT and the same RETURN QUERY as the P2 body.
--   • The bookings INSERT column list and hold_expires_at expression.
--   • The 8 error codes from P2 remain. P2.1 adds one new code
--     (`partner_already_in_complete_partnership`) and reframes
--     `partner_intent_already_reserved` for the double-reservation case.
--
-- NEW ERROR CODES:
--   partner_already_in_complete_partnership
--     Partner already sits in a status='complete' partnership in this game.
--     Cannot pair via book_game; partnership must be unwound first.
--
--   partner_intent_already_reserved
--     Another active (pending|complete) partnership already names this
--     partner as its intended partner for this game. Caller must wait for
--     that partnership to be cancelled / completed by the original parties.
--
-- RETAINED ERROR CODES:
--   partner_required, partner_choice_conflict, partner_is_self,
--   partner_not_found, partner_dupr_required, partner_already_in_game,
--   partner_not_supported_for_solo_game, dupr_required, not_yet_published,
--   game_not_found.
--
-- VERIFICATION AFTER APPLY:
--   -- Signature unchanged (still 11 params)
--   SELECT count(*) FROM pg_proc WHERE proname='book_game';        -- 1
--   SELECT pronargs FROM pg_proc WHERE proname='book_game';        -- 11
--
--   -- Body references the new column
--   SELECT (regexp_matches(prosrc, 'requested_partner_user_id', 'g')) IS NOT NULL
--     FROM pg_proc WHERE proname='book_game';
--
-- ROLLBACK:
--   Re-apply the P2 body verbatim from
--   supabase/migrations/20260511030000_book_game_partnered_branch.sql.
--   That restores the strict "partner_already_in_game" rejection. Roll
--   back 20260511040000 only AFTER restoring the P2 function body, so the
--   live function doesn't reference a dropped column mid-rollback.
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
    v_max_spots             INT;
    v_requires_dupr         BOOL;
    v_publish_at            TIMESTAMPTZ;
    v_partnership_mode      TEXT;
    v_confirmed_cnt         INT;
    v_waitlist_pos          INT;
    v_status                TEXT;
    v_booking_id            UUID := gen_random_uuid();
    v_hold_mins             INT  := get_waitlist_hold_minutes();
    v_caller_dupr           TEXT;
    v_partner_dupr          TEXT;
    v_partner_booking_id    UUID;
    v_partner_complete_cnt  INT;
    v_existing_pending_id   UUID;
    v_completing_existing   BOOL := FALSE;
    v_intent_reserved_cnt   INT;
BEGIN
    -- Lock games row + pin partnership_mode in the same snapshot.
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

    IF v_publish_at IS NOT NULL AND v_publish_at > now() THEN
        RAISE EXCEPTION 'not_yet_published';
    END IF;

    -- ──────────────────────────────────────────────────────────────────────
    -- Partnership gating (P2.1 logic). Solo callers skip the entire block.
    -- ──────────────────────────────────────────────────────────────────────
    IF v_partnership_mode = 'partnered' THEN
        IF p_partner_user_id IS NULL AND p_allocate_partner = FALSE THEN
            RAISE EXCEPTION 'partner_required';
        END IF;

        IF p_partner_user_id IS NOT NULL AND p_allocate_partner = TRUE THEN
            RAISE EXCEPTION 'partner_choice_conflict';
        END IF;

        IF p_partner_user_id IS NOT NULL THEN
            IF p_partner_user_id = p_user_id THEN
                RAISE EXCEPTION 'partner_is_self';
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM profiles p WHERE p.id = p_partner_user_id
            ) THEN
                RAISE EXCEPTION 'partner_not_found';
            END IF;

            -- Partner DUPR gate (runs before any partnership lookups so a
            -- DUPR-invalid request fails before any further work).
            IF v_requires_dupr THEN
                SELECT trim(p.dupr_id)
                INTO   v_partner_dupr
                FROM   profiles p
                WHERE  p.id = p_partner_user_id;

                IF v_partner_dupr IS NULL OR length(v_partner_dupr) < 6 THEN
                    RAISE EXCEPTION 'partner_dupr_required';
                END IF;
            END IF;

            -- Partner's active booking in this game, if any.
            -- (LIMIT 1 is defensive: the bookings table's existing uniqueness
            -- prevents more than one non-cancelled booking per (user, game),
            -- but ORDER BY + LIMIT keeps the query deterministic in any
            -- adversarial edge case.)
            SELECT b.id
            INTO   v_partner_booking_id
            FROM   bookings b
            WHERE  b.game_id      = p_game_id
              AND  b.user_id      = p_partner_user_id
              AND  b.status::text IN ('confirmed', 'pending_payment', 'waitlisted')
            ORDER BY b.created_at
            LIMIT 1;

            IF v_partner_booking_id IS NOT NULL THEN
                -- Partner is already in the game.
                -- (1) Reject if they're already in a complete partnership.
                SELECT COUNT(*)
                INTO   v_partner_complete_cnt
                FROM   booking_partnerships bp
                WHERE  bp.game_id = p_game_id
                  AND  bp.status  = 'complete'
                  AND  (bp.player_a_booking_id = v_partner_booking_id
                        OR bp.player_b_booking_id = v_partner_booking_id);

                IF v_partner_complete_cnt > 0 THEN
                    RAISE EXCEPTION 'partner_already_in_complete_partnership';
                END IF;

                -- (2) Find a pending partnership the partner created that
                --     names the current caller as the intended partner.
                --     If found, we COMPLETE it after the bookings INSERT.
                SELECT bp.id
                INTO   v_existing_pending_id
                FROM   booking_partnerships bp
                WHERE  bp.game_id                   = p_game_id
                  AND  bp.player_a_booking_id       = v_partner_booking_id
                  AND  bp.player_b_booking_id       IS NULL
                  AND  bp.status                    = 'pending'
                  AND  bp.requested_partner_user_id = p_user_id
                LIMIT 1;

                IF v_existing_pending_id IS NULL THEN
                    -- Partner is in the game but has no pending partnership
                    -- intending the caller. They may be in the allocate pool
                    -- (intent = NULL) or intending someone else. Either way,
                    -- pairing via book_game is not possible — the P3 manual
                    -- pair RPC is the path.
                    RAISE EXCEPTION 'partner_already_in_game';
                END IF;

                v_completing_existing := TRUE;
            ELSE
                -- Partner has no booking yet. Make sure no other active
                -- partnership already names them as the intended partner.
                -- This is also enforced by
                -- one_active_partnership_per_intended_partner; the explicit
                -- check produces a clean error code instead of a unique
                -- violation.
                SELECT COUNT(*)
                INTO   v_intent_reserved_cnt
                FROM   booking_partnerships bp
                WHERE  bp.game_id                   = p_game_id
                  AND  bp.requested_partner_user_id = p_partner_user_id
                  AND  bp.status                    IN ('pending', 'complete');

                IF v_intent_reserved_cnt > 0 THEN
                    RAISE EXCEPTION 'partner_intent_already_reserved';
                END IF;
            END IF;
        END IF;
        -- p_allocate_partner = TRUE: no partner to validate; no intent column
        -- to set. The auto-match cron (P4, future) handles the pairing.
    ELSE
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

    -- Capacity check (unchanged).
    SELECT COUNT(*)
    INTO   v_confirmed_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
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

    -- Booking INSERT (unchanged shape).
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
    -- Partnership row write (P2.1: complete-or-create).
    -- Only fires when the requester actually holds a seat. Waitlisted
    -- bookings remain decoupled from partnership state in this slice.
    -- ──────────────────────────────────────────────────────────────────────
    IF v_partnership_mode = 'partnered'
       AND v_status IN ('confirmed', 'pending_payment') THEN

        IF v_completing_existing THEN
            -- The intended-partner side is calling in. Complete the partner's
            -- pending row instead of creating a new one. requested_partner_user_id
            -- is left as-is (it already equals p_user_id, which is correct for
            -- the audit trail of "who was originally intended").
            UPDATE booking_partnerships bp
            SET    player_b_booking_id = v_booking_id,
                   status              = 'complete',
                   updated_at          = now()
            WHERE  bp.id = v_existing_pending_id;
        ELSE
            -- First-mover path: insert a new pending partnership.
            --   Selected-partner case → requested_partner_user_id = p_partner_user_id
            --   Allocate-partner case → requested_partner_user_id = NULL
            INSERT INTO booking_partnerships (
                game_id,
                player_a_booking_id,
                player_b_booking_id,
                status,
                requested_by,
                requested_partner_user_id
            ) VALUES (
                p_game_id,
                v_booking_id,
                NULL,
                'pending',
                p_user_id,
                p_partner_user_id  -- NULL when allocate path
            );
        END IF;
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
