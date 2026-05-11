-- ─────────────────────────────────────────────────────────────────────────────
-- P4 corrective: also fire the matcher when a new pending allocate-me
-- partnership row is inserted.
--
-- WHY:
--   The original P4 trigger (`trg_match_after_booking_confirmed`) fires on
--   `bookings` after a row lands in 'confirmed'. That covers the paid path
--   (the partnership row already exists when the pending_payment → confirmed
--   transition happens), but NOT the free path: inside `book_game` the
--   booking is inserted BEFORE the partnership row, so when the bookings
--   trigger fires the matcher cannot yet see the new allocate-me partnership
--   — only earlier ones. The matcher then finds at most 1 eligible row and
--   skips the pair.
--
--   The fix is symmetric: also fire the matcher AFTER a new partnership row
--   is inserted as a pending allocate-me intent, but only if the underlying
--   booking is already 'confirmed' (so the paid-path is left to the existing
--   bookings trigger to drive when the status transition happens).
--
-- SCOPE:
--   • `match_after_partnership_inserted_fn()` SECURITY DEFINER trigger
--     function.
--   • `trg_match_after_partnership_inserted` AFTER INSERT ON
--     booking_partnerships FOR EACH ROW WHEN (the row is a pending
--     allocate-me intent) — calls the matcher with the row's game_id.
--   • No change to `match_pending_partnerships` itself, no change to the
--     existing `trg_match_after_booking_confirmed`.
--
-- RECURSION:
--   The matcher writes only to booking_partnerships:
--     - UPDATE to 'complete' on row A
--     - UPDATE to 'cancelled' on row B
--   This trigger fires on INSERT only, so UPDATEs do not re-fire it.
--   The function is idempotent (a second invocation on the same state finds
--   no eligible rows and exits cleanly).
--
-- VERIFICATION AFTER APPLY:
--   SELECT proname FROM pg_proc
--    WHERE proname = 'match_after_partnership_inserted_fn';     -- 1 row
--   SELECT tgname, tgenabled FROM pg_trigger
--    WHERE tgrelid = 'public.booking_partnerships'::regclass
--      AND tgname  = 'trg_match_after_partnership_inserted';    -- 1 row
--
-- ROLLBACK:
--   BEGIN;
--     DROP TRIGGER IF EXISTS trg_match_after_partnership_inserted
--       ON public.booking_partnerships;
--     DROP FUNCTION IF EXISTS public.match_after_partnership_inserted_fn();
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.match_after_partnership_inserted_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_partnership_mode TEXT;
    v_booking_status   TEXT;
BEGIN
    -- The WHEN clause already filtered status/player_b/requested_partner.
    -- Verify the game is partnered (cheap guard — the row should not exist
    -- on a solo game, but cost of one read is trivial).
    SELECT COALESCE(g.partnership_mode, 'solo')
    INTO   v_partnership_mode
    FROM   games g
    WHERE  g.id = NEW.game_id;

    IF v_partnership_mode <> 'partnered' THEN
        RETURN NEW;
    END IF;

    -- Only run the matcher if the underlying player_a booking is already
    -- confirmed. For the paid path (pending_payment) the bookings
    -- status-transition trigger will fire later and drive the matcher
    -- — we don't want to do anything here.
    SELECT b.status::text
    INTO   v_booking_status
    FROM   bookings b
    WHERE  b.id = NEW.player_a_booking_id;

    IF v_booking_status <> 'confirmed' THEN
        RETURN NEW;
    END IF;

    PERFORM public.match_pending_partnerships(NEW.game_id);
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_match_after_partnership_inserted
    ON public.booking_partnerships;

CREATE TRIGGER trg_match_after_partnership_inserted
AFTER INSERT ON public.booking_partnerships
FOR EACH ROW
WHEN (
    NEW.status = 'pending'
    AND NEW.player_b_booking_id IS NULL
    AND NEW.requested_partner_user_id IS NULL
)
EXECUTE FUNCTION public.match_after_partnership_inserted_fn();
