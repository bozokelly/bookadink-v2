-- Waitlist push: hard-code Supabase URL + anon key, route to promote-top-waitlisted-push
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   1. promote_top_waitlisted() (trigger) and revert_expired_holds_and_repromote()
--      (cron) read app.supabase_url / app.supabase_anon_key via current_setting().
--      Supabase hosted blocks `ALTER DATABASE postgres SET app.*` for non-superusers,
--      so those settings remain NULL and the IF v_supabase_url IS NOT NULL guard
--      silently skipped every push.
--
--   2. Original migration 20260407 routed pushes to /functions/v1/notify, which
--      runs getCallerID() and returns 401 "Authentication required" when called
--      with the anon key Bearer (no `sub` claim). The purpose-built endpoint is
--      promote-top-waitlisted-push, which is deployed --no-verify-jwt and has
--      no auth gate, and which handles the in-app notification copy + APNs push
--      + stale-token cleanup + waitlist_push preference check internally.
--
-- DESIGN:
--   Replace current_setting() with literal constants and POST to
--   /functions/v1/promote-top-waitlisted-push with its expected payload shape:
--     { booking_id, user_id, game_id, type }
--   where type is:
--     "waitlist_promoted_pending_payment"  → paid game, hold timer, "Action required"
--     "waitlist_promoted"                  → free game promotion, "You're off the waitlist!"
--
--   The anon key is already public (embedded in the iOS app binary), so storing
--   it in the function body is no incremental risk. RLS — not the anon key — is
--   what protects data. The receiving function uses its own SUPABASE_SERVICE_ROLE_KEY
--   for the DB operations it needs.
--
-- ROLLOUT:
--   Pure DDL. Idempotent (CREATE OR REPLACE).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION promote_top_waitlisted()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game           games%ROWTYPE;
  v_booking_id     UUID;
  v_promoted_user  UUID;
  v_is_paid        BOOLEAN;
  v_hold_minutes   CONSTANT INT  := 30;
  v_supabase_url   CONSTANT TEXT := 'https://vdhwptzngjguluxcbzsi.supabase.co';
  v_anon_key       CONSTANT TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZkaHdwdHpuZ2pndWx1eGNienNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MDUwMDgsImV4cCI6MjA4NjQ4MTAwOH0.KhCdfv8EDGApovbdsEiEIE0vBJojy2tfEJzpgvcBuXk';
BEGIN
  IF OLD.status IS DISTINCT FROM 'confirmed' OR NEW.status IS DISTINCT FROM 'cancelled' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_game FROM games WHERE id = NEW.game_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

  SELECT id INTO v_booking_id
  FROM   bookings
  WHERE  game_id = NEW.game_id
    AND  status  = 'waitlisted'
  ORDER  BY waitlist_position ASC NULLS LAST,
            created_at        ASC
  LIMIT  1
  FOR UPDATE SKIP LOCKED;

  IF v_booking_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_is_paid THEN
    UPDATE bookings
    SET
      status            = 'pending_payment',
      waitlist_position = NULL,
      hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
      promoted_at       = now()
    WHERE id = v_booking_id
    RETURNING user_id INTO v_promoted_user;

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
    UPDATE bookings
    SET
      status            = 'confirmed',
      waitlist_position = NULL
    WHERE id = v_booking_id
    RETURNING user_id INTO v_promoted_user;

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
        SELECT COALESCE(MAX(waitlist_position), 0)
        INTO   v_max_wl_pos
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'waitlisted';

        UPDATE bookings
        SET
            status            = 'waitlisted',
            hold_expires_at   = NULL,
            promoted_at       = NULL,
            waitlist_position = v_max_wl_pos + 1
        WHERE id = r.booking_id;

        SELECT * INTO v_game FROM games WHERE id = r.game_id;
        IF NOT FOUND THEN CONTINUE; END IF;

        v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

        SELECT COUNT(*)
        INTO   v_confirmed_cnt
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'confirmed';

        IF v_confirmed_cnt >= v_game.max_spots THEN CONTINUE; END IF;

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
