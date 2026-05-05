-- Surgical: deferred cancellation credit conditional on actual replacement.
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDS ON
--   20260505030000_replacement_tracking_columns.sql — adds
--     bookings.replacement_booking_id, .replacement_confirmed_at, .replacement_credit_issued_at.
--
-- WHAT THIS DOES
--   Replaces the simplistic "any waitlist promotion = was_replaced" model
--   from 20260505020000 with a strict replacement-aware model:
--
--   1. cancel_booking_with_credit
--        Inside the cutoff window AND no inline replacement → cancel only,
--        return zeros; the deferred trigger may credit later if a paid
--        replacement actually confirms+pays. Outside the cutoff window OR
--        was_replaced=TRUE (free-game inline replacement) → credit
--        immediately. Whenever credit is issued, stamp
--        replacement_credit_issued_at on the booking as the idempotency
--        guard against the deferred trigger crediting again.
--
--   2. promote_top_waitlisted (trigger)
--        PAID game promotion (waitlister → pending_payment): set
--        replacement_booking_id on the cancelled booking, but NOT
--        was_replaced. The replacement is held, not yet confirmed.
--        FREE game promotion (waitlister → confirmed): set
--        replacement_booking_id + was_replaced + replacement_confirmed_at
--        on the cancelled booking AFTER the waitlister UPDATE. The
--        wrapping cancel_booking_with_credit transaction then sees
--        was_replaced=TRUE on its post-cancel re-read and credits inline.
--        Marks AFTER the waitlister UPDATE means the deferred trigger
--        fires on the waitlister's confirmed-transition while the
--        cancelled booking still has replacement_booking_id=NULL,
--        so the deferred trigger does not also credit. Single issuance.
--
--   3. revert_expired_holds_and_repromote (cron)
--        On forfeit + inline re-promotion: re-point any original cancelled
--        booking's replacement_booking_id from the forfeit booking to the
--        newly promoted waitlister BEFORE updating the waitlister's status.
--        On forfeit with NO next waitlister or no capacity: NULL the link.
--        Forfeit booking itself is NOT marked was_replaced — forfeits are
--        not replacements. Spec: "If promoted replacement hold expires:
--        do not issue credit; clear or leave replacement reference only
--        if safe/auditable; ensure another later confirmed replacement
--        can still credit the original cancelled booking if applicable."
--        Re-pointing achieves both (clear when no candidate, redirect when
--        there is one).
--
--   4. New deferred-credit trigger credit_on_replacement_confirmed
--        Fires AFTER UPDATE OF status, fee_paid on bookings. When a booking
--        transitions INTO 'confirmed' (paid: also requires fee_paid=TRUE;
--        free: status alone), looks for cancelled bookings whose outstanding
--        replacement candidate is THIS booking (replacement_booking_id=NEW.id
--        AND status='cancelled' AND was_replaced=FALSE
--        AND replacement_credit_issued_at IS NULL). For each match: read
--        club's policy (club_managed → mark replaced but no credit; managed
--        → compute refund using the same math as cancel_booking_with_credit
--        and issue via player_credits upsert), then stamp was_replaced,
--        replacement_confirmed_at, and replacement_credit_issued_at.
--
--   5. promote_waitlist_player (admin manual RPC)
--        Aligned with the new model: heuristically link the unambiguous
--        cancelled candidate via replacement_booking_id BEFORE the
--        waitlister UPDATE. Never mark was_replaced — the deferred trigger
--        (free path inline, paid path on later confirm) handles that. If
--        the waitlister UPDATE fails, the speculative link is reverted.
--        Removes the previous heuristic was_replaced=TRUE write that
--        would have falsely sealed cancelled bookings against deferred
--        credit issuance.
--
-- IDEMPOTENCY
--   • replacement_credit_issued_at IS NULL is the single guard for credit
--     issuance. Both the cutoff path (cancel_booking_with_credit) and the
--     deferred path (credit_on_replacement_confirmed trigger) stamp it on
--     issuance and refuse to issue when it is already set.
--   • Re-running confirmation updates does not duplicate credit because
--     was_replaced flips TRUE on first issuance, excluding the row from
--     the trigger's filter on subsequent fires.
--
-- BLAST RADIUS
--   • Inside-cutoff cancellations on paid games with no waitlister: now
--     return 0 credit at cancel time (previously: returned 0 — same).
--   • Inside-cutoff cancellations on paid games WITH a waitlister: now
--     return 0 credit at cancel time, then receive credit later if/when
--     the promoted waitlister actually pays. Previously (20260505020000):
--     received credit immediately because was_replaced was set inline on
--     pending_payment promotion. This is the spec change.
--   • Outside-cutoff cancellations: receive credit immediately (unchanged).
--   • Free-game cancellations with a waitlister: receive credit immediately
--     (unchanged — was_replaced is set inline by the free-path of
--     promote_top_waitlisted).
--   • club_managed clubs: never issue credit (unchanged).
--
-- VERIFY AFTER RUN
--   1. Outside cutoff, no waitlist:
--        cancel → credit_issued > 0, was_eligible TRUE,
--          booking.replacement_credit_issued_at non-NULL,
--          booking.was_replaced FALSE.
--   2. Inside cutoff, no waitlist:
--        cancel → credit_issued = 0, was_eligible FALSE,
--          booking.replacement_credit_issued_at NULL.
--   3. Inside cutoff, paid game, waitlister:
--        cancel → credit_issued = 0, was_eligible FALSE,
--          booking.replacement_booking_id = waitlister_id,
--          booking.was_replaced FALSE,
--          booking.replacement_credit_issued_at NULL.
--   4. Same as (3), then waitlister confirms+pays:
--        booking.was_replaced TRUE,
--        booking.replacement_confirmed_at non-NULL,
--        booking.replacement_credit_issued_at non-NULL,
--        player_credits balance increased by refund amount.
--   5. Same as (3), then waitlister hold expires (cron forfeits):
--        booking.replacement_booking_id re-pointed to next waitlister
--          (or NULL if none).
--        No credit issued.
--   6. Free game, inside cutoff, waitlister promoted:
--        cancel → credit_issued > 0, was_eligible TRUE (because
--        was_replaced was set inline), booking.was_replaced TRUE,
--        booking.replacement_credit_issued_at non-NULL.
--   7. club_managed club, any scenario:
--        cancel + later replacement events → no credit ever issued.
--
-- SAFE TO RE-RUN: each function is CREATE OR REPLACE; trigger is
-- DROP IF EXISTS / CREATE.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. cancel_booking_with_credit ───────────────────────────────────────────
-- Inside cutoff with no inline replacement → no credit. Stamps
-- replacement_credit_issued_at whenever credit is actually issued so the
-- deferred trigger cannot re-credit later.

