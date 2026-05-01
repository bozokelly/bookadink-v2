-- Waitlist hold expiry: server-authoritative cleanup + re-promotion
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   Previously, no server-side job reverted expired pending_payment holds.
--   A player whose 30-minute hold lapsed could still confirm their booking
--   because the DB still showed status='pending_payment'. The next waitlist
--   player was also blocked from being promoted until the iOS client refreshed.
--
-- MISSED-HOLD RULE (documented decision):
--   When a hold expires the player is moved to the BOTTOM of the waitlist.
--   They remain eligible for promotion on the next cancellation. They are not
--   removed from the waitlist. This is fair: they lose priority but are not
--   penalised by removal due to a possible connectivity issue.
--
-- CORRECTNESS LAYER:
--   This cron job is a correctness mechanism, not only a cleanup job.
--   The iOS/Android/web confirmPendingBooking endpoint also enforces
--   hold_expires_at > now() at the PATCH level, so even if the cron job
--   has not yet run, an expired hold cannot be confirmed by a client.
--
-- PREREQUISITES:
--   pg_cron extension: enabled (Supabase Dashboard → Database → Extensions).
--   pg_net extension: enabled (same location) — for push notifications.
--   app.supabase_url / app.supabase_anon_key DB settings configured
--     (same settings used by promote_top_waitlisted trigger).
--
-- SAFE TO RE-RUN:
--   CREATE OR REPLACE is idempotent.
--   cron.schedule() replaces any existing job with the same name.
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
    v_confirmed_cnt  INT;
    v_max_wl_pos     INT;
    v_next_id        UUID;
    v_next_user      UUID;
    v_hold_minutes   CONSTANT INT  := 30;  -- must match AppState.waitlistHoldMinutes
    v_supabase_url   TEXT;
    v_anon_key       TEXT;
BEGIN
    -- ── Step 1: Revert every expired hold back to waitlisted ───────────────────
    -- FOR UPDATE SKIP LOCKED: skip any row already locked by a concurrent
    -- cancellation trigger to avoid contention.
    FOR r IN
        SELECT b.id AS booking_id, b.game_id, b.user_id
        FROM   bookings b
        WHERE  b.status          = 'pending_payment'
          AND  b.hold_expires_at IS NOT NULL
          AND  b.hold_expires_at  < now()
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Compute the next available waitlist position for this game.
        SELECT COALESCE(MAX(waitlist_position), 0)
        INTO   v_max_wl_pos
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'waitlisted';

        -- Revert expired hold → bottom of waitlist.
        UPDATE bookings
        SET
            status            = 'waitlisted',
            hold_expires_at   = NULL,
            promoted_at       = NULL,
            waitlist_position = v_max_wl_pos + 1
        WHERE id = r.booking_id;

        -- ── Step 2: Re-promote the next eligible player if a spot is open ──────
        SELECT * INTO v_game FROM games WHERE id = r.game_id;
        IF NOT FOUND THEN CONTINUE; END IF;

        v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

        -- Recount confirmed bookings after the revert above.
        SELECT COUNT(*)
        INTO   v_confirmed_cnt
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'confirmed';

        -- Only promote if the game still has an open spot.
        IF v_confirmed_cnt >= v_game.max_spots THEN CONTINUE; END IF;

        -- Claim the next waitlisted player atomically.
        SELECT id, user_id
        INTO   v_next_id, v_next_user
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'waitlisted'
        ORDER  BY waitlist_position ASC NULLS LAST, created_at ASC
        LIMIT  1
        FOR UPDATE SKIP LOCKED;

        IF v_next_id IS NULL THEN CONTINUE; END IF;  -- no one else on waitlist

        IF v_is_paid THEN
            -- Paid game: promote to pending_payment with a fresh hold.
            UPDATE bookings
            SET
                status            = 'pending_payment',
                waitlist_position = NULL,
                hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
                promoted_at       = now()
            WHERE id = v_next_id;

            -- Send push notification (best-effort — same pattern as trigger).
            v_supabase_url := current_setting('app.supabase_url',     true);
            v_anon_key     := current_setting('app.supabase_anon_key', true);

            IF v_supabase_url IS NOT NULL
               AND v_anon_key IS NOT NULL
               AND v_next_user IS NOT NULL
            THEN
                PERFORM net.http_post(
                    url     := v_supabase_url || '/functions/v1/notify',
                    headers := jsonb_build_object(
                                   'Content-Type',  'application/json',
                                   'Authorization', 'Bearer ' || v_anon_key
                               ),
                    body    := jsonb_build_object(
                                   'user_id',      v_next_user::text,
                                   'title',        '⚠️ Action required: complete your booking',
                                   'body',         'A spot opened in ' || v_game.title
                                                   || '. Pay now to confirm — your hold expires in '
                                                   || v_hold_minutes || ' minutes.',
                                   'type',         'waitlist_promoted',
                                   'reference_id', r.game_id::text,
                                   'send_push',    true
                               )
                );
            END IF;

        ELSE
            -- Free game: promote directly to confirmed.
            UPDATE bookings
            SET
                status            = 'confirmed',
                waitlist_position = NULL,
                hold_expires_at   = NULL
            WHERE id = v_next_id;
        END IF;

    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION revert_expired_holds_and_repromote() TO postgres;

-- ── Schedule: run every minute ────────────────────────────────────────────────
-- The cron job is a correctness layer, not a timing-precision guarantee.
-- A hold is always rejected server-side by the hold_expires_at > now() filter
-- on confirmPendingBooking, even if the cron job has not yet run.
SELECT cron.schedule(
    'revert_expired_holds_and_repromote',   -- job name (idempotent)
    '* * * * *',                            -- every minute
    'SELECT revert_expired_holds_and_repromote()'
);
