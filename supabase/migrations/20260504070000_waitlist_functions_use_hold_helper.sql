-- Surgical: replace hardcoded hold-minute constants with get_waitlist_hold_minutes().
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDS ON: 20260504060000_app_config_waitlist_hold_helper.sql (additive — must
--             be applied first so get_waitlist_hold_minutes() exists).
--
-- SCOPE — STRICTLY LIMITED
--   For each of four functions, replace the hardcoded hold-minute literal with
--   a call to get_waitlist_hold_minutes(). Nothing else changes. Specifically:
--     - promote_top_waitlisted: trigger condition stays narrow
--       (OLD.status='confirmed' AND NEW.status='cancelled' only). NO capacity
--       check is added. NO game-row FOR UPDATE lock is added.
--     - revert_expired_holds_and_repromote: inline promotion logic is preserved
--       in full. The cron continues to forfeit + re-promote the next waitlister
--       inline (unchanged from current production behaviour).
--     - book_game: members-only gate and auth.uid() check are NOT introduced.
--     - promote_waitlist_player: only the parameter default and the inner
--       COALESCE fallback are sourced from the helper.
--   The known production bugs (W1 decline → W2 stranded; missing members-only
--   gate) are NOT addressed here. They are documented in CLAUDE.md under
--   "Pending architectural fixes" and require separate, paired migrations.
--
-- BODY PROVENANCE
--   Each function body below is the captured live `prosrc` from
--   pg_proc on 2026-05-04, with exactly one substitution: the hardcoded
--   CONSTANT INT literal is replaced by `get_waitlist_hold_minutes()` and
--   CONSTANT is dropped (a function call cannot be a CONSTANT initializer).
--   No other text is changed.
--
-- BEFORE APPLYING — re-verify nothing has drifted since capture:
--   SELECT pg_get_functiondef(p.oid)
--   FROM pg_proc p
--   WHERE p.proname IN (
--     'book_game','promote_top_waitlisted',
--     'revert_expired_holds_and_repromote','promote_waitlist_player'
--   );
--   Diff each body against the bodies in this migration. The only differences
--   should be the hold-minute literal lines. If anything else differs, STOP —
--   someone hand-edited a function and you risk reverting that edit.
--
-- BLAST RADIUS
--   Behaviour change: the effective hold duration switches from whatever each
--   function has hardcoded today (mixed: 2 / 30 / 30 / 30-default) to
--   whatever app_config says (currently '2'). This is the centralization.
--   No other behaviour changes.
--
-- VERIFY AFTER RUN
--   1. SELECT get_waitlist_hold_minutes();   -- e.g. 2
--   2. Trigger a fresh paid booking → bookings.hold_expires_at ≈ now() + 2min.
--   3. Cancel a confirmed booking on a paid game with a waitlister →
--      next waitlister becomes pending_payment with hold ≈ now() + 2min.
--   4. UPDATE app_config SET value = '5' WHERE key = 'waitlist_hold_minutes';
--      Repeat (2) and (3) → holds are now 5 min. No function recreation.
--
-- SAFE TO RE-RUN: each step is CREATE OR REPLACE.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. book_game: replace v_hold_mins constant with helper. ────────────────
-- Live prosrc preserved verbatim. Members-only gate and auth.uid() check are
-- intentionally absent (they are not in production today).

