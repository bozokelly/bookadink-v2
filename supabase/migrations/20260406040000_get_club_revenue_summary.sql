-- Phase 5A-1 — Club Revenue Summary RPC
-- Run once in Supabase SQL Editor (as postgres).
-- Safe to re-run (CREATE OR REPLACE).
--
-- get_club_revenue_summary(p_club_id, p_days)
--   p_days = NULL → all time
--   p_days = 30   → last 30 days, etc.
--
-- Server enforces:
--   1. Caller must be club owner (clubs.created_by) or club admin (club_admins)
--   2. Club must have analytics_access = true in club_entitlements
--
-- Aggregation:
--   paid  = status = 'confirmed' AND payment_method = 'stripe'
--   free  = status = 'confirmed' AND payment_method != 'stripe' (admin comps, free games)
--   currency = most recent fee_currency on a paid booking for this club, defaulting to 'AUD'

CREATE OR REPLACE FUNCTION get_club_revenue_summary(
  p_club_id UUID,
  p_days    INT DEFAULT NULL
)
RETURNS TABLE (
  total_club_payout_cents   BIGINT,
  total_platform_fee_cents  BIGINT,
  paid_booking_count        INT,
  free_booking_count        INT,
  currency                  TEXT,
  as_of                     TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller UUID := auth.uid();
BEGIN
  -- 1. Verify caller is club owner or admin.
  IF NOT EXISTS (
    SELECT 1 FROM clubs WHERE id = p_club_id AND created_by = v_caller
  ) AND NOT EXISTS (
    SELECT 1 FROM club_admins WHERE club_id = p_club_id AND user_id = v_caller
  ) THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Verify analytics_access entitlement (server-side, not relying on iOS gate).
  IF NOT EXISTS (
    SELECT 1 FROM club_entitlements
    WHERE club_id = p_club_id AND analytics_access = true
  ) THEN
    RAISE EXCEPTION 'Analytics requires a Pro plan.' USING ERRCODE = 'P0001';
  END IF;

  -- 3. Aggregate.
  RETURN QUERY
  SELECT
    COALESCE(
      SUM(CASE WHEN b.payment_method = 'stripe'
               THEN COALESCE(b.club_payout_cents, 0) ELSE 0 END)::BIGINT,
      0
    ) AS total_club_payout_cents,

    COALESCE(
      SUM(CASE WHEN b.payment_method = 'stripe'
               THEN COALESCE(b.platform_fee_cents, 0) ELSE 0 END)::BIGINT,
      0
    ) AS total_platform_fee_cents,

    COUNT(CASE WHEN b.payment_method = 'stripe' THEN 1 END)::INT
      AS paid_booking_count,

    COUNT(CASE WHEN b.payment_method IS DISTINCT FROM 'stripe' THEN 1 END)::INT
      AS free_booking_count,

    -- Most recent fee_currency on a paid booking for this club.
    COALESCE(
      (SELECT g2.fee_currency
       FROM   games    g2
       JOIN   bookings b2 ON b2.game_id = g2.id
       WHERE  g2.club_id          = p_club_id
         AND  b2.status           = 'confirmed'
         AND  b2.payment_method   = 'stripe'
         AND  g2.fee_currency IS NOT NULL
       ORDER BY b2.created_at DESC
       LIMIT 1),
      'AUD'
    ) AS currency,

    now() AS as_of

  FROM   bookings b
  JOIN   games    g ON b.game_id = g.id
  WHERE  g.club_id = p_club_id
    AND  b.status  = 'confirmed'
    AND  (p_days IS NULL
          OR b.created_at >= now() - (p_days::TEXT || ' days')::INTERVAL);
END;
$$;

GRANT EXECUTE ON FUNCTION get_club_revenue_summary(UUID, INT) TO authenticated;
