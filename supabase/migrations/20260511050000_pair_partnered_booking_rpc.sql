-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — Phase 3 (P3): pair_partnered_booking() RPC.
--
-- Adds an owner/admin-only SECURITY DEFINER RPC that pairs two already-active
-- bookings in a partnered game into a single complete partnership row.
-- Replaces the only previously-supported flow ("requester books first,
-- partner books second and completes via book_game") with an explicit admin-
-- driven path that works even when both players are already booked solo,
-- when both used `p_allocate_partner=TRUE`, or when intents disagree.
--
-- Solo games, payment flow, waitlist promotion, and the cancellation /
-- credits pipeline are untouched. Only the booking_partnerships table is
-- written.
--
-- SIGNATURE:
--   pair_partnered_booking(
--     p_game_id            UUID,   -- the partnered game
--     p_booking_id         UUID,   -- the "player A" booking
--     p_partner_booking_id UUID    -- the "player B" booking
--   ) RETURNS TABLE(
--     id, game_id, player_a_booking_id, player_b_booking_id,
--     status, requested_by, requested_partner_user_id,
--     created_at, updated_at
--   )
--
-- VALIDATION ORDER (cheap → expensive):
--   1. authentication_required
--   2. same_booking_not_allowed                (p_booking_id == p_partner_booking_id)
--   3. game_not_found                          (FOR UPDATE on games row)
--   4. not_a_partnered_game                    (g.partnership_mode != 'partnered')
--   5. forbidden_owner_or_admin_only           (caller not club owner/admin)
--   6. booking_not_found / partner_booking_not_found
--   7. bookings_game_mismatch                  (booking.game_id != p_game_id)
--   8. booking_not_active / partner_booking_not_active
--                                              (status not in confirmed|pending_payment)
--   9. booking_payment_pending / partner_booking_payment_pending
--                                              (status is pending_payment — see policy note)
--   10. partner_is_self                        (defensive: should be impossible
--                                              given distinct booking IDs + the
--                                              `(user_id, game_id)` uniqueness
--                                              on bookings, but cheap to check)
--   11. dupr_required / partner_dupr_required  (if game requires DUPR)
--   12. booking_already_in_complete_partnership
--                                              (either side already in 'complete')
--   13. partner_intent_already_reserved_by_other
--                                              (a third partnership already
--                                              names the partner as intent)
--
-- POLICY: pending_payment bookings are NOT eligible for manual pairing.
--   The spec calls for partnership completion to align with the payment rule,
--   and our enum has no intermediate "complete-but-not-paid" state.
--   Admins must wait until both players' bookings are confirmed before
--   pairing. (book_game()'s automatic-completion path remains as before for
--   the natural user flow.)
--
-- RESULT (UPDATE-or-INSERT):
--   Always normalises to a single 'complete' partnership row with
--   player_a_booking_id = p_booking_id and player_b_booking_id =
--   p_partner_booking_id. Concretely:
--     • If a pending row exists where player_a = p_booking_id (BP_A),
--       UPDATE it (player_b set, status='complete', intent overwritten to
--       partner's user_id, updated_at refreshed).
--     • If a pending row exists where player_a = p_partner_booking_id (BP_B),
--       CANCEL it first (frees any intent slot it held).
--     • If neither pending row exists, INSERT a fresh complete row with
--       requested_by = the calling admin.
--
-- INVARIANTS PRESERVED:
--   • Every column reference in the function body is alias-qualified
--     (g., b., c., ca., bp., p.) per CLAUDE.md RETURNS-TABLE rules.
--   • games FOR UPDATE serialises concurrent P3 calls for the same game,
--     making bookings FOR UPDATE unnecessary (no cross-game lock order
--     deadlock either, because bookings belong to a single game).
--   • RLS on booking_partnerships remains ENABLED with no policies; this
--     RPC bypasses RLS via SECURITY DEFINER and is the only write path.
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.pair_partnered_booking(UUID, UUID, UUID);
--   (The booking_partnerships rows written by the RPC are intentionally
--   preserved on rollback — they represent real player intent. Manual cleanup
--   via UPDATE booking_partnerships SET status='cancelled' is the safer way
--   to undo data effects.)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.pair_partnered_booking(
    p_game_id            UUID,
    p_booking_id         UUID,
    p_partner_booking_id UUID
)
RETURNS TABLE (
    id                        UUID,
    game_id                   UUID,
    player_a_booking_id       UUID,
    player_b_booking_id       UUID,
    status                    TEXT,
    requested_by              UUID,
    requested_partner_user_id UUID,
    created_at                TIMESTAMPTZ,
    updated_at                TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_caller_id           UUID := auth.uid();
    v_club_id             UUID;
    v_partnership_mode    TEXT;
    v_requires_dupr       BOOL;
    v_caller_is_admin     BOOL;
    v_booking_user_id     UUID;
    v_partner_user_id     UUID;
    v_booking_status      TEXT;
    v_partner_status      TEXT;
    v_booking_game_id     UUID;
    v_partner_game_id     UUID;
    v_caller_dupr         TEXT;
    v_partner_dupr        TEXT;
    v_bp_a_id             UUID;
    v_bp_b_id             UUID;
    v_complete_conflict   INT;
    v_intent_conflict     INT;
    v_result_id           UUID;
BEGIN
    -- 1. Auth
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'authentication_required';
    END IF;

    -- 2. Distinct bookings
    IF p_booking_id = p_partner_booking_id THEN
        RAISE EXCEPTION 'same_booking_not_allowed';
    END IF;

    -- 3-4. Game row lock + partnership mode + club lookup
    SELECT g.club_id,
           COALESCE(g.partnership_mode, 'solo'),
           COALESCE(g.requires_dupr, FALSE)
    INTO   v_club_id,
           v_partnership_mode,
           v_requires_dupr
    FROM   games g
    WHERE  g.id = p_game_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_not_found';
    END IF;

    IF v_partnership_mode <> 'partnered' THEN
        RAISE EXCEPTION 'not_a_partnered_game';
    END IF;

    -- 5. Caller must be club owner or admin. Dual-source check defends against
    -- a hypothetical drift between clubs.created_by and the club_admins
    -- "owner" row (kept in sync by triggers, but defence in depth).
    SELECT EXISTS (
        SELECT 1 FROM clubs c
        WHERE  c.id = v_club_id
          AND  c.created_by = v_caller_id
    ) OR EXISTS (
        SELECT 1 FROM club_admins ca
        WHERE  ca.club_id = v_club_id
          AND  ca.user_id = v_caller_id
          AND  ca.role IN ('owner', 'admin')
    )
    INTO v_caller_is_admin;

    IF NOT v_caller_is_admin THEN
        RAISE EXCEPTION 'forbidden_owner_or_admin_only';
    END IF;

    -- 6. Look up both bookings
    SELECT b.user_id, b.status::text, b.game_id
    INTO   v_booking_user_id, v_booking_status, v_booking_game_id
    FROM   bookings b
    WHERE  b.id = p_booking_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking_not_found';
    END IF;

    SELECT b.user_id, b.status::text, b.game_id
    INTO   v_partner_user_id, v_partner_status, v_partner_game_id
    FROM   bookings b
    WHERE  b.id = p_partner_booking_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'partner_booking_not_found';
    END IF;

    -- 7. Both bookings must belong to p_game_id
    IF v_booking_game_id <> p_game_id OR v_partner_game_id <> p_game_id THEN
        RAISE EXCEPTION 'bookings_game_mismatch';
    END IF;

    -- 8. Both must be active (not waitlisted, not cancelled)
    IF v_booking_status NOT IN ('confirmed', 'pending_payment') THEN
        RAISE EXCEPTION 'booking_not_active';
    END IF;
    IF v_partner_status NOT IN ('confirmed', 'pending_payment') THEN
        RAISE EXCEPTION 'partner_booking_not_active';
    END IF;

    -- 9. Outcome rule: 'complete' requires both bookings to be paid (confirmed).
    -- Pending_payment is rejected with a distinct code so the client can guide
    -- the admin to wait until payment lands.
    IF v_booking_status = 'pending_payment' THEN
        RAISE EXCEPTION 'booking_payment_pending';
    END IF;
    IF v_partner_status = 'pending_payment' THEN
        RAISE EXCEPTION 'partner_booking_payment_pending';
    END IF;

    -- 10. Distinct users (defensive)
    IF v_booking_user_id = v_partner_user_id THEN
        RAISE EXCEPTION 'partner_is_self';
    END IF;

    -- 11. DUPR gate (mirrors book_game's structure)
    IF v_requires_dupr THEN
        SELECT trim(p.dupr_id)
        INTO   v_caller_dupr
        FROM   profiles p
        WHERE  p.id = v_booking_user_id;
        IF v_caller_dupr IS NULL OR length(v_caller_dupr) < 6 THEN
            RAISE EXCEPTION 'dupr_required';
        END IF;

        SELECT trim(p.dupr_id)
        INTO   v_partner_dupr
        FROM   profiles p
        WHERE  p.id = v_partner_user_id;
        IF v_partner_dupr IS NULL OR length(v_partner_dupr) < 6 THEN
            RAISE EXCEPTION 'partner_dupr_required';
        END IF;
    END IF;

    -- 12. Neither booking is in a COMPLETE partnership for this game
    SELECT COUNT(*)
    INTO   v_complete_conflict
    FROM   booking_partnerships bp
    WHERE  bp.game_id = p_game_id
      AND  bp.status  = 'complete'
      AND  (bp.player_a_booking_id IN (p_booking_id, p_partner_booking_id)
            OR bp.player_b_booking_id IN (p_booking_id, p_partner_booking_id));

    IF v_complete_conflict > 0 THEN
        RAISE EXCEPTION 'booking_already_in_complete_partnership';
    END IF;

    -- 13. Find existing pending partnerships anchored on either booking.
    SELECT bp.id
    INTO   v_bp_a_id
    FROM   booking_partnerships bp
    WHERE  bp.game_id             = p_game_id
      AND  bp.status              = 'pending'
      AND  bp.player_a_booking_id = p_booking_id
    LIMIT 1;

    SELECT bp.id
    INTO   v_bp_b_id
    FROM   booking_partnerships bp
    WHERE  bp.game_id             = p_game_id
      AND  bp.status              = 'pending'
      AND  bp.player_a_booking_id = p_partner_booking_id
    LIMIT 1;

    -- 14. Cancel BP_B first (frees its intent slot before we touch BP_A).
    IF v_bp_b_id IS NOT NULL THEN
        UPDATE booking_partnerships bp
        SET    status     = 'cancelled',
               updated_at = now()
        WHERE  bp.id = v_bp_b_id;
    END IF;

    -- 15. Reject if a THIRD active partnership already names v_partner_user_id
    -- as its intended partner (excluding BP_A which we may be about to update).
    -- The unique index `one_active_partnership_per_intended_partner` would
    -- also catch this on write, but pre-checking yields a clean error code.
    SELECT COUNT(*)
    INTO   v_intent_conflict
    FROM   booking_partnerships bp
    WHERE  bp.game_id                   = p_game_id
      AND  bp.requested_partner_user_id = v_partner_user_id
      AND  bp.status                    IN ('pending', 'complete')
      AND  (v_bp_a_id IS NULL OR bp.id <> v_bp_a_id);

    IF v_intent_conflict > 0 THEN
        RAISE EXCEPTION 'partner_intent_already_reserved_by_other';
    END IF;

    -- 16. UPDATE BP_A if it exists, else INSERT fresh. Either way the result
    -- has player_a = p_booking_id, player_b = p_partner_booking_id, complete.
    IF v_bp_a_id IS NOT NULL THEN
        UPDATE booking_partnerships bp
        SET    player_b_booking_id       = p_partner_booking_id,
               requested_partner_user_id = v_partner_user_id,
               status                    = 'complete',
               updated_at                = now()
        WHERE  bp.id = v_bp_a_id
        RETURNING bp.id INTO v_result_id;
    ELSE
        INSERT INTO booking_partnerships (
            game_id,
            player_a_booking_id,
            player_b_booking_id,
            status,
            requested_by,
            requested_partner_user_id
        ) VALUES (
            p_game_id,
            p_booking_id,
            p_partner_booking_id,
            'complete',
            v_caller_id,
            v_partner_user_id
        )
        RETURNING booking_partnerships.id INTO v_result_id;
    END IF;

    RETURN QUERY
    SELECT
        bp.id,
        bp.game_id,
        bp.player_a_booking_id,
        bp.player_b_booking_id,
        bp.status,
        bp.requested_by,
        bp.requested_partner_user_id,
        bp.created_at,
        bp.updated_at
    FROM booking_partnerships bp
    WHERE bp.id = v_result_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.pair_partnered_booking(UUID, UUID, UUID) TO authenticated;
