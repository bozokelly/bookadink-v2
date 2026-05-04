-- Trigger + cron unification: promote on ANY seat-freeing cancellation.
-- ─────────────────────────────────────────────────────────────────────────────
-- INCIDENT (2026-05-02):
--   With the duplicate-trigger bug fixed, single-promotion worked for
--   confirmed→cancelled. But "W1 declines their hold" / "W1 cancels via the
--   iOS Cancel button before the 2-min hold expires" left W2 stranded as
--   waitlisted forever. Net effect: a confirmed seat permanently disappeared
--   from circulation if W1 cancelled instead of paying.
--
-- ROOT CAUSE:
--   Two paths to 'cancelled' from a seat-holding state, only one was wired:
--
--     A. confirmed       → cancelled   (admin cancel, self-cancel of confirmed
--                                       booking)         ← trigger fires ✓
--     B. pending_payment → cancelled   (user declines hold via
--                                       cancel_booking_with_credit)  ← MISSED
--     C. pending_payment → cancelled   (cron forfeit step)           ← cron
--                                       handled inline via its own promotion
--                                       logic
--
--   Path B was unhandled. Path C had its own duplicate logic which created a
--   re-introduction risk for the 5/4 bug if the trigger ever expanded to
--   cover B (the cron's UPDATE would also fire the trigger → double promotion).
--
-- WHAT THIS MIGRATION DOES:
--   1. Expands `promote_top_waitlisted` to fire on `pending_payment → cancelled`
--      in addition to `confirmed → cancelled`. Both transitions free a held
--      seat for waitlist promotion.
--   2. Adds a defence-in-depth capacity check inside the trigger
--      (`confirmed + pending_payment <= max_spots`) using a `FOR UPDATE` lock
--      on the games row, mirroring book_game / owner_create_booking /
--      promote_waitlist_player. This protects against pre-existing
--      over-booked rows and concurrent races.
--   3. Removes the inline promotion logic from
--      `revert_expired_holds_and_repromote`. The cron now does:
--        - find expired pending_payment holds
--        - UPDATE status='cancelled' (which fires the trigger → promotion +
--          promotion push happen via the trigger path)
--        - send the `hold_expired_forfeit` push to the cancelled user
--      One canonical promotion path = no risk of double-promotion.
--
-- BACKWARDS-COMPAT:
--   No change to public RPC signatures. No iOS / Android changes required.
--   Existing callers that cancel via cancel_booking_with_credit, the iOS
--   Cancel button, or the cron all benefit automatically.
--
-- VERIFY AFTER RUN:
--   1. Cancel a 'pending_payment' booking from the iOS app (W1 declining a
--      hold). The next waitlister should immediately move to confirmed (free
--      game) or pending_payment (paid game) and receive the promotion push.
--   2. Let a 'pending_payment' hold expire by waiting past hold_expires_at.
--      Within ~1 min the cron should:
--        - cancel the expired hold
--        - the trigger then promotes the next waitlister
--        - the cron sends the forfeit push to the cancelled user
--      Both pushes arrive; no row is over-promoted.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE on both functions.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION promote_top_waitlisted()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game           games%ROWTYPE;
  v_active_cnt     INT;
  v_booking_id     UUID;
  v_promoted_user  UUID;
  v_is_paid        BOOLEAN;
  v_hold_minutes   CONSTANT INT  := 2;   -- TEMP: testing waitlist promotion. Revert to 30 before ship.
  v_supabase_url   CONSTANT TEXT := 'https://vdhwptzngjguluxcbzsi.supabase.co';
  v_anon_key       CONSTANT TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZkaHdwdHpuZ2pndWx1eGNienNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MDUwMDgsImV4cCI6MjA4NjQ4MTAwOH0.KhCdfv8EDGApovbdsEiEIE0vBJojy2tfEJzpgvcBuXk';
BEGIN
  -- Fire on any seat-freeing cancellation. Both confirmed and pending_payment
  -- physically hold a seat, so cancelling either one frees capacity for the
  -- next waitlister.
  IF NEW.status IS DISTINCT FROM 'cancelled' THEN
    RETURN NEW;
  END IF;
  IF OLD.status::text NOT IN ('confirmed', 'pending_payment') THEN
    RETURN NEW;
  END IF;

  -- Lock the game row. Same lock book_game(), owner_create_booking(), and
  -- promote_waitlist_player() take. Serialises promotion against concurrent
  -- bookings so the active-seat count below is consistent.
  SELECT * INTO v_game FROM games WHERE id = NEW.game_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- Defence-in-depth capacity check. Counts confirmed + pending_payment
  -- (canonical "active seats" invariant). Should never trip in steady state
  -- because OLD.status was a held seat that just freed, but protects against:
  --   - pre-existing over-booked rows from old data
  --   - concurrent paths that might race
  --   - future changes that re-introduce a missed cancellation handler
  SELECT COUNT(*)
  INTO   v_active_cnt
  FROM   bookings b
  WHERE  b.game_id    = NEW.game_id
    AND  b.status::text IN ('confirmed', 'pending_payment');

  IF v_game.max_spots IS NOT NULL AND v_active_cnt >= v_game.max_spots THEN
    RETURN NEW;
  END IF;

  v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

  -- Pick top waitlister. FOR UPDATE SKIP LOCKED prevents two concurrent
  -- trigger fires from grabbing the same waitlist row.
  SELECT b.id INTO v_booking_id
  FROM   bookings b
  WHERE  b.game_id    = NEW.game_id
    AND  b.status::text = 'waitlisted'
  ORDER  BY b.waitlist_position ASC NULLS LAST,
            b.created_at        ASC
  LIMIT  1
  FOR UPDATE SKIP LOCKED;

  IF v_booking_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_is_paid THEN
    UPDATE bookings b
    SET    status            = 'pending_payment',
           waitlist_position = NULL,
           hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
           promoted_at       = now()
    WHERE  b.id = v_booking_id
    RETURNING b.user_id INTO v_promoted_user;

    IF v_promoted_user IS NOT NULL THEN
      PERFORM net.http_post(
        url     := v_supabase_url || '/functions/v1/promote-top-waitlisted-push',
        headers := jsonb_build_object(
                     'Content-Type',  'application/json',
                     'Authorization', 'Bearer ' || v_anon_key
                   ),
        body    := jsonb_build_object(
                     'booking_id', v_booking_id::text,
                     'user_id',    v_promoted_user::text,
                     'game_id',    NEW.game_id::text,
                     'type',       'waitlist_promoted_pending_payment'
                   )
      );
    END IF;
  ELSE
    UPDATE bookings b
    SET    status            = 'confirmed',
           waitlist_position = NULL,
           hold_expires_at   = NULL,
           promoted_at       = now()
    WHERE  b.id = v_booking_id
    RETURNING b.user_id INTO v_promoted_user;

    IF v_promoted_user IS NOT NULL THEN
      PERFORM net.http_post(
        url     := v_supabase_url || '/functions/v1/promote-top-waitlisted-push',
        headers := jsonb_build_object(
                     'Content-Type',  'application/json',
                     'Authorization', 'Bearer ' || v_anon_key
                   ),
        body    := jsonb_build_object(
                     'booking_id', v_booking_id::text,
                     'user_id',    v_promoted_user::text,
                     'game_id',    NEW.game_id::text,
                     'type',       'waitlist_promoted'
                   )
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


-- Cron: forfeit expired holds. Promotion is now the trigger's job exclusively.
-- The UPDATE below sets pending_payment → cancelled, which fires
-- promote_top_waitlisted() in the same transaction → next waitlister promoted
-- with the appropriate paid/free path and the promotion push is sent. The
-- cron's only remaining responsibility is sending the forfeit push to the
-- user who lost their hold.
CREATE OR REPLACE FUNCTION revert_expired_holds_and_repromote()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r                RECORD;
    v_supabase_url   CONSTANT TEXT := 'https://vdhwptzngjguluxcbzsi.supabase.co';
    v_anon_key       CONSTANT TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZkaHdwdHpuZ2pndWx1eGNienNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MDUwMDgsImV4cCI6MjA4NjQ4MTAwOH0.KhCdfv8EDGApovbdsEiEIE0vBJojy2tfEJzpgvcBuXk';
BEGIN
    FOR r IN
        SELECT b.id AS booking_id, b.game_id, b.user_id
        FROM   bookings b
        WHERE  b.status          = 'pending_payment'
          AND  b.hold_expires_at IS NOT NULL
          AND  b.hold_expires_at  < now()
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Forfeit: cancel the expired hold. The trigger
        -- promote_top_waitlisted fires on this UPDATE
        -- (pending_payment → cancelled) and handles the next-waitlister
        -- promotion + push atomically in the same transaction.
        UPDATE bookings
        SET    status            = 'cancelled',
               hold_expires_at   = NULL,
               promoted_at       = NULL,
               waitlist_position = NULL
        WHERE  id = r.booking_id;

        -- Send the forfeit push to the user who lost their hold. The
        -- promotion push (for the newly-promoted next waitlister) is sent
        -- by the trigger above.
        IF r.user_id IS NOT NULL THEN
            PERFORM net.http_post(
                url     := v_supabase_url || '/functions/v1/promote-top-waitlisted-push',
                headers := jsonb_build_object(
                               'Content-Type',  'application/json',
                               'Authorization', 'Bearer ' || v_anon_key
                           ),
                body    := jsonb_build_object(
                               'booking_id', r.booking_id::text,
                               'user_id',    r.user_id::text,
                               'game_id',    r.game_id::text,
                               'type',       'hold_expired_forfeit'
                           )
            );
        END IF;
    END LOOP;
END;
$$;
