-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — Phase 3 (P3): cancellation sync trigger.
--
-- Hooks into every path that transitions a bookings row INTO `cancelled`
-- status (user cancel via cancel_booking_with_credit, hold expiry cron via
-- revert_expired_holds_and_repromote, admin cancellations, future paths)
-- and cancels any active partnership row referencing that booking.
--
-- WHY A TRIGGER vs. modifying each RPC:
--   • Five+ live paths transition bookings to cancelled today, and more will
--     land later. A single AFTER UPDATE trigger covers them all uniformly.
--   • Each existing RPC is server-authoritative and complex; changing five
--     functions in one slice would touch unrelated logic and risk drift.
--   • The trigger fires AFTER the bookings UPDATE commits within the same
--     transaction, so partnership cancellation is atomic with the underlying
--     cancellation. Refund / credit logic in cancel_booking_with_credit
--     continues to run unchanged.
--
-- WHAT IT DOES:
--   When a bookings row transitions FROM any non-cancelled status INTO
--   'cancelled', update every booking_partnerships row referencing that
--   booking (as player_a OR player_b) whose status is 'pending' or
--   'complete' to status='cancelled' (no other column touched).
--
--   Cancelled partnership rows are excluded from all three partial unique
--   indexes (`one_active_partnership_player_a`, `_player_b`,
--   `one_active_partnership_per_intended_partner`), so the booked-other-
--   side and the intended-partner slots become available for fresh pairing
--   immediately.
--
-- INVARIANTS PRESERVED:
--   • Existing cancellation paths (cancel_booking_with_credit cutoff path,
--     credit_on_replacement_confirmed deferred path,
--     revert_expired_holds_and_repromote cron) are byte-identical. The
--     trigger runs AFTER their bookings UPDATE and only writes to
--     booking_partnerships.
--   • Refund / credit math is untouched.
--   • Waitlist compaction trigger (`trg_compact_waitlist_on_leave`) and
--     promotion trigger (`trg_promote_top_waitlisted`) on the same UPDATE
--     OF status event continue to run; this new trigger does not affect
--     their ordering or behaviour (each is independent and idempotent).
--   • RLS-bypassing SECURITY DEFINER is required because partnership rows
--     belong to a table with RLS enabled + no policies.
--
-- VERIFICATION AFTER APPLY:
--   SELECT tgname, tgenabled, pg_get_triggerdef(oid)
--     FROM pg_trigger
--    WHERE tgrelid='public.bookings'::regclass
--      AND tgname='trg_cancel_related_partnerships';
--
--   -- Functional check (transaction-rolled-back):
--   --   1. INSERT a bookings row, INSERT a booking_partnerships row pointing at it.
--   --   2. UPDATE bookings.status -> 'cancelled'.
--   --   3. Expect booking_partnerships.status = 'cancelled'.
--
-- ROLLBACK:
--   BEGIN;
--     DROP TRIGGER IF EXISTS trg_cancel_related_partnerships ON public.bookings;
--     DROP FUNCTION IF EXISTS public.cancel_related_partnerships_fn();
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.cancel_related_partnerships_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    -- The WHEN clause on the trigger filters most no-ops, but a belt-and-braces
    -- check inside the function keeps the contract obvious to readers.
    IF NEW.status::text = 'cancelled' AND OLD.status::text <> 'cancelled' THEN
        UPDATE booking_partnerships bp
        SET    status     = 'cancelled',
               updated_at = now()
        WHERE  bp.status IN ('pending', 'complete')
          AND  (bp.player_a_booking_id = NEW.id
                OR bp.player_b_booking_id = NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cancel_related_partnerships ON public.bookings;

CREATE TRIGGER trg_cancel_related_partnerships
AFTER UPDATE OF status ON public.bookings
FOR EACH ROW
WHEN (OLD.status::text <> 'cancelled' AND NEW.status::text = 'cancelled')
EXECUTE FUNCTION public.cancel_related_partnerships_fn();
