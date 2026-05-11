-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — Phase 4 (P4): auto-match allocate-me partnerships.
--
-- Two confirmed allocate-me bookings (p_allocate_partner=TRUE in book_game)
-- in the same partnered game are now paired automatically — admin no longer
-- needs to run pair_partnered_booking() for the common "anyone will do" case.
--
-- SCOPE:
--   • `match_pending_partnerships(p_game_id uuid default null)` SECURITY
--     DEFINER function: pairs eligible allocate-me rows oldest-first.
--     Returns one row per pair completed so callers (and tests) can see the
--     work that happened.
--   • `trg_match_after_booking_confirmed` AFTER INSERT OR UPDATE OF status
--     trigger on `bookings`: fires the matcher every time a booking lands
--     in `confirmed` status (free game allocate-me inserts directly into
--     confirmed; paid game allocate-me waits for the pending_payment ->
--     confirmed transition that follows Stripe completion).
--   • No pg_cron schedule — triggers cover every confirmed-transition path
--     reliably; per spec, cron is optional and not added here. A future
--     slice may add a "*/5 * * * *" safety-net schedule if monitoring
--     reveals stragglers; the function signature already accepts NULL to
--     run a sweep over every partnered game.
--
-- ELIGIBILITY (must all hold for a row to be matched):
--   • games.partnership_mode = 'partnered'
--   • booking_partnerships.status = 'pending'
--   • booking_partnerships.player_b_booking_id IS NULL
--   • booking_partnerships.requested_partner_user_id IS NULL
--     (this is what makes the row an "allocate me" intent — selected-partner
--     rows have a target user id and are intentionally NOT auto-matched)
--   • bookings.status = 'confirmed' (NOT pending_payment, NOT waitlisted,
--     NOT cancelled)
--   • If game.requires_dupr is true, the player must have a valid DUPR id
--     (>= 6 trimmed chars) — same length check as book_game()
--
-- ALGORITHM:
--   For each partnered game (FOR UPDATE on the games row to serialise with
--   pair_partnered_booking and any concurrent matcher invocation):
--     1. SELECT eligible rows ORDER BY created_at ASC, id ASC into an array
--     2. Walk the array in pairs (oldest+second-oldest, then next two, …)
--     3. For each pair (a, b):
--          - skip if both rows reference the same user (defensive — the
--            bookings (user_id, game_id) uniqueness already prevents this)
--          - UPDATE a: player_b_booking_id = b's player_a booking,
--                      requested_partner_user_id = b's user_id,
--                      status = 'complete', updated_at = now()
--          - UPDATE b: status = 'cancelled', updated_at = now()
--            (cancelled rows fall outside every partial unique index, so
--            the consumed row stops claiming any slot)
--          - emit RETURN row (game_id, partnership_id, a_user, b_user)
--
-- WHY UPDATE-then-CANCEL INSTEAD OF DELETE-and-INSERT:
--   • Preserves audit lineage — the original allocate-me row created by
--     the player keeps its `id` (and now records the actual partner via
--     `requested_partner_user_id`); the consumed row stays in the table
--     as `cancelled` so reporting / forensics can still find it.
--   • Avoids any momentary partial-unique-index conflict that a delete +
--     insert path could create on `one_active_partnership_player_a`.
--
-- INTERACTION WITH EXISTING TRIGGERS:
--   • trg_cancel_related_partnerships (P3) — fires on bookings → cancelled.
--     match_pending_partnerships does NOT touch bookings, so this trigger
--     is never re-fired by P4 work.
--   • trg_promote_top_waitlisted — also on bookings status changes, but
--     only on confirmed → cancelled. No overlap with P4's confirmed-arrival
--     condition.
--   • trg_compact_waitlist_on_leave — fires on waitlisted → other. No
--     overlap.
--   Multiple AFTER triggers on the same UPDATE event fire in alphabetical
--   order of trigger name; the matcher does not depend on ordering with
--   the existing triggers.
--
-- RECURSION:
--   match_pending_partnerships only writes to booking_partnerships. No
--   booking row is updated, so the trigger that called it cannot re-fire
--   transitively. The function is also idempotent (running it twice on
--   the same state finds no eligible rows and exits cleanly).
--
-- DOES NOT TOUCH:
--   • Solo games (the FOR loop filters on partnership_mode='partnered',
--     and the trigger function early-returns when the game is solo).
--   • Selected-partner pending rows (filter requires_partner_user_id IS NULL).
--   • Pending_payment / waitlisted bookings (filter b.status='confirmed').
--   • Cancellation / refund / credit flow.
--   • Waitlist promotion.
--   • Payment intent creation.
--   • RLS policies on booking_partnerships (still no policies; SECURITY
--     DEFINER trigger function bypasses RLS the same way every other
--     server-authoritative write does).
--
-- VERIFICATION AFTER APPLY:
--   SELECT proname FROM pg_proc
--    WHERE proname IN ('match_pending_partnerships',
--                      'match_after_booking_confirmed_fn');                    -- 2 rows
--   SELECT tgname, tgenabled FROM pg_trigger
--    WHERE tgrelid = 'public.bookings'::regclass
--      AND tgname  = 'trg_match_after_booking_confirmed';                       -- 1 row
--
-- ROLLBACK (in a single transaction):
--   BEGIN;
--     DROP TRIGGER IF EXISTS trg_match_after_booking_confirmed ON public.bookings;
--     DROP FUNCTION IF EXISTS public.match_after_booking_confirmed_fn();
--     DROP FUNCTION IF EXISTS public.match_pending_partnerships(UUID);
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.match_pending_partnerships(
    p_game_id UUID DEFAULT NULL
)
RETURNS TABLE (
    game_id              UUID,
    partnership_id       UUID,
    player_a_user_id     UUID,
    player_b_user_id     UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_game_id           UUID;
    v_requires_dupr     BOOL;
    v_eligible_ids      UUID[];
    v_idx               INT;
    v_a_id              UUID;
    v_b_id              UUID;
    v_a_user            UUID;
    v_b_user            UUID;
    v_b_booking         UUID;
BEGIN
    FOR v_game_id, v_requires_dupr IN
        SELECT g.id, COALESCE(g.requires_dupr, FALSE)
        FROM   games g
        WHERE  g.partnership_mode = 'partnered'
          AND  (p_game_id IS NULL OR g.id = p_game_id)
        FOR UPDATE OF g
    LOOP
        -- Collect every match-eligible row in this game, oldest first.
        -- Ties on created_at broken by id for determinism (rare; bookings
        -- inserted within the same microsecond).
        SELECT array_agg(bp.id ORDER BY bp.created_at ASC, bp.id ASC)
        INTO   v_eligible_ids
        FROM   booking_partnerships bp
        JOIN   bookings b ON b.id = bp.player_a_booking_id
        LEFT JOIN profiles p ON p.id = b.user_id
        WHERE  bp.game_id                   = v_game_id
          AND  bp.status                    = 'pending'
          AND  bp.player_b_booking_id       IS NULL
          AND  bp.requested_partner_user_id IS NULL
          AND  b.status::text               = 'confirmed'
          AND  (
                NOT v_requires_dupr
             OR (p.dupr_id IS NOT NULL AND length(trim(p.dupr_id)) >= 6)
          );

        IF v_eligible_ids IS NULL OR array_length(v_eligible_ids, 1) < 2 THEN
            CONTINUE;
        END IF;

        v_idx := 1;
        WHILE v_idx + 1 <= array_length(v_eligible_ids, 1) LOOP
            v_a_id := v_eligible_ids[v_idx];
            v_b_id := v_eligible_ids[v_idx + 1];

            -- Resolve A's user id (for emitted result + self-pair guard).
            SELECT b.user_id
            INTO   v_a_user
            FROM   booking_partnerships bp
            JOIN   bookings b ON b.id = bp.player_a_booking_id
            WHERE  bp.id = v_a_id;

            -- Resolve B's player_a booking + user (we'll attach the booking
            -- as A.player_b_booking_id and record the user as the actual
            -- "requested partner" so the audit trail is honest).
            SELECT bp.player_a_booking_id, b.user_id
            INTO   v_b_booking, v_b_user
            FROM   booking_partnerships bp
            JOIN   bookings b ON b.id = bp.player_a_booking_id
            WHERE  bp.id = v_b_id;

            -- Defensive self-pair guard. The bookings UNIQUE(user_id,
            -- game_id) constraint already prevents this, but the cost of
            -- the check is one comparison.
            IF v_a_user IS NULL OR v_b_user IS NULL OR v_a_user = v_b_user THEN
                v_idx := v_idx + 2;
                CONTINUE;
            END IF;

            -- Promote row A → complete, attaching B's booking + user.
            UPDATE booking_partnerships bp
            SET    player_b_booking_id       = v_b_booking,
                   requested_partner_user_id = v_b_user,
                   status                    = 'complete',
                   updated_at                = now()
            WHERE  bp.id = v_a_id;

            -- Cancel row B so it stops claiming the player_a slot.
            UPDATE booking_partnerships bp
            SET    status     = 'cancelled',
                   updated_at = now()
            WHERE  bp.id = v_b_id;

            game_id          := v_game_id;
            partnership_id   := v_a_id;
            player_a_user_id := v_a_user;
            player_b_user_id := v_b_user;
            RETURN NEXT;

            v_idx := v_idx + 2;
        END LOOP;
    END LOOP;

    RETURN;
END;
$function$;

-- Trigger function: fires the matcher when a booking lands in 'confirmed'.
-- Both INSERT (free-game allocate-me path through book_game) and UPDATE
-- (pending_payment -> confirmed via confirmPendingBooking) are covered.
CREATE OR REPLACE FUNCTION public.match_after_booking_confirmed_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_partnership_mode TEXT;
BEGIN
    -- Only act on transitions INTO confirmed. INSERT: every confirmed-on-
    -- insert booking. UPDATE: only when status changes from non-confirmed
    -- to confirmed.
    IF NEW.status::text = 'confirmed'
       AND (TG_OP = 'INSERT' OR OLD.status::text <> 'confirmed') THEN

        SELECT COALESCE(g.partnership_mode, 'solo')
        INTO   v_partnership_mode
        FROM   games g
        WHERE  g.id = NEW.game_id;

        IF v_partnership_mode = 'partnered' THEN
            PERFORM public.match_pending_partnerships(NEW.game_id);
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_match_after_booking_confirmed ON public.bookings;

CREATE TRIGGER trg_match_after_booking_confirmed
AFTER INSERT OR UPDATE OF status ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.match_after_booking_confirmed_fn();
