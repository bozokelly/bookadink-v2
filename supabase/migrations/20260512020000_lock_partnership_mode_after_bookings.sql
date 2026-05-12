-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered games — server-side safety guard for partnership_mode changes.
--
-- The iOS form (OwnerEditGameSheet) already disables the Registration Style
-- picker once any booking exists for the game. This migration backs that UI
-- guard with a DB-level guarantee so any caller (direct PostgREST PATCH,
-- SQL Editor edit, future Android/web client, server-side script) is held to
-- the same invariant:
--
--   Once a game has any booking row (regardless of status — including
--   cancelled), `games.partnership_mode` cannot change.
--
-- Why include cancelled bookings:
--   Cancelled bookings are historical evidence that players registered under
--   the original registration style. Re-classifying the game retroactively
--   would silently change the meaning of those past bookings and break
--   downstream analytics / audit assumptions.
--
-- Implementation:
--   BEFORE UPDATE OF partnership_mode trigger fires only when the value
--   actually changes (WHEN clause uses IS DISTINCT FROM). If at least one
--   bookings row exists for the game, the trigger raises
--   `partnership_mode_locked_after_bookings` and the UPDATE is aborted
--   atomically. Other columns can still be updated freely.
--
-- INVARIANTS PRESERVED:
--   • Existing create/update paths (createGame insert; updateGame PATCH from
--     the OwnerEditGameSheet form which keeps partnership_mode equal to the
--     stored value when bookings exist) are unaffected — the IS DISTINCT FROM
--     gate means the trigger is a no-op when the value isn't changing.
--   • Trigger does NOT touch any other column.
--   • RLS / SECURITY DEFINER mirrors existing partnership trigger
--     (`cancel_related_partnerships_fn`) — the function reads `bookings`
--     bypassing RLS so server-authoritative behaviour is uniform regardless
--     of the calling role.
--
-- VERIFICATION AFTER APPLY:
--   SELECT tgname, tgenabled, pg_get_triggerdef(oid)
--     FROM pg_trigger
--    WHERE tgrelid='public.games'::regclass
--      AND tgname='trg_lock_partnership_mode_after_bookings';
--
--   -- Functional smoke tests (transaction-rolled-back):
--   --   1. Pick a game with zero bookings, UPDATE partnership_mode = 'partnered'
--   --      → succeeds.
--   --   2. INSERT a bookings row (status='waitlisted' or 'confirmed' or
--   --      'cancelled'), then UPDATE games.partnership_mode = 'solo'
--   --      → fails with `partnership_mode_locked_after_bookings`.
--   --   3. UPDATE any non-partnership_mode column on the same game
--   --      (e.g. title, max_spots) → succeeds.
--   --   4. UPDATE partnership_mode to its own value (no-op change)
--   --      → succeeds (WHEN clause filters it out).
--
-- ROLLBACK:
--   BEGIN;
--     DROP TRIGGER IF EXISTS trg_lock_partnership_mode_after_bookings ON public.games;
--     DROP FUNCTION IF EXISTS public.lock_partnership_mode_after_bookings_fn();
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.lock_partnership_mode_after_bookings_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    -- Belt-and-braces: WHEN clause on the trigger already filters no-op
    -- updates, but re-check inside the function so the contract is obvious
    -- when reading pg_proc.
    IF OLD.partnership_mode IS DISTINCT FROM NEW.partnership_mode THEN
        IF EXISTS (SELECT 1 FROM bookings b WHERE b.game_id = NEW.id) THEN
            RAISE EXCEPTION 'partnership_mode_locked_after_bookings'
                USING HINT = 'Registration style cannot change once any booking exists for this game.';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_lock_partnership_mode_after_bookings ON public.games;

CREATE TRIGGER trg_lock_partnership_mode_after_bookings
BEFORE UPDATE OF partnership_mode ON public.games
FOR EACH ROW
WHEN (OLD.partnership_mode IS DISTINCT FROM NEW.partnership_mode)
EXECUTE FUNCTION public.lock_partnership_mode_after_bookings_fn();
