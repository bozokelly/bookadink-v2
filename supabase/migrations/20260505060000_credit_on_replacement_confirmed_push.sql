-- Surgical: have credit_on_replacement_confirmed fan out a push to the
-- original cancelling user when deferred credit is issued.
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDS ON
--   20260505030000_replacement_tracking_columns.sql
--   20260505040000_deferred_credit_and_replacement_tracking.sql
--   20260505050000_notification_type_replacement_credit_issued.sql
--
-- WHAT THIS DOES
--   Replaces the body of credit_on_replacement_confirmed() with an
--   identical version that, after a successful deferred credit issuance
--   on a 'managed'-policy club with a non-zero refund amount, calls
--   /functions/v1/replacement-credit-issued-push via net.http_post. The
--   Edge Function (deployed separately as
--   supabase/functions/replacement-credit-issued-push/) inserts the in-app
--   notifications row and sends APNs.
--
-- SCOPE — STRICTLY LIMITED
--   Only the trigger function body is rewritten. The trigger DDL
--   (`AFTER UPDATE OF status, fee_paid ON bookings`) is unchanged. The
--   eligibility/idempotency logic from 20260505040000 is preserved
--   verbatim:
--     • Trigger filter requires `replacement_credit_issued_at IS NULL`
--       on the cancelled booking — push is sent at most once per booking.
--     • club_managed branch CONTINUEs before reaching the push code —
--       no push for clubs that don't issue platform credit.
--     • Push is only fired when v_refund > 0 — zero-credit bookings
--       (e.g. free-game cancellations with no credits applied) are
--       silently marked replaced and skipped.
--
--   Outside-cutoff immediate credits issued via cancel_booking_with_credit
--   do NOT enter this trigger (they're not replacement events; the trigger
--   fires on a NEW booking transitioning to confirmed, not on the cancelled
--   booking itself). Those continue to surface via iOS's lastCancellationCredit
--   half-sheet — exactly the spec's "outside-cutoff immediate credits already
--   handled by cancel flow" requirement.
--
-- BLAST RADIUS
--   Adds one async net.http_post per deferred-credit issuance. Failure of
--   the HTTP queue or the Edge Function does not roll back the credit —
--   pg_net is fire-and-forget at the queue level, and the credit upsert
--   has already committed by the time the loop continues.
--
-- BODY PROVENANCE
--   credit_on_replacement_confirmed body is taken verbatim from
--   20260505040000_deferred_credit_and_replacement_tracking.sql with the
--   following addition only:
--     • New CONSTANT TEXT declarations for the Supabase URL + anon key
--       (same hardcoded credentials pattern as promote_top_waitlisted and
--       revert_expired_holds_and_repromote — see CLAUDE.md "Server-Side
--       Push Triggers" section).
--     • PERFORM net.http_post(...) inside the LOOP, on the managed +
--       v_refund > 0 branch only, AFTER the player_credits upsert and
--       AFTER the bookings UPDATE that sets the idempotency stamp.
--
-- VERIFY AFTER RUN
--   1. Apply the migration. Reload pg_net's config if needed (typically
--      not required — net.http_post is invoked in the function body).
--   2. Force a deferred-credit fire end-to-end (see migration 040000's
--      VERIFY block, scenario 4):
--        a. cancel a confirmed booking inside the cutoff on a paid game
--           with at least one waitlister.
--        b. confirm + pay as the promoted waitlister.
--      The original cancelling user should:
--        - have a row in `notifications` with type='replacement_credit_issued',
--          reference_id=club_id, title="Spot filled — credit issued".
--        - receive an APNs push with the same title/body if their device
--          has a push_token and notification_preferences allow.
--        - have their player_credits balance increased by the refund amount.
--   3. Check `net._http_response` for the corresponding HTTP response:
--        SELECT id, status_code, content::text, created
--          FROM net._http_response
--          ORDER BY created DESC LIMIT 5;
--      Expect 200 with `{"notified":true,"pushed":true}` (or `pushed:false`
--      with reason="no_token" / "user_pref_off" / "stale_token_cleared"
--      depending on the test user's state).
--   4. Re-trigger the same UPDATE chain (e.g. UPDATE the replacement
--      booking again) — verify NO new notification row, NO new HTTP
--      response. The bookings.replacement_credit_issued_at NOT NULL
--      check excludes the row from the trigger's filter on the second pass.
--
-- SAFE TO RE-RUN: function is CREATE OR REPLACE; trigger DDL untouched.
-- ─────────────────────────────────────────────────────────────────────────────


CREATE OR REPLACE FUNCTION credit_on_replacement_confirmed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r              RECORD;
    v_is_paid      BOOLEAN;
    v_policy_type  TEXT;
    v_club_id      UUID;
    v_refund       INT;
    v_game_fee     INT;
    v_supabase_url CONSTANT TEXT := 'https://vdhwptzngjguluxcbzsi.supabase.co';
    v_anon_key     CONSTANT TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZkaHdwdHpuZ2pndWx1eGNienNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MDUwMDgsImV4cCI6MjA4NjQ4MTAwOH0.KhCdfv8EDGApovbdsEiEIE0vBJojy2tfEJzpgvcBuXk';
BEGIN
    -- Only act on transitions INTO 'confirmed'.
    IF NEW.status::text <> 'confirmed' THEN
        RETURN NEW;
    END IF;
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;

    SELECT g.fee_amount,
           g.club_id,
           COALESCE(c.cancellation_policy_type, 'managed')
    INTO   v_game_fee, v_club_id, v_policy_type
    FROM   games g
    JOIN   clubs c ON c.id = g.club_id
    WHERE  g.id = NEW.game_id;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    v_is_paid := COALESCE(v_game_fee, 0) > 0;

    IF v_is_paid AND NOT COALESCE(NEW.fee_paid, FALSE) THEN
        RETURN NEW;
    END IF;

    FOR r IN
        SELECT b.id,
               b.user_id,
               b.fee_paid,
               b.platform_fee_cents,
               b.club_payout_cents,
               b.credits_applied_cents
        FROM   bookings b
        WHERE  b.replacement_booking_id        = NEW.id
          AND  b.status::text                  = 'cancelled'
          AND  b.was_replaced                  = FALSE
          AND  b.replacement_credit_issued_at  IS NULL
        FOR UPDATE
    LOOP
        IF v_policy_type = 'club_managed' THEN
            UPDATE bookings
            SET    was_replaced              = TRUE,
                   replacement_confirmed_at  = now()
            WHERE  id = r.id;

            RAISE LOG 'deferred_credit: policy=club_managed booking=% replacement=% — no credit, no push',
                r.id, NEW.id;
            CONTINUE;
        END IF;

        v_refund := 0;
        IF r.fee_paid THEN
            v_refund := COALESCE(r.platform_fee_cents,   0)
                     +  COALESCE(r.club_payout_cents,     0)
                     +  COALESCE(r.credits_applied_cents, 0);
        ELSIF COALESCE(r.credits_applied_cents, 0) > 0 THEN
            v_refund := r.credits_applied_cents;
        END IF;

        UPDATE bookings
        SET    was_replaced                  = TRUE,
               replacement_confirmed_at      = now(),
               replacement_credit_issued_at  = now()
        WHERE  id = r.id;

        IF v_refund > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (r.user_id, v_club_id, v_refund, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;

            -- Notify the original cancelling user that their cancelled spot
            -- was filled and credit has been added to their account. Only
            -- fired when actual credit was issued (v_refund > 0), only on
            -- the managed-policy branch (club_managed CONTINUEd above), and
            -- only once per cancelled booking (replacement_credit_issued_at
            -- is now non-NULL — the trigger's filter excludes this row on
            -- subsequent fires, so re-triggering the same UPDATE chain
            -- cannot produce a duplicate push).
            --
            -- Hardcoded URL + anon key per CLAUDE.md "Server-Side Push
            -- Triggers" — current_setting('app.supabase_url') returns NULL
            -- on Supabase hosted, and DB triggers must call --no-verify-jwt
            -- Edge Functions only.
            PERFORM net.http_post(
                url     := v_supabase_url || '/functions/v1/replacement-credit-issued-push',
                headers := jsonb_build_object(
                               'Content-Type',  'application/json',
                               'Authorization', 'Bearer ' || v_anon_key
                           ),
                body    := jsonb_build_object(
                               'user_id',             r.user_id::text,
                               'booking_id',          r.id::text,
                               'game_id',             NEW.game_id::text,
                               'club_id',             v_club_id::text,
                               'credit_issued_cents', v_refund
                           )
            );
        END IF;

        RAISE LOG 'deferred_credit: booking=% replacement=% user=% refund_cents=% pushed=%',
            r.id, NEW.id, r.user_id, v_refund, (v_refund > 0);
    END LOOP;

    RETURN NEW;
END;
$$;
