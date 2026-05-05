-- Surgical: wire cancellation policy + replacement marker into the four functions.
-- ─────────────────────────────────────────────────────────────────────────────
-- DEPENDS ON
--   20260505010000_cancellation_policy_columns.sql — must be applied first
--     so clubs.cancellation_policy_type, clubs.cancellation_cutoff_hours,
--     and bookings.was_replaced exist.
--
-- SCOPE — STRICTLY LIMITED
--   Each function below is the captured live `prosrc` from pg_proc on
--   2026-05-04 (per CLAUDE.md "Pending architectural fixes" — migration
--   table cannot be trusted; the live function body is the only truth).
--   Each is reproduced verbatim with the minimum additive edits needed:
--
--     1. cancel_booking_with_credit
--          - Read club's cancellation_policy_type and cancellation_cutoff_hours
--            (FROM clubs c JOIN games g ON g.club_id = c.id WHERE g.id = …).
--          - 'club_managed' → cancel only, return zeros, no credit.
--          - 'managed'      → cancel, then re-read was_replaced (so the
--                             trigger's mark is visible), then eligible iff
--                             was_replaced OR (now() < game_dt - cutoff).
--          - Refund math, status check, FOR UPDATE lock, idempotency, and
--            return shape are UNCHANGED.
--          - RAISE LOG line for production tracing.
--
--     2. promote_top_waitlisted (trigger)
--          - After a successful waitlister promote, mark NEW.id (the
--            cancelled booking that triggered us) as was_replaced=TRUE.
--          - Trigger condition stays narrow (confirmed → cancelled). Hold
--            value sourcing unchanged. No capacity check added.
--
--     3. revert_expired_holds_and_repromote (cron)
--          - After a successful inline promote of the next waitlister,
--            mark r.booking_id (the just-forfeited booking) was_replaced=TRUE.
--          - The forfeit user's booking is already cancelled; the flag is
--            never read for them (they cannot re-call cancel_booking_with_credit).
--            Set anyway for spec/audit consistency. No effect on credit.
--          - Inline promotion preserved in full.
--
--     4. promote_waitlist_player (admin RPC)
--          - After a successful manual promote, mark the cancelled
--            booking on the same game as was_replaced=TRUE — but ONLY
--            when there is exactly one cancelled-non-replaced booking
--            for that game (unambiguous link). If 0 or 2+ candidates,
--            do nothing. See "ADMIN PROMOTE LINKING" below.
--          - Lock, capacity check, hold sourcing, clamp all unchanged.
--
--   Cascade safety re-checked:
--     • trg_promote_top_waitlisted is `AFTER UPDATE OF status` — does NOT
--       re-fire when only was_replaced is set (status not in SET list).
--     • trg_compact_waitlist_on_leave is `AFTER UPDATE` (any column) — fires
--       but the function early-returns unless OLD.status='waitlisted' AND
--       NEW.status!='waitlisted'. For our was_replaced update on a cancelled
--       row, OLD.status='cancelled' so it's a no-op.
--
-- ADMIN PROMOTE LINKING (promote_waitlist_player only)
--   `promote_waitlist_player` is a manual safety net. The RPC has no
--   explicit reference to which cancelled booking is being replaced.
--   Rather than guess, we only set `was_replaced` when the link is
--   unambiguous — i.e. exactly one cancelled-non-replaced booking exists
--   for the game. With 0 candidates: nothing to mark. With 2+ candidates:
--   marking any one of them is a guess that could (a) put a false entry
--   in the audit trail and (b) — in a hypothetical future code path that
--   consulted the flag for an already-cancelled row — grant an incorrect
--   decision. Doing nothing in the multi-candidate case is the safe
--   default; the flag remains FALSE for all cancelled bookings on that
--   game until a more specific path (the trigger) marks them.
--
--   By the time this RPC is called, any cancelling user has already
--   received their cancel_booking_with_credit decision; setting
--   was_replaced afterwards has no effect on credit (the booking can
--   no longer be re-cancelled — it's already 'cancelled', which is
--   excluded from the RPC's cancellable status set). The flag exists
--   for audit/consistency only on this path.
--
-- BODY PROVENANCE
--   Bodies for promote_top_waitlisted, revert_expired_holds_and_repromote,
--   and promote_waitlist_player are taken verbatim from migration
--   20260504070000_waitlist_functions_use_hold_helper.sql (the most recent
--   surgical baseline that swapped hardcoded hold-minute literals for the
--   helper). cancel_booking_with_credit body is taken verbatim from
--   20260502010000_cancel_booking_credit_balance_null_fix.sql.
--
-- BEFORE APPLYING — re-verify nothing has drifted since 2026-05-04:
--   SELECT pg_get_functiondef(p.oid)
--   FROM   pg_proc p
--   WHERE  p.proname IN (
--     'cancel_booking_with_credit',
--     'promote_top_waitlisted',
--     'revert_expired_holds_and_repromote',
--     'promote_waitlist_player'
--   );
--   Diff each body against the bodies in this migration. The only
--   differences should be the additions documented above. If anything else
--   differs, STOP — someone hand-edited a function and you risk reverting
--   that edit.
--
-- BLAST RADIUS
--   Behaviour change for cancel_booking_with_credit:
--     • Before: hardcoded 6h window. After: per-club cutoff (default 12h).
--       Existing clubs default to 12h, so the eligible window WIDENS by 6h
--       for clubs that don't change the default. To preserve the previous
--       6h cutoff for a specific club:
--         UPDATE clubs SET cancellation_cutoff_hours = 6 WHERE id = …;
--     • Before: always 'managed' policy. After: 'managed' default — no
--       behaviour change unless an admin opts a club into 'club_managed'.
--     • New eligibility branch: was_replaced=TRUE → credit issued even
--       past cutoff. This intentionally rewards users whose cancellation
--       was filled by a waitlister.
--
--   Behaviour change for the three promotion paths:
--     • A single bookings.was_replaced UPDATE is added on the success
--       branch of each path. No promotion ordering, locking, or capacity
--       logic changes. The cascade triggers are no-ops on this update.
--
-- VERIFY AFTER RUN
--   1. Cancel a confirmed booking on a paid game with a waitlister:
--        - Trigger promotes waitlister.
--        - Cancelled booking now has was_replaced=TRUE.
--        - cancel_booking_with_credit returns credit_issued_cents > 0
--          regardless of game start time.
--   2. Cancel a confirmed booking on a paid game with NO waitlister, more
--      than cutoff_hours before start:
--        - Trigger fires, no promotion (no waitlisters).
--        - was_replaced stays FALSE.
--        - cancel_booking_with_credit returns credit_issued_cents > 0,
--          was_eligible=TRUE.
--   3. Same as (2) but inside the cutoff window:
--        - was_eligible=FALSE, credit_issued_cents=0.
--   4. UPDATE clubs SET cancellation_policy_type = 'club_managed' WHERE id = …;
--      Cancel a confirmed booking far before start:
--        - Booking cancelled, was_eligible=FALSE, credit_issued_cents=0.
--   5. UPDATE clubs SET cancellation_cutoff_hours = 24 WHERE id = …;
--      Repeat (3) → cutoff effective immediately, no app update needed.
--   6. Forfeit hold (let it expire, cron runs) on a paid game with a
--      waitlister:
--        - Forfeit booking cancelled, waitlister promoted inline.
--        - Forfeit booking now has was_replaced=TRUE (audit only).
--   7. promote_waitlist_player on a game with exactly one cancelled-
--      non-replaced booking:
--        - Promotion succeeds; the cancelled booking is marked
--          was_replaced=TRUE.
--      Same RPC on a game with 0 or 2+ cancelled-non-replaced bookings:
--        - Promotion succeeds; no audit mark is written (ambiguous link).
--   8. Double-call cancel_booking_with_credit on the same booking:
--        - Second call raises 'not_cancellable'. No double-credit.
--
-- SAFE TO RE-RUN: each step is CREATE OR REPLACE.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. cancel_booking_with_credit: per-club cutoff + was_replaced override ──

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
    v_refund_cents    INT := 0;
    v_new_balance     INT := 0;
    v_eligible        BOOL := FALSE;
BEGIN
    -- Lock the booking row and verify the caller owns it.
    SELECT b.* INTO v_booking
    FROM   bookings b
    WHERE  b.id      = p_booking_id
      AND  b.user_id = auth.uid()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking_not_found' USING ERRCODE = 'P0002';
    END IF;

    -- Only cancellable statuses. Cast to ::text — booking_status is a PG enum
    -- and direct string comparison in IN() raises 22P02 (see CLAUDE.md).
    IF v_booking.status::text NOT IN ('confirmed', 'pending_payment', 'waitlisted') THEN
        RAISE EXCEPTION 'not_cancellable' USING ERRCODE = 'P0002';
    END IF;

    -- Resolve game date, club, and per-club cancellation policy in a single
    -- join. The COALESCEs are belt-and-braces against any NULLs sneaking in
    -- before the columns' NOT NULL defaults applied (e.g. inserts during the
    -- additive migration window).
    SELECT g.date_time,
           g.club_id,
           COALESCE(c.cancellation_policy_type,  'managed'),
           COALESCE(c.cancellation_cutoff_hours, 12)
    INTO   v_game_dt, v_club_id, v_policy_type, v_cutoff_hours
    FROM   games g
    JOIN   clubs c ON c.id = g.club_id
    WHERE  g.id = v_booking.game_id;

    -- Cancel the booking. The trigger trg_promote_top_waitlisted fires here
    -- on confirmed→cancelled transitions and may set was_replaced=TRUE on
    -- this same row before control returns to us. Trigger updates inside
    -- this transaction are visible to subsequent reads in the same session.
    UPDATE bookings
    SET    status = 'cancelled'::booking_status
    WHERE  id = p_booking_id;

    -- Re-read was_replaced AFTER the cancel UPDATE so we observe any flag
    -- written by the promotion trigger. Subquery + COALESCE for paranoia.
    SELECT COALESCE(b.was_replaced, FALSE)
    INTO   v_was_replaced
    FROM   bookings b
    WHERE  b.id = p_booking_id;

    -- club_managed clubs handle refunds off-platform — never issue credit.
    -- The booking is still cancelled; only credit issuance is suppressed.
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

    -- managed policy: eligible if replaced OR cancelled before the cutoff.
    -- Cutoff is `game_start - cutoff_hours`; cancelling AT or BEFORE that
    -- timestamp is eligible. now() > v_cutoff_at means we're inside the
    -- cutoff window (too late to refund).
    v_cutoff_at := v_game_dt - (v_cutoff_hours || ' hours')::INTERVAL;
    v_eligible  := v_was_replaced OR (NOW() <= v_cutoff_at);

    RAISE LOG 'cancel_booking: policy=managed booking=% club=% game_dt=% cutoff_h=% replaced=% eligible=%',
        p_booking_id, v_club_id, v_game_dt, v_cutoff_hours, v_was_replaced, v_eligible;

    IF v_eligible THEN
        -- Refund policy (unchanged):
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

        -- Atomic upsert — no read-modify-write race. Idempotency: this
        -- branch is reached at most once per booking because the cancellable
        -- status check above raises on a second call.
        IF v_refund_cents > 0 THEN
            INSERT INTO player_credits (user_id, club_id, amount_cents, currency)
            VALUES (auth.uid(), v_club_id, v_refund_cents, 'aud')
            ON CONFLICT (user_id, club_id, currency)
            DO UPDATE SET amount_cents = player_credits.amount_cents + EXCLUDED.amount_cents;
        END IF;
    END IF;

    -- Authoritative new balance. Subquery + COALESCE so v_new_balance stays
    -- 0 when no player_credits row exists for this user/club/currency.
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


-- ── 2. promote_top_waitlisted: mark NEW.id was_replaced=TRUE on success. ────
-- Trigger condition stays narrow (confirmed → cancelled only). NO capacity
-- check added. NO game-row lock added. Live prosrc preserved verbatim apart
-- from the single-row was_replaced update on the success branch.

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
      -- Mark the cancelled booking that freed this seat as replaced.
      -- AFTER UPDATE OF status will not re-fire this trigger because
      -- was_replaced is not in the SET list. The compaction trigger fires
      -- but its function early-returns (OLD.status='cancelled' here).
      UPDATE bookings SET was_replaced = TRUE WHERE id = NEW.id;

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
      UPDATE bookings SET was_replaced = TRUE WHERE id = NEW.id;

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


-- ── 3. revert_expired_holds_and_repromote: mark forfeit booking on inline promote. ─
-- Inline promotion preserved in full. Live prosrc preserved verbatim apart
-- from the single-row was_replaced update on each successful inline promote.

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

            -- The forfeit booking's seat is now filled by v_next_id.
            -- Mark the forfeit booking replaced for audit consistency.
            -- Forfeit users cannot call cancel_booking_with_credit (their
            -- booking is already cancelled), so this flag is read-only here.
            UPDATE bookings SET was_replaced = TRUE WHERE id = r.booking_id;

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

            UPDATE bookings SET was_replaced = TRUE WHERE id = r.booking_id;

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


-- ── 4. promote_waitlist_player: best-effort mark of cancelled booking. ──────
-- Live signature is (p_game_id, p_booking_id, p_hold_minutes). Live body
-- preserved verbatim apart from the heuristic was_replaced mark on success.

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
    SELECT COUNT(*)
    INTO   v_active_cnt
    FROM   bookings b
    WHERE  b.game_id    = p_game_id
      AND  b.status::text IN ('confirmed', 'pending_payment');

    IF v_max_spots IS NOT NULL AND v_active_cnt >= v_max_spots THEN
        RETURN FALSE;
    END IF;

    -- Clamp hold_minutes to a sane range.
    v_hold_mins := GREATEST(1, LEAST(COALESCE(p_hold_minutes, get_waitlist_hold_minutes()), 1440));

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

    -- Mark the cancelled booking that this promotion replaces — but ONLY
    -- when the link is unambiguous, i.e. exactly one cancelled-non-replaced
    -- booking exists for the game. The admin RPC has no explicit reference
    -- to a specific cancelled booking, so when multiple candidates exist
    -- we cannot tell which one the promoted waitlister is filling. Marking
    -- the wrong booking would lie in the audit trail and (in theory) grant
    -- an incorrect credit if a future code path consulted the flag for an
    -- already-cancelled booking. Doing nothing is the safe default.
    --
    -- The =1 guard is checked in the same statement as the UPDATE so we
    -- don't race a concurrent cancel between a separate count and the
    -- update. If 0 candidates: subselect returns no row, UPDATE matches 0.
    -- If 1 candidate: UPDATE marks it. If 2+ candidates: =1 is false,
    -- UPDATE matches 0 — no audit mark written.
    IF v_rows_updated > 0 THEN
        UPDATE bookings
        SET    was_replaced = TRUE
        WHERE  id = (
            SELECT b.id
            FROM   bookings b
            WHERE  b.game_id     = p_game_id
              AND  b.status::text = 'cancelled'
              AND  b.was_replaced = FALSE
            ORDER  BY b.created_at DESC
            LIMIT  1
        )
          AND (
            SELECT COUNT(*)
            FROM   bookings b
            WHERE  b.game_id     = p_game_id
              AND  b.status::text = 'cancelled'
              AND  b.was_replaced = FALSE
        ) = 1;
    END IF;

    RETURN v_rows_updated > 0;
END;
$$;
