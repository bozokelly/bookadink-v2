-- Surgical: add `not_yet_published` gate to book_game(). Block bookings on
-- delayed-publish games whose publish_at is still in the future.
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM FIXED:
--   A scheduled game (games.publish_at > now()) is hidden from non-admins by
--   fetchUpcomingGames(), but admins still see it on the club games tab in a
--   dimmed "Not visible to the public" state. The dimmed card is tappable, and
--   the GameDetailView booking CTA was fully functional — an admin could book
--   and pay through the normal player flow before publish, creating real Stripe
--   charges and confirmed bookings on a game members couldn't even see yet.
--
--   The fix is server-authoritative: book_game() rejects unpublished games for
--   ALL callers (player and admin alike). Admins who legitimately need to seat
--   a player pre-publish must use the admin-only owner_create_booking() RPC,
--   which is the intended "Add Player" path. The PaymentIntent path is gated
--   separately in the create-payment-intent Edge Function so a Stripe charge
--   is never created against an unpublished game.
--
-- WHAT THIS MIGRATION DOES:
--   1. CREATE OR REPLACE book_game() with one surgical change: read publish_at
--      alongside max_spots and requires_dupr in the same FOR UPDATE snapshot,
--      and RAISE 'not_yet_published' when publish_at IS NOT NULL AND
--      publish_at > now(). The check sits between the "row found" check and
--      the DUPR gate so an unpublished game short-circuits before any
--      capacity / DUPR work is done.
--   2. Nothing else changes. v_hold_mins still sources from
--      get_waitlist_hold_minutes() (the centralized helper from
--      20260504070000). The DUPR gate, capacity invariant, hold-for-payment
--      branching, and INSERT shape are byte-identical to the live body.
--
-- BODY PROVENANCE:
--   Live prosrc captured from 20260504070000_waitlist_functions_use_hold_helper
--   on 2026-05-10. Only difference vs. that body is the new v_publish_at
--   declaration, the additional column in the SELECT, and the RAISE block
--   (~10 lines total). No other text changed.
--
-- BEFORE APPLYING — verify nothing has drifted:
--   SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'book_game';
--   Diff against migration 20260504070000. The only differences should be the
--   publish_at-related lines below.
--
-- BLAST RADIUS:
--   Behaviour change: bookings on games with publish_at in the future are now
--   rejected with HTTP 400 'not_yet_published'. Already-published games
--   (publish_at IS NULL or publish_at <= now()) are unaffected — the gate is
--   a no-op for them. Free games and paid games handled identically.
--
-- iOS handling:
--   SupabaseService.bookGame maps the 'not_yet_published' substring to
--   SupabaseServiceError.notYetPublished, surfaced to the user as
--   "This game isn't open for bookings yet." The UI also disables the booking
--   CTA pre-publish (defence in depth — server is authoritative).
--
-- ADMINS ARE NOT EXEMPT:
--   The gate fires for every caller including club owners and club_admins.
--   The legitimate pre-publish admin path is owner_create_booking(), which
--   already takes the same FOR UPDATE lock and respects the capacity invariant.
--   See "Separate admin management from normal booking" section in CLAUDE.md.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE is idempotent.
-- ─────────────────────────────────────────────────────────────────────────────

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
    v_publish_at    TIMESTAMPTZ;
    v_confirmed_cnt INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID := gen_random_uuid();
    v_hold_mins     INT := get_waitlist_hold_minutes();
    v_caller_dupr   TEXT;
BEGIN
    -- Lock the game row to prevent concurrent over-booking.
    -- Read publish_at + requires_dupr alongside max_spots so all gating
    -- decisions use the same locked snapshot of the games row.
    SELECT g.max_spots, COALESCE(g.requires_dupr, FALSE), g.publish_at
    INTO   v_max_spots, v_requires_dupr, v_publish_at
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Publish gate: a game with a future publish_at is not yet open for
    -- bookings. Applies to ALL callers — the legitimate pre-publish admin
    -- path is owner_create_booking(), not book_game().
    IF v_publish_at IS NOT NULL AND v_publish_at > now() THEN
        RAISE EXCEPTION 'not_yet_published';
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