CREATE OR REPLACE FUNCTION book_game(
    p_game_id               UUID,
    p_user_id               UUID,
    p_fee_paid              BOOLEAN  DEFAULT FALSE,
    p_stripe_pi_id          TEXT     DEFAULT NULL,
    p_payment_method        TEXT     DEFAULT NULL,
    p_platform_fee_cents    INT      DEFAULT NULL,
    p_club_payout_cents     INT      DEFAULT NULL,
    p_credits_applied_cents INT      DEFAULT NULL,
    p_hold_for_payment      BOOLEAN  DEFAULT FALSE
)
RETURNS TABLE(
    id                       UUID,
    game_id                  UUID,
    user_id                  UUID,
    status                   TEXT,
    waitlist_position        INT,
    created_at               TIMESTAMPTZ,
    fee_paid                 BOOLEAN,
    paid_at                  TIMESTAMPTZ,
    stripe_payment_intent_id TEXT,
    payment_method           TEXT,
    platform_fee_cents       INT,
    club_payout_cents        INT,
    credits_applied_cents    INT,
    hold_expires_at          TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_spots     INT;
    v_requires_dupr BOOL;
    v_confirmed_cnt INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID := gen_random_uuid();
    v_hold_mins     INT := get_waitlist_hold_minutes();
    v_caller_dupr   TEXT;
BEGIN
    -- Lock the game row to prevent concurrent over-booking.
    -- Read requires_dupr alongside max_spots so the DUPR check is consistent
    -- with the capacity snapshot taken under the same lock.
    SELECT g.max_spots, COALESCE(g.requires_dupr, FALSE)
    INTO   v_max_spots, v_requires_dupr
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- DUPR gate: caller must have a stored DUPR ID when the game requires it.
    -- Applies to confirmed spots and waitlist joins alike.
    IF v_requires_dupr THEN
        SELECT trim(p.dupr_id)
        INTO   v_caller_dupr
        FROM   profiles p
        WHERE  p.id = p_user_id;

        IF v_caller_dupr IS NULL OR length(v_caller_dupr) < 6 THEN
            RAISE EXCEPTION 'dupr_required';
        END IF;
    END IF;

    -- Count active seats. Both `confirmed` and `pending_payment` physically
    -- hold a seat — the invariant is `confirmed + pending_payment <= max_spots`.
    SELECT COUNT(*) INTO v_confirmed_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_confirmed_cnt >= v_max_spots THEN
        -- Game is full — place on waitlist regardless of hold flag.
        SELECT COALESCE(MAX(b.waitlist_position), 0) + 1
        INTO   v_waitlist_pos
        FROM   bookings b
        WHERE  b.game_id      = p_game_id
          AND  b.status::text = 'waitlisted';

        v_status := 'waitlisted';
    ELSE
        -- Spot available. When the caller requests a payment hold (paid fresh
        -- booking), use pending_payment so the Stripe PI can be scoped to this
        -- booking_id and the cron job can revert it if payment never lands.
        v_waitlist_pos := NULL;
        v_status := CASE WHEN p_hold_for_payment THEN 'pending_payment' ELSE 'confirmed' END;
    END IF;

    -- INSERT column list refers to the bookings table directly; OUT variable
    -- shadowing does not apply to the column list — only to expressions in
    -- WHERE / SELECT / UPDATE / DELETE / SET clauses.
    INSERT INTO bookings (
        id,
        game_id,
        user_id,
        status,
        waitlist_position,
        fee_paid,
        stripe_payment_intent_id,
        payment_method,
        platform_fee_cents,
        club_payout_cents,
        credits_applied_cents,
        hold_expires_at
    ) VALUES (
        v_booking_id,
        p_game_id,
        p_user_id,
        v_status::booking_status,
        v_waitlist_pos,
        p_fee_paid,
        p_stripe_pi_id,
        p_payment_method,
        p_platform_fee_cents,
        p_club_payout_cents,
        p_credits_applied_cents,
        CASE WHEN v_status = 'pending_payment'
             THEN now() + (v_hold_mins || ' minutes')::INTERVAL
             ELSE NULL
        END
    );

    RETURN QUERY
    SELECT
        b.id,
        b.game_id,
        b.user_id,
        b.status::TEXT,
        b.waitlist_position,
        b.created_at,
        b.fee_paid,
        b.paid_at,
        b.stripe_payment_intent_id,
        b.payment_method,
        b.platform_fee_cents,
        b.club_payout_cents,
        b.credits_applied_cents,
        b.hold_expires_at
    FROM bookings b
    WHERE b.id = v_booking_id;
END;
$$;


-- ── 2. promote_top_waitlisted: replace v_hold_minutes constant with helper. ──
-- Trigger condition stays narrow (confirmed → cancelled only). NO capacity
-- check added. NO game-row lock added. Live prosrc preserved verbatim apart
-- from the one-line constant swap.

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


-- ── 3. revert_expired_holds_and_repromote: replace v_hold_minutes with helper. ──
-- Inline promotion is PRESERVED in full. This migration intentionally does NOT
-- adopt the simplified "forfeit + push only" cron design. Keeping the cron's
-- existing behaviour avoids requiring a paired trigger broadening, which is
-- the change that has historically introduced the 5/4 over-booking class.
-- Live prosrc preserved verbatim apart from the one-line constant swap.

CREATE OR REPLACE FUNCTION revert_expired_holds_and_repromote()
RETURNS VOID
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
    v_hold_minutes   INT  := get_waitlist_hold_minutes();
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


-- ── 4. promote_waitlist_player: parameter default + COALESCE fallback → helper. ──
-- Live body preserved verbatim apart from the parameter default and the
-- COALESCE fallback inside v_hold_mins. Clamp [1, 1440] preserved so an
-- explicit caller can still override within bounds.

-- NOTE on parameter order: live signature is (p_game_id, p_booking_id, p_hold_minutes).
-- The migration file 20260501040000 declares (p_booking_id, p_game_id, ...), which
-- never made it to production in that order. CREATE OR REPLACE cannot change
-- parameter names or order, so we MUST use the live order here.
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
    v_max_spots    INT;
    v_fee_amount   INT;
    v_is_paid      BOOLEAN;
    v_active_cnt   INT;
    v_hold_mins    INT;
    v_rows_updated INT;
BEGIN
    -- Lock the game row. Same lock book_game(), owner_create_booking(),
    -- and recompact_waitlist_positions() take. Without this, a concurrent
    -- book_game() could read max_spots and count active seats while we hold
    -- a stale snapshot — leading to over-booking under load.
    SELECT g.max_spots, COALESCE(g.fee_amount, 0)
    INTO   v_max_spots, v_fee_amount
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    v_is_paid := v_fee_amount > 0;

    -- Count active seats. confirmed AND pending_payment both physically hold
    -- a seat — the canonical invariant is `confirmed + pending_payment <= max_spots`.
    -- Counting only confirmed is the bug class that produced the 5/4 incident.
    SELECT COUNT(*)
    INTO   v_active_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_active_cnt >= v_max_spots THEN
        RETURN FALSE;
    END IF;

    -- Clamp hold_minutes to a sane range. Negative or zero values would
    -- create an immediately-expired hold (cron picks it up next minute and
    -- forfeits the user — confusing UX). Cap upper bound at 1440 (24h) so
    -- a buggy caller can't squat on a seat indefinitely.
    v_hold_mins := GREATEST(1, LEAST(COALESCE(p_hold_minutes, get_waitlist_hold_minutes()), 1440));

    -- Promote — atomic with the lock above. The status='waitlisted' filter
    -- means the promote_top_waitlisted trigger or another concurrent caller
    -- can't double-promote: only one of the racing UPDATEs will see status
    -- as 'waitlisted' at commit time, the other affects 0 rows.
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
        -- Free game — no payment hold needed; promote straight to confirmed.
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
    RETURN v_rows_updated > 0;
END;
$$;
