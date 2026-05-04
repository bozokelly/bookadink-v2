-- Server-authoritative membership gate for members-only club bookings.
--
-- Before this migration, book_game only enforced capacity (confirmed vs waitlisted).
-- A non-member on Android, via direct API, or via a cache miss on iOS could insert
-- a booking for a members-only game with no server resistance.
--
-- Two layers of enforcement:
-- 1. book_game RPC (primary gate): checked inside the FOR UPDATE lock, before the
--    INSERT, so the error is atomic with the booking decision.
-- 2. bookings INSERT RLS policy (defence-in-depth): catches direct PostgREST INSERTs
--    that bypass the RPC. The admin-override policy is left untouched so
--    ownerCreateBooking still works without restriction.
--
-- Error codes:
--   membership_required  — caller is not an approved member / owner / admin
--   unauthorized         — caller passed a user_id != auth.uid()

CREATE OR REPLACE FUNCTION book_game(
    p_game_id               UUID,
    p_user_id               UUID,
    p_fee_paid              BOOLEAN  DEFAULT FALSE,
    p_stripe_pi_id          TEXT     DEFAULT NULL,
    p_payment_method        TEXT     DEFAULT NULL,
    p_platform_fee_cents    INT      DEFAULT NULL,
    p_club_payout_cents     INT      DEFAULT NULL,
    p_credits_applied_cents INT      DEFAULT NULL
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
    v_max_players   INT;
    v_club_id       UUID;
    v_members_only  BOOL;
    v_confirmed_cnt INT;
    v_waitlist_pos  INT;
    v_status        TEXT;
    v_booking_id    UUID;
BEGIN
    -- Prevent booking on behalf of another user.
    -- book_game is SECURITY DEFINER so RLS is bypassed; enforce caller identity here.
    IF p_user_id != auth.uid() THEN
        RAISE EXCEPTION 'unauthorized';
    END IF;

    -- Lock the game row to prevent concurrent over-booking.
    -- Cast status::text because booking_status is a PG enum; direct string
    -- comparisons in IN() raise 22P02 on some PG versions (see CLAUDE.md).
    SELECT g.max_players, g.club_id
    INTO   v_max_players, v_club_id
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    -- Membership gate: members-only clubs require an approved club_members row.
    -- Club owners and admins are exempt — they can always add themselves.
    SELECT c.members_only INTO v_members_only
    FROM   clubs c
    WHERE  c.id = v_club_id;

    IF v_members_only THEN
        IF NOT (
            EXISTS (
                SELECT 1 FROM club_members
                WHERE  club_id  = v_club_id
                  AND  user_id  = auth.uid()
                  AND  status::text = 'approved'
            )
            OR EXISTS (
                SELECT 1 FROM clubs
                WHERE  id = v_club_id AND created_by = auth.uid()
            )
            OR EXISTS (
                SELECT 1 FROM club_admins
                WHERE  club_id = v_club_id AND user_id = auth.uid()
            )
        ) THEN
            RAISE EXCEPTION 'membership_required';
        END IF;
    END IF;

    -- Count active (non-cancelled) seats.
    SELECT COUNT(*) INTO v_confirmed_cnt
    FROM   bookings
    WHERE  game_id = p_game_id
      AND  status::text IN ('confirmed', 'pending_payment');

    IF v_max_players IS NOT NULL AND v_confirmed_cnt >= v_max_players THEN
        -- Game is full — place on waitlist.
        SELECT COALESCE(MAX(waitlist_position), 0) + 1 INTO v_waitlist_pos
        FROM   bookings
        WHERE  game_id = p_game_id
          AND  status::text = 'waitlisted';

        v_status      := 'waitlisted';
    ELSE
        -- Spot available.
        v_waitlist_pos := NULL;
        v_status       := 'confirmed';
    END IF;

    INSERT INTO bookings (
        game_id,
        user_id,
        status,
        waitlist_position,
        fee_paid,
        stripe_payment_intent_id,
        payment_method,
        platform_fee_cents,
        club_payout_cents,
        credits_applied_cents
    ) VALUES (
        p_game_id,
        p_user_id,
        v_status::booking_status,
        v_waitlist_pos,
        p_fee_paid,
        p_stripe_pi_id,
        p_payment_method,
        p_platform_fee_cents,
        p_club_payout_cents,
        p_credits_applied_cents
    )
    RETURNING bookings.id INTO v_booking_id;

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

GRANT EXECUTE ON FUNCTION book_game(UUID, UUID, BOOLEAN, TEXT, TEXT, INT, INT, INT) TO authenticated;

-- ─── Defence-in-depth: RLS on direct bookings INSERT ─────────────────────────
-- Replaces the existing "Users can create own bookings" policy.
-- The admin-override policy ("Club owner or admin can create bookings for others")
-- is left untouched so ownerCreateBooking remains unrestricted.

DROP POLICY IF EXISTS "Users can create own bookings" ON bookings;
CREATE POLICY "Users can create own bookings"
  ON bookings FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND (
      -- Public club: no membership gate
      NOT EXISTS (
        SELECT 1
        FROM   games g
        JOIN   clubs c ON c.id = g.club_id
        WHERE  g.id = bookings.game_id
          AND  c.members_only = TRUE
      )
      OR
      -- Members-only club: approved member
      EXISTS (
        SELECT 1
        FROM   games g
        JOIN   clubs c ON c.id = g.club_id
        JOIN   club_members cm ON cm.club_id = c.id
        WHERE  g.id        = bookings.game_id
          AND  cm.user_id  = auth.uid()
          AND  cm.status::text = 'approved'
      )
      OR
      -- Club owner
      EXISTS (
        SELECT 1
        FROM   games g
        JOIN   clubs c ON c.id = g.club_id
        WHERE  g.id = bookings.game_id AND c.created_by = auth.uid()
      )
      OR
      -- Club admin
      EXISTS (
        SELECT 1
        FROM   games g
        JOIN   club_admins ca ON ca.club_id = g.club_id
        WHERE  g.id = bookings.game_id AND ca.user_id = auth.uid()
      )
    )
  );
