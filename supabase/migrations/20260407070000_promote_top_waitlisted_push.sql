-- promote_top_waitlisted() — Phase 3 + push notification
--
-- SUPERSEDES: 20260407_promote_top_waitlisted_phase3.sql
-- If you have already run the Phase 3 migration, run this one too.
-- If you have not yet run Phase 3, run this file instead of it.
--
-- WHAT THIS ADDS:
--   After promoting a waitlisted player to pending_payment on a paid game,
--   the trigger now fires an async HTTP POST to the `notify` Edge Function
--   via pg_net. This sends the player an APNs push notification AND inserts
--   a notification row, so they are alerted immediately without needing to
--   relaunch the app.
--
-- PREREQUISITES:
--   1. pg_net extension must be enabled (already enabled if the email trigger works).
--   2. Two database settings must be configured with your actual project values.
--      Run these ONCE in the SQL Editor (replace the placeholders):
--
--        ALTER DATABASE postgres SET app.supabase_url = 'https://<YOUR_PROJECT_REF>.supabase.co';
--        ALTER DATABASE postgres SET app.supabase_anon_key = '<YOUR_ANON_KEY>';
--
--      Find these in: Supabase Dashboard → Settings → API
--        - Project URL  → app.supabase_url
--        - anon / public key → app.supabase_anon_key
--
--   3. The `notify` Edge Function must be deployed:
--        supabase functions deploy notify --no-verify-jwt --project-ref <ref>
--
-- SAFE TO RE-RUN:
--   CREATE OR REPLACE FUNCTION is idempotent.
--   The current_setting(..., true) calls return NULL (not an error) if the
--   settings have not been configured yet — the push is silently skipped,
--   so the promotion itself still works.

-- 1. Ensure promoted_at column exists (idempotent, may have been added by Phase 3 migration).
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS promoted_at TIMESTAMPTZ NULL;

-- 2. Replace the trigger function with Phase 3 logic + push notification.
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
  v_hold_minutes   CONSTANT INT := 30;   -- must match AppState.waitlistHoldMinutes
  v_supabase_url   TEXT;
  v_anon_key       TEXT;
  v_notif_title    TEXT;
  v_notif_body     TEXT;
BEGIN
  -- Only fire when a CONFIRMED booking transitions to CANCELLED.
  IF OLD.status IS DISTINCT FROM 'confirmed' OR NEW.status IS DISTINCT FROM 'cancelled' THEN
    RETURN NEW;
  END IF;

  -- Look up the game.
  SELECT * INTO v_game
  FROM   games
  WHERE  id = NEW.game_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

  -- Claim the top waitlisted booking atomically.
  -- FOR UPDATE SKIP LOCKED prevents double-promotion under concurrent cancellations.
  SELECT id INTO v_booking_id
  FROM   bookings
  WHERE  game_id = NEW.game_id
    AND  status  = 'waitlisted'
  ORDER  BY waitlist_position ASC NULLS LAST,
            created_at        ASC
  LIMIT  1
  FOR UPDATE SKIP LOCKED;

  IF v_booking_id IS NULL THEN
    RETURN NEW;   -- nobody on the waitlist
  END IF;

  IF v_is_paid THEN
    -- Paid game: promote to pending_payment with a timed hold.
    -- RETURNING captures the promoted user's ID for the push notification.
    UPDATE bookings
    SET
      status            = 'pending_payment',
      waitlist_position = NULL,
      hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
      promoted_at       = now()
    WHERE id = v_booking_id
    RETURNING user_id INTO v_promoted_user;

    -- Fire push notification asynchronously via pg_net.
    -- current_setting(..., true) returns NULL (not an error) when the setting
    -- hasn't been configured — the PERFORM is then a no-op so promotion still works.
    v_supabase_url := current_setting('app.supabase_url',   true);
    v_anon_key     := current_setting('app.supabase_anon_key', true);

    IF v_supabase_url IS NOT NULL AND v_anon_key IS NOT NULL AND v_promoted_user IS NOT NULL THEN
      v_notif_title := '⚠️ Action required: complete your booking';
      v_notif_body  := 'A spot opened in ' || v_game.title
                       || '. Pay now to confirm your place — your hold expires in '
                       || v_hold_minutes || ' minutes.';

      PERFORM net.http_post(
        url     := v_supabase_url || '/functions/v1/notify',
        headers := jsonb_build_object(
                     'Content-Type',  'application/json',
                     'Authorization', 'Bearer ' || v_anon_key
                   ),
        body    := jsonb_build_object(
                     'user_id',      v_promoted_user::text,
                     'title',        v_notif_title,
                     'body',         v_notif_body,
                     'type',         'waitlist_promoted',
                     'reference_id', NEW.game_id::text,
                     'send_push',    true
                   )
      );
    END IF;

  ELSE
    -- Free game: promote directly to confirmed (pre-Phase-3 behaviour, unchanged).
    UPDATE bookings
    SET
      status            = 'confirmed',
      waitlist_position = NULL
    WHERE id = v_booking_id;

  END IF;

  RETURN NEW;
END;
$$;