CREATE OR REPLACE FUNCTION cancel_booking_with_credit(p_booking_id UUID)
RETURNS TABLE(credit_issued_cents INT, was_eligible BOOL, new_balance_cents INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_booking         bookings%ROWTYPE;
    v_game_dt         TIMESTAMPTZ;
    v_club_id         UUID;
    v_policy_type     TEXT;
    v_cutoff_hours    INT;
    v_cutoff_at       TIMESTAMPTZ;
    v_was_replaced    BOOLEAN := FALSE;
    v_refund_cents    INT     := 0;
    v_new_balance     INT     := 0;
    v_eligible        BOOL    := FALSE;
BEGIN
    -- Lock booking + verify ownership.
    SELECT b.* INTO v_booking
    FROM   bookings b
    WHERE  b.id      = p_booking_id
      AND  b.user_id = auth.uid()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking_not_found' USING ERRCODE = 'P0002';
    END IF;

    -- Cancellable statuses only.
    IF v_booking.status::text NOT IN ('confirmed', 'pending_payment', 'waitlisted') THEN
        RAISE EXCEPTION 'not_cancellable' USING ERRCODE = 'P0002';
    END IF;

    -- Resolve game date, club, and per-club policy.
    SELECT g.date_time,
           g.club_id,
           COALESCE(c.cancellation_policy_type,  'managed'),
           COALESCE(c.cancellation_cutoff_hours, 12)
    INTO   v_game_dt, v_club_id, v_policy_type, v_cutoff_hours
    FROM   games g
    JOIN   clubs c ON c.id = g.club_id
    WHERE  g.id = v_booking.game_id;

    -- Cancel — fires promote_top_waitlisted trigger which may set
    -- replacement_booking_id (paid) OR was_replaced + replacement_booking_id
    -- + replacement_confirmed_at (free) on this same booking.
    UPDATE bookings
    SET    status = 'cancelled'::booking_status
    WHERE  id = p_booking_id;

    -- Re-read flags set by the trigger.
    SELECT COALESCE(b.was_replaced, FALSE)
    INTO   v_was_replaced
    FROM   bookings b
    WHERE  b.id = p_booking_id;

    -- club_managed: cancel only, never credit.
    IF v_policy_type = 'club_managed' THEN
        RAISE LOG 'cancel_booking: policy=club_managed booking=% club=% replaced=% — no credit',
            p_booking_id, v_club_id, v_was_replaced;

        v_new_balance := COALESCE(
            (SELECT pc.amount_cents
             FROM   player_credits pc
             WHERE  pc.user_id  = auth.uid()
               AND  pc.club_id  = v_club_id
               AND  pc.currency = 'aud'),
            0
        );
        RETURN QUERY SELECT 0, FALSE, v_new_balance;
        RETURN;
    END IF;

    -- managed: eligible NOW iff already replaced (free-game inline path)
    -- OR cancelled at-or-before the cutoff time. Inside-cutoff with no
    -- inline replacement returns 0 here; the deferred-credit trigger may
    -- credit later if a paid waitlister actually confirms+pays.
    v_cutoff_at := v_game_dt - (v_cutoff_hours || ' hours')::INTERVAL;
    v_eligible  := v_was_replaced OR (NOW() <= v_cutoff_at);

    RAISE LOG 'cancel_booking: policy=managed booking=% club=% game_dt=% cutoff_h=% replaced=% eligible=%',
        p_booking_id, v_club_id, v_game_dt, v_cutoff_hours, v_was_replaced, v_eligible;

    IF v_eligible THEN
        -- Refund math (unchanged):
        --   • Stripe-paid:   platform_fee + club_payout + credits_applied
        --   • Credit-only:   credits_applied
        --   • Free/admin:    0
        IF v_booking.fee_paid THEN
            v_refund_cents := COALESCE(v_booking.platform_fee_cents,   0)
                           + COALESCE(v_booking.club_payout_cents,     0)
                           + COALESCE(v_booking.credits_applied_cents, 0);
        ELSIF COALESCE(v_booking.credits_applied_cents, 0) > 0 THEN
            v_refund_cents := v_booking.credits_applied_cents;
        END IF;

        IF v_refund_cents > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (auth.uid(), v_club_id, v_refund_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
        END IF;

        -- Idempotency stamp — blocks the deferred trigger from re-crediting
        -- if a paid replacement subsequently confirms.
        UPDATE bookings
        SET    replacement_credit_issued_at = now()
        WHERE  id = p_booking_id;
    END IF;

    v_new_balance := COALESCE(
        (SELECT pc.amount_cents
         FROM   player_credits pc
         WHERE  pc.user_id  = auth.uid()
           AND  pc.club_id  = v_club_id
           AND  pc.currency = 'aud'),
        0
    );

    RETURN QUERY SELECT v_refund_cents, v_eligible, v_new_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION cancel_booking_with_credit(UUID) TO authenticated;


-- ── 2. promote_top_waitlisted ───────────────────────────────────────────────
-- PAID promotion: link only, no replacement-confirmed marker (replacement
-- is held, not yet paid). FREE promotion: full inline mark including
-- was_replaced=TRUE so the wrapping cancel_booking_with_credit can credit
-- immediately. Marks come AFTER the waitlister UPDATE so the deferred
-- trigger fires before replacement_booking_id is set on the cancelled
-- booking, ensuring single credit issuance.

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
  v_hold_minutes   INT  := get_waitlist_hold_minutes();
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
      -- Paid: replacement is held, not confirmed. Track the link only.
      -- Deferred-credit trigger will mark was_replaced + issue credit
      -- once this booking actually confirms+pays.
      UPDATE bookings
      SET    replacement_booking_id = v_booking_id
      WHERE  id = NEW.id;

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
      -- Free: replacement IS confirmed immediately. Mark the cancelled
      -- booking with full replacement state. Order matters: the marks are
      -- set AFTER the waitlister UPDATE so the deferred-credit trigger,
      -- which fires on that UPDATE's confirmed transition, sees
      -- replacement_booking_id=NULL on NEW.id and finds nothing — leaving
      -- credit issuance to the wrapping cancel_booking_with_credit
      -- transaction (which re-reads was_replaced=TRUE).
      UPDATE bookings
      SET
        was_replaced              = TRUE,
        replacement_booking_id    = v_booking_id,
        replacement_confirmed_at  = now()
      WHERE id = NEW.id;

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


-- ── 3. revert_expired_holds_and_repromote ──────────────────────────────────
-- Re-point the original cancelled booking's replacement_booking_id from the
-- forfeit booking to the newly promoted waitlister (or NULL if no candidate)
-- BEFORE updating the waitlister's status. Forfeit booking is NOT marked
-- was_replaced — a forfeit is not a replacement. Inline promotion preserved.

CREATE OR REPLACE FUNCTION revert_expired_holds_and_repromote()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r              RECORD;
    v_game         games%ROWTYPE;
    v_is_paid      BOOLEAN;
    v_active_cnt   INT;
    v_next_id      UUID;
    v_next_user    UUID;
    v_hold_minutes INT  := get_waitlist_hold_minutes();
    v_supabase_url CONSTANT TEXT := 'https://vdhwptzngjguluxcbzsi.supabase.co';
    v_anon_key     CONSTANT TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZkaHdwdHpuZ2pndWx1eGNienNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MDUwMDgsImV4cCI6MjA4NjQ4MTAwOH0.KhCdfv8EDGApovbdsEiEIE0vBJojy2tfEJzpgvcBuXk';
BEGIN
    FOR r IN
        SELECT b.id AS booking_id, b.game_id, b.user_id
        FROM   bookings b
        WHERE  b.status          = 'pending_payment'
          AND  b.hold_expires_at IS NOT NULL
          AND  b.hold_expires_at  < now()
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Forfeit the expired hold.
        UPDATE bookings
        SET
            status            = 'cancelled',
            hold_expires_at   = NULL,
            promoted_at       = NULL,
            waitlist_position = NULL
        WHERE id = r.booking_id;

        -- Forfeit push (best-effort).
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

        -- Re-promotion path.
        SELECT * INTO v_game FROM games WHERE id = r.game_id;
        IF NOT FOUND THEN
            -- Game vanished — clear stale link if any.
            UPDATE bookings
            SET    replacement_booking_id = NULL
            WHERE  replacement_booking_id        = r.booking_id
              AND  status::text                  = 'cancelled'
              AND  was_replaced                  = FALSE
              AND  replacement_credit_issued_at  IS NULL;
            CONTINUE;
        END IF;

        v_is_paid := COALESCE(v_game.fee_amount, 0) > 0;

        SELECT COUNT(*) INTO v_active_cnt
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status::text IN ('confirmed', 'pending_payment');

        IF v_active_cnt >= v_game.max_spots THEN
            -- Capacity already filled by another path. Clear the stale
            -- pointer; no future credit chain on this booking.
            UPDATE bookings
            SET    replacement_booking_id = NULL
            WHERE  replacement_booking_id        = r.booking_id
              AND  status::text                  = 'cancelled'
              AND  was_replaced                  = FALSE
              AND  replacement_credit_issued_at  IS NULL;
            CONTINUE;
        END IF;

        -- Pick the next waitlister.
        SELECT id, user_id
        INTO   v_next_id, v_next_user
        FROM   bookings
        WHERE  game_id = r.game_id
          AND  status  = 'waitlisted'
        ORDER  BY waitlist_position ASC NULLS LAST, created_at ASC
        LIMIT  1
        FOR UPDATE SKIP LOCKED;

        IF v_next_id IS NULL THEN
            -- No waitlister to take the freed spot. Clear the stale link.
            UPDATE bookings
            SET    replacement_booking_id = NULL
            WHERE  replacement_booking_id        = r.booking_id
              AND  status::text                  = 'cancelled'
              AND  was_replaced                  = FALSE
              AND  replacement_credit_issued_at  IS NULL;
            CONTINUE;
        END IF;

        -- Re-point any original cancelled booking that previously pointed
        -- at the forfeit booking BEFORE we update the waitlister. The
        -- deferred-credit trigger needs to see the new pointer when it
        -- fires on the waitlister's confirmed transition (free-game edge
        -- below); for paid the order is also safe because no trigger fires
        -- on pending_payment.
        UPDATE bookings
        SET    replacement_booking_id = v_next_id
        WHERE  replacement_booking_id        = r.booking_id
          AND  status::text                  = 'cancelled'
          AND  was_replaced                  = FALSE
          AND  replacement_credit_issued_at  IS NULL;

        IF v_is_paid THEN
            UPDATE bookings
            SET
                status            = 'pending_payment',
                waitlist_position = NULL,
                hold_expires_at   = now() + (v_hold_minutes || ' minutes')::INTERVAL,
                promoted_at       = now()
            WHERE id = v_next_id;

            -- No was_replaced mark on r.booking_id (forfeits are not
            -- replacements). No was_replaced mark on the original cancelled
            -- booking either — credit is deferred until v_next_id confirms+pays.

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
            -- Free-game edge: cron only iterates over pending_payment holds,
            -- which means the originating game was paid when the hold was
            -- set. v_is_paid=FALSE here means the game was edited to free
            -- in the meantime. UPDATE to confirmed fires the deferred-credit
            -- trigger which finds the original cancelled booking via the
            -- just-re-pointed replacement_booking_id and credits it.
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


-- ── 4. credit_on_replacement_confirmed (deferred credit trigger) ───────────
-- Fires when a booking transitions INTO confirmed. Issues credit to the
-- original cancelled booking whose replacement candidate is the booking
-- that just confirmed. Paid games require fee_paid=TRUE on the new
-- booking; free games accept confirmed status alone.

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
BEGIN
    -- Only act on transitions INTO 'confirmed'.
    IF NEW.status::text <> 'confirmed' THEN
        RETURN NEW;
    END IF;
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        -- Status didn't change; no transition. Skip.
        RETURN NEW;
    END IF;

    -- Look up game once: every candidate cancelled booking that points to
    -- NEW.id is on NEW.game_id, so they share club + policy.
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

    -- Paid game: the replacement booking must actually be paid. Without
    -- this check, a confirmed-but-unpaid booking (admin override etc.)
    -- would credit the original cancelling user prematurely.
    IF v_is_paid AND NOT COALESCE(NEW.fee_paid, FALSE) THEN
        RETURN NEW;
    END IF;

    -- Iterate over all cancelled bookings whose outstanding replacement
    -- candidate is THIS booking. The filter mirrors the partial index
    -- idx_bookings_pending_replacement.
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
            -- club_managed clubs handle refunds off-platform. Mark the
            -- audit columns but issue NO credit. replacement_credit_issued_at
            -- stays NULL — but was_replaced=TRUE excludes the row from
            -- the trigger's filter on any future fire, so it's sealed.
            UPDATE bookings
            SET    was_replaced              = TRUE,
                   replacement_confirmed_at  = now()
            WHERE  id = r.id;

            RAISE LOG 'deferred_credit: policy=club_managed booking=% replacement=% — no credit',
                r.id, NEW.id;
            CONTINUE;
        END IF;

        -- Refund math (identical to cancel_booking_with_credit):
        --   • Stripe-paid:   platform_fee + club_payout + credits_applied
        --   • Credit-only:   credits_applied
        --   • Free/admin:    0
        v_refund := 0;
        IF r.fee_paid THEN
            v_refund := COALESCE(r.platform_fee_cents,   0)
                     +  COALESCE(r.club_payout_cents,     0)
                     +  COALESCE(r.credits_applied_cents, 0);
        ELSIF COALESCE(r.credits_applied_cents, 0) > 0 THEN
            v_refund := r.credits_applied_cents;
        END IF;

        -- Mark replaced + credit-issued atomically with the credit upsert.
        -- replacement_credit_issued_at is set unconditionally on the
        -- managed-policy path: it's the idempotency guard whether or not
        -- a refundable amount existed.
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
        END IF;

        RAISE LOG 'deferred_credit: booking=% replacement=% user=% refund_cents=%',
            r.id, NEW.id, r.user_id, v_refund;
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_credit_on_replacement_confirmed ON bookings;
CREATE TRIGGER trg_credit_on_replacement_confirmed
AFTER UPDATE OF status, fee_paid ON bookings
FOR EACH ROW
EXECUTE FUNCTION credit_on_replacement_confirmed();


-- ── 5. promote_waitlist_player (admin manual safety net) ───────────────────
-- Aligned with the new model: link replacement_booking_id heuristically when
-- there is exactly one unambiguous candidate cancelled booking. NEVER mark
-- was_replaced here — for paid the replacement isn't yet confirmed, and for
-- free the deferred-credit trigger fires on the waitlister UPDATE and does
-- the marking + crediting itself. The link is set BEFORE the waitlister
-- UPDATE so the deferred trigger can find the candidate cancelled booking
-- when it fires. If the waitlister UPDATE fails (booking already promoted
-- by a parallel path, etc.), the speculative link is reverted.

CREATE OR REPLACE FUNCTION promote_waitlist_player(
    p_game_id      UUID,
    p_booking_id   UUID,
    p_hold_minutes INT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_spots       INT;
    v_fee_amount      INT;
    v_is_paid         BOOLEAN;
    v_active_cnt      INT;
    v_hold_mins       INT;
    v_rows_updated    INT;
    v_original_id     UUID;
    v_candidate_count INT;
BEGIN
    -- Lock the games row (same lock book_game / owner_create_booking /
    -- recompact_waitlist_positions take).
    SELECT g.max_spots, COALESCE(g.fee_amount, 0)
    INTO   v_max_spots, v_fee_amount
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    v_is_paid := v_fee_amount > 0;

    -- Capacity invariant: confirmed + pending_payment <= max_spots.
    SELECT COUNT(*)
    INTO   v_active_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_active_cnt >= v_max_spots THEN
        RETURN FALSE;
    END IF;

    v_hold_mins := GREATEST(1, LEAST(COALESCE(p_hold_minutes, get_waitlist_hold_minutes()), 1440));

    -- Heuristically link an unambiguous cancelled-non-replaced booking on
    -- this game to p_booking_id BEFORE updating the waitlister. =1 guard
    -- ensures we never mis-attribute the replacement when multiple
    -- candidates exist. The deferred-credit trigger (free path) needs the
    -- link in place when it fires on the confirmed transition.
    SELECT COUNT(*)
    INTO   v_candidate_count
    FROM   bookings b
    WHERE  b.game_id     = p_game_id
      AND  b.status::text = 'cancelled'
      AND  b.was_replaced = FALSE
      AND  b.replacement_booking_id IS NULL
      AND  b.replacement_credit_issued_at IS NULL;

    IF v_candidate_count = 1 THEN
        SELECT b.id
        INTO   v_original_id
        FROM   bookings b
        WHERE  b.game_id     = p_game_id
          AND  b.status::text = 'cancelled'
          AND  b.was_replaced = FALSE
          AND  b.replacement_booking_id IS NULL
          AND  b.replacement_credit_issued_at IS NULL
        ORDER  BY b.created_at DESC
        LIMIT  1;

        UPDATE bookings
        SET    replacement_booking_id = p_booking_id
        WHERE  id = v_original_id;
    END IF;

    -- Promote.
    IF v_is_paid THEN
        UPDATE bookings b
        SET
            status            = 'pending_payment',
            waitlist_position = NULL,
            hold_expires_at   = now() + (v_hold_mins || ' minutes')::INTERVAL,
            promoted_at       = now()
        WHERE  b.id      = p_booking_id
          AND  b.game_id = p_game_id
          AND  b.status::text = 'waitlisted';
    ELSE
        UPDATE bookings b
        SET
            status            = 'confirmed',
            waitlist_position = NULL,
            hold_expires_at   = NULL,
            promoted_at       = now()
        WHERE  b.id      = p_booking_id
          AND  b.game_id = p_game_id
          AND  b.status::text = 'waitlisted';
    END IF;

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    -- If the promotion didn't happen (booking wasn't waitlisted, race with
    -- another path, etc.), revert the speculative link. The trigger may
    -- already have fired for the free case if status was confirmed for an
    -- instant — but the WHERE clause requires status='waitlisted', so the
    -- update couldn't have happened in that case.
    IF v_rows_updated = 0 AND v_original_id IS NOT NULL THEN
        UPDATE bookings
        SET    replacement_booking_id = NULL
        WHERE  id = v_original_id
          AND  replacement_booking_id = p_booking_id;
    END IF;

    RETURN v_rows_updated > 0;
END;
$$;
