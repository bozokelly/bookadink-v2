-- Hold-expiry policy change: forfeit-on-expiry (replaces move-to-bottom)
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   Previous revert_expired_holds_and_repromote() moved the expired holder to
--   the bottom of the waitlist (status='waitlisted', position=MAX+1). When the
--   expired holder was the ONLY person on the waitlist, the very next step in
--   the same loop iteration re-promoted them (they were now at position 1 of
--   1) with a fresh 30-min hold — an infinite loop of "Action required: pay"
--   pushes every 30 minutes.
--
--   The CLAUDE.md "missed-hold rule" of "move to bottom" was correct in the
--   multi-waitlister case but broken in the single-waitlister case.
--
-- POLICY CHANGE (Option A — forfeit):
--   Expired hold → status='cancelled'. The user forfeits the spot. They are
--   not re-promoted. The next eligible waitlister is promoted normally.
--   If no other waitlister exists, the spot stays open and the next player
--   to book via the normal flow takes it.
--
--   The forfeiting user receives a one-shot "Your hold expired" push pointing
--   them back at the game so they can rejoin if they want. Sent via the
--   existing promote-top-waitlisted-push Edge Function with a new payload type
--   `hold_expired_forfeit`.
--
-- WHY CANCEL (NOT DELETE):
--   Cancelled rows are auditable. The trg_compact_waitlist_on_leave trigger
--   only fires on `OLD.status = 'waitlisted' AND NEW.status != 'waitlisted'`,
--   so cancelling a pending_payment booking does NOT trigger compaction —
--   waitlist_position integers for the rest of the waitlist remain intact.
--
-- DOWNSTREAM TRIGGER INTERACTION:
--   The promote_top_waitlisted() trigger fires only on
--   `OLD.status = 'confirmed' AND NEW.status = 'cancelled'`. Cancelling a
--   pending_payment booking does NOT trigger it — re-promotion happens here
--   in the cron function inline, exactly as before.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION revert_expired_holds_and_repromote()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r                RECORD;
    v_game           games%ROWTYPE;
    v_is_paid        BOOLEAN;
    v_active_cnt     INT;
    v_next_id        UUID;
    v_next_user      UUID;
    v_hold_minutes   CONSTANT INT  := 30;
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
        -- Forfeit: cancel the expired hold. The user does NOT return to the
        -- waitlist. Spot is freed for the next waitlister or anyone via book_game.
        UPDATE bookings
        SET
            status            = 'cancelled',
            hold_expires_at   = NULL,
            promoted_at       = NULL,
            waitlist_position = NULL
        WHERE id = r.booking_id;

        -- One-shot forfeit push to the user (best-effort; failure does not
        -- block the loop). The push body invites them to rejoin the game.
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

        -- Re-promotion: pick the next waitlister if a spot is open.
        SELECT * INTO v_game FROM games WHERE id = r.game_id;
        IF NOT FOUND THEN CONTINUE; END IF;

        v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

        -- Count active seats AFTER the forfeit cancellation.
        SELECT COUNT(*) INTO v_active_cnt
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status::text IN ('confirmed', 'pending_payment');

        IF v_active_cnt >= v_game.max_spots THEN CONTINUE; END IF;

        -- Pick the next waitlister. The forfeiting user is now `cancelled`,
        -- not `waitlisted`, so they cannot be selected here — no infinite loop.
        SELECT id, user_id
        INTO   v_next_id, v_next_user
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'waitlisted'
        ORDER  BY waitlist_position ASC NULLS LAST, created_at ASC
        LIMIT  1
        FOR UPDATE SKIP LOCKED;

        IF v_next_id IS NULL THEN CONTINUE; END IF;

        IF v_is_paid THEN
            UPDATE bookings
            SET
                status            = 'pending_payment',
                waitlist_position = NULL,
                hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
                promoted_at       = now()
            WHERE id = v_next_id;

            IF v_next_user IS NOT NULL THEN
                PERFORM net.http_post(
                    url     := v_supabase_url || '/functions/v1/promote-top-waitlisted-push',
                    headers := jsonb_build_object(
                                   'Content-Type',  'application/json',
                                   'Authorization', 'Bearer ' || v_anon_key
                               ),
                    body    := jsonb_build_object(
                                   'booking_id', v_next_id::text,
                                   'user_id',    v_next_user::text,
                                   'game_id',    r.game_id::text,
                                   'type',       'waitlist_promoted_pending_payment'
                               )
                );
            END IF;

        ELSE
            UPDATE bookings
            SET
                status            = 'confirmed',
                waitlist_position = NULL,
                hold_expires_at   = NULL
            WHERE id = v_next_id;

            IF v_next_user IS NOT NULL THEN
                PERFORM net.http_post(
                    url     := v_supabase_url || '/functions/v1/promote-top-waitlisted-push',
                    headers := jsonb_build_object(
                                   'Content-Type',  'application/json',
                                   'Authorization', 'Bearer ' || v_anon_key
                               ),
                    body    := jsonb_build_object(
                                   'booking_id', v_next_id::text,
                                   'user_id',    v_next_user::text,
                                   'game_id',    r.game_id::text,
                                   'type',       'waitlist_promoted'
                               )
                );
            END IF;
        END IF;

    END LOOP;
END;
$$;
