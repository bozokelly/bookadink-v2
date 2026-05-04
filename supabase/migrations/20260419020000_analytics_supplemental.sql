-- Club Analytics Supplemental RPC
--
-- get_club_analytics_supplemental(p_club_id, p_days)
-- Returns enriched operational metrics not covered by get_club_analytics_kpis.
-- Same Pro-plan gate: caller must be club owner or admin + analytics_access = true.
--
-- Metrics:
--   curr_member_joins      — new approved members in the current period (requested_at proxy)
--   prev_member_joins      — same, prior period (for delta)
--   total_active_members   — all currently approved members
--   curr_new_players       — first-time bookers at this club in the current period
--   curr_game_count        — non-cancelled past games hosted in the period
--   curr_no_show_count     — game_attendance rows with attendance_status = 'no_show'
--   curr_checked_count     — total game_attendance rows (attended + no_show) — denominator for no-show rate
--   curr_waitlist_count    — waitlisted bookings across current-period games (demand signal)
--   curr_paid_bookings     — confirmed stripe-paid bookings in the period
--   curr_free_bookings     — confirmed non-stripe (free/admin) bookings in the period
--   avg_rev_per_player_cents — club_payout_cents / distinct paying players (0 if no revenue)
--
-- Notes:
--   No-show rate is derived client-side: curr_no_show_count / curr_checked_count.
--   Returns 0 (not NULL) for all counts so the iOS client never needs to unwrap.
--   The waitlist count includes future games — it signals live demand, not historical activity.

CREATE OR REPLACE FUNCTION get_club_analytics_supplemental(
  p_club_id UUID,
  p_days    INT DEFAULT 30
)
RETURNS TABLE (
  curr_member_joins          BIGINT,
  prev_member_joins          BIGINT,
  total_active_members       BIGINT,
  curr_new_players           BIGINT,
  curr_game_count            BIGINT,
  curr_no_show_count         BIGINT,
  curr_checked_count         BIGINT,
  curr_waitlist_count        BIGINT,
  curr_paid_bookings         BIGINT,
  curr_free_bookings         BIGINT,
  avg_rev_per_player_cents   BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller     UUID        := auth.uid();
  v_curr_start TIMESTAMPTZ := now() - (p_days::TEXT || ' days')::INTERVAL;
  v_prev_start TIMESTAMPTZ := now() - (p_days::TEXT || ' days')::INTERVAL * 2;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller)
  AND NOT EXISTS (SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller)
  THEN RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001'; END IF;

  IF NOT EXISTS (SELECT 1 FROM club_entitlements WHERE club_id = p_club_id AND analytics_access = true)
  THEN RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001'; END IF;

  RETURN QUERY
  WITH
  -- All non-cancelled games in the current period (past + future, for waitlist / booking counts)
  curr_games AS (
    SELECT g.id
    FROM   games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_curr_start
  ),
  -- Previous period games
  prev_games AS (
    SELECT g.id
    FROM   games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_prev_start
      AND  g.date_time <  v_curr_start
  ),
  -- Past (already occurred) games in the current period — used for no-show & game_count
  curr_past_games AS (
    SELECT g.id
    FROM   games g
    WHERE  g.club_id   = p_club_id
      AND  g.status   != 'cancelled'
      AND  g.date_time >= v_curr_start
      AND  g.date_time <  now()
  ),
  -- Confirmed bookings on current period games
  curr_conf AS (
    SELECT b.user_id, b.game_id, b.payment_method,
           COALESCE(b.club_payout_cents, 0) AS payout,
           b.created_at
    FROM   bookings b
    WHERE  b.status  = 'confirmed'
      AND  b.game_id IN (SELECT id FROM curr_games)
  ),
  -- First-ever booking at this club per player (to identify new players)
  player_first_booking AS (
    SELECT b.user_id, MIN(b.created_at) AS first_at
    FROM   bookings b
    JOIN   games    g ON g.id = b.game_id
    WHERE  g.club_id = p_club_id
      AND  b.status  = 'confirmed'
    GROUP  BY b.user_id
  )
  SELECT
    -- Members who joined in the current period
    (SELECT COUNT(*) FROM club_members
     WHERE  club_id      = p_club_id
       AND  status       = 'approved'
       AND  requested_at >= v_curr_start)::BIGINT,

    -- Members who joined in the previous period
    (SELECT COUNT(*) FROM club_members
     WHERE  club_id      = p_club_id
       AND  status       = 'approved'
       AND  requested_at >= v_prev_start
       AND  requested_at <  v_curr_start)::BIGINT,

    -- Total approved members right now
    (SELECT COUNT(*) FROM club_members
     WHERE  club_id = p_club_id AND status = 'approved')::BIGINT,

    -- First-time bookers in the current period
    (SELECT COUNT(*) FROM player_first_booking
     WHERE  first_at >= v_curr_start)::BIGINT,

    -- Past games hosted in the current period
    (SELECT COUNT(*) FROM curr_past_games)::BIGINT,

    -- No-shows (from game_attendance — only games with attendance tracked)
    (SELECT COUNT(*) FROM game_attendance ga
     WHERE  ga.attendance_status = 'no_show'
       AND  ga.game_id IN (SELECT id FROM curr_past_games))::BIGINT,

    -- Total checked-in records (attended + no_show) — denominator for no-show rate
    (SELECT COUNT(*) FROM game_attendance ga
     WHERE  ga.game_id IN (SELECT id FROM curr_past_games))::BIGINT,

    -- Waitlisted bookings on current period games (live demand signal)
    (SELECT COUNT(*) FROM bookings b
     WHERE  b.status  = 'waitlisted'
       AND  b.game_id IN (SELECT id FROM curr_games))::BIGINT,

    -- Stripe-paid confirmed bookings
    (SELECT COUNT(*) FROM curr_conf WHERE payment_method = 'stripe')::BIGINT,

    -- Free / admin confirmed bookings (no stripe payment)
    (SELECT COUNT(*) FROM curr_conf
     WHERE  payment_method IS DISTINCT FROM 'stripe')::BIGINT,

    -- Average club payout per unique paying player (0 when no stripe revenue)
    CASE WHEN (SELECT COUNT(DISTINCT user_id) FROM curr_conf WHERE payment_method = 'stripe') > 0
         THEN ROUND(
           (SELECT SUM(payout) FROM curr_conf WHERE payment_method = 'stripe')::NUMERIC
           / (SELECT COUNT(DISTINCT user_id) FROM curr_conf WHERE payment_method = 'stripe')
         )::BIGINT
         ELSE 0::BIGINT END;

END;
$$;

GRANT EXECUTE ON FUNCTION get_club_analytics_supplemental(UUID, INT) TO authenticated;
