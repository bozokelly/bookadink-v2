-- Waitlist position compaction
-- ──────────────────────────────────────────────────────────────────────────────
-- PROBLEM:
--   waitlist_position values become non-sequential (gaps) whenever a player
--   is removed from the middle of the queue — by cancellation, admin removal,
--   promotion, or hold expiry + re-promotion.  A user seeing "Position 5" when
--   only 2 players are ahead of them creates confusion and erodes trust.
--
-- SOLUTION:
--   recompact_waitlist_positions(p_game_id) reassigns sequential 1, 2, 3 …
--   positions to all remaining waitlisted bookings, preserving relative order.
--
--   compact_waitlist_after_leave() is an AFTER UPDATE trigger on bookings that
--   fires whenever a booking transitions FROM 'waitlisted' to any other status,
--   calling the compaction utility.
--
-- RACE SAFETY:
--   recompact_waitlist_positions acquires SELECT … FOR UPDATE on the games row
--   before rewriting positions.  book_game (20260426_book_game_rpc.sql) also
--   acquires this same lock before reading MAX(waitlist_position).  The shared
--   lock serialises the two operations so positions are always dense after
--   both transactions commit — no gap can appear between a compaction and a
--   concurrent new-booking insert.
--
-- TRIGGER COVERAGE (all paths that remove a booking from the waitlist):
--   • User self-cancels waitlisted booking       (waitlisted → cancelled)
--   • Admin cancels a waitlisted booking         (waitlisted → cancelled)
--   • promote_top_waitlisted trigger fires       (waitlisted → pending_payment / confirmed)
--   • promote_waitlist_player RPC is called      (waitlisted → pending_payment)
--   • revert_expired_holds_and_repromote cron    (waitlisted → pending_payment / confirmed
--                                                  on the re-promotion step)
--
-- ADMIN DRAG-REORDER SAFETY:
--   ownerUpdateBooking swaps waitlist_position integers while keeping both
--   bookings in status 'waitlisted'.  The trigger condition
--   OLD.status = 'waitlisted' AND NEW.status != 'waitlisted' evaluates FALSE,
--   so admin reorder is completely unaffected.
--
-- INFINITE-LOOP SAFETY:
--   The compaction UPDATE only changes waitlist_position, not status.
--   The trigger condition (status must change away from waitlisted) is FALSE
--   for position-only updates, so the trigger does not re-fire.
--
-- BACKFILL:
--   The final DO block compacts all games that currently have waitlisted
--   bookings with non-sequential positions.
--
-- SAFE TO RE-RUN:
--   CREATE OR REPLACE for functions; DROP TRIGGER IF EXISTS before recreation.
-- ──────────────────────────────────────────────────────────────────────────────


-- ── 1. Shared compaction utility ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recompact_waitlist_positions(p_game_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r   RECORD;
    pos INT := 1;
BEGIN
    -- Acquire the same games row lock used by book_game so that a concurrent
    -- MAX(waitlist_position) read never races with a position rewrite.
    PERFORM id FROM games WHERE id = p_game_id FOR UPDATE;

    -- Re-assign 1, 2, 3 … preserving relative order.
    -- FOR UPDATE on each row prevents another session from reading a stale
    -- position in the middle of the rewrite.
    FOR r IN
        SELECT id
        FROM   bookings
        WHERE  game_id      = p_game_id
          AND  status::text = 'waitlisted'
        ORDER  BY waitlist_position ASC NULLS LAST, created_at ASC
        FOR UPDATE
    LOOP
        UPDATE bookings
        SET    waitlist_position = pos
        WHERE  id = r.id;

        pos := pos + 1;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION recompact_waitlist_positions(UUID) TO authenticated;


-- ── 2. Trigger function ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION compact_waitlist_after_leave()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Fire only when a booking leaves the waitlist (status changes away from
    -- 'waitlisted').  Position-only updates (admin reorder) keep status as
    -- 'waitlisted', so this condition stays FALSE and reorder is preserved.
    IF OLD.status::text = 'waitlisted' AND NEW.status::text != 'waitlisted' THEN
        PERFORM recompact_waitlist_positions(NEW.game_id);
    END IF;
    RETURN NEW;
END;
$$;


-- ── 3. Install the trigger ────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_compact_waitlist_on_leave ON bookings;

CREATE TRIGGER trg_compact_waitlist_on_leave
    AFTER UPDATE ON bookings
    FOR EACH ROW
    EXECUTE FUNCTION compact_waitlist_after_leave();


-- ── 4. One-time backfill ──────────────────────────────────────────────────────
-- Compact every game that currently has waitlisted bookings so the trigger
-- starts from a clean baseline.

DO $$
DECLARE
    g RECORD;
BEGIN
    FOR g IN
        SELECT DISTINCT game_id
        FROM   bookings
        WHERE  status::text       = 'waitlisted'
          AND  waitlist_position  IS NOT NULL
    LOOP
        PERFORM recompact_waitlist_positions(g.game_id);
    END LOOP;
END;
$$;
