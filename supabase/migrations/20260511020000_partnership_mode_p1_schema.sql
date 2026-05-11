-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — Phase 1 (P1): additive schema only.
--
-- Adds the storage layer for partnered registration without touching booking,
-- payment, waitlist, or any client-visible behaviour. Every existing game gets
-- partnership_mode='solo' via the column DEFAULT; the new booking_partnerships
-- table is empty and only writable via SECURITY DEFINER RPCs added in P2+.
--
-- INVARIANTS PRESERVED:
--   • book_game(), owner_create_booking(), promote_top_waitlisted, and the
--     waitlist/credit/hold flows are byte-identical — they neither read nor
--     write the new column or table.
--   • RLS on booking_partnerships is ENABLED with no policies — direct
--     PostgREST reads return zero rows. P2+ SECURITY DEFINER RPCs bypass
--     RLS and remain the only write path. A SELECT policy will be added
--     in the slice where iOS starts reading partnership rows (P5).
--   • iOS game SELECT strings are NOT yet updated in this slice; they will
--     pick up partnership_mode in the companion iOS commit. PostgREST
--     returns the same JSON shape it returned yesterday for callers that
--     do not enumerate the column.
--
-- VERIFICATION AFTER APPLY:
--   SELECT count(*) FROM games WHERE partnership_mode IS NULL;             -- 0
--   SELECT count(*) FROM games WHERE partnership_mode = 'solo';            -- == total games
--   SELECT count(*) FROM games WHERE partnership_mode = 'partnered';       -- 0
--   SELECT count(*) FROM booking_partnerships;                             -- 0
--   SELECT relrowsecurity FROM pg_class WHERE relname='booking_partnerships'; -- t
--   SELECT count(*) FROM pg_policies WHERE tablename='booking_partnerships'; -- 0
--   -- CHECK enforcement smoke test (must raise constraint violation):
--   --   UPDATE games SET partnership_mode='trio' WHERE id = '<any id>';
--
-- ROLLBACK (in a single transaction):
--   BEGIN;
--     DROP INDEX IF EXISTS public.one_active_partnership_player_a;
--     DROP INDEX IF EXISTS public.one_active_partnership_player_b;
--     DROP TABLE IF EXISTS public.booking_partnerships;
--     ALTER TABLE public.games
--       DROP CONSTRAINT IF EXISTS games_partnership_mode_check,
--       DROP COLUMN IF EXISTS partnership_mode;
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. games.partnership_mode — solo (default) or partnered.
ALTER TABLE public.games
  ADD COLUMN IF NOT EXISTS partnership_mode TEXT NOT NULL DEFAULT 'solo';

ALTER TABLE public.games
  DROP CONSTRAINT IF EXISTS games_partnership_mode_check;

ALTER TABLE public.games
  ADD CONSTRAINT games_partnership_mode_check
    CHECK (partnership_mode IN ('solo', 'partnered'));

-- 2. booking_partnerships — per-game partnership rows.
--    player_a_booking_id : always set (CHECK enforced). The "self" side.
--    player_b_booking_id : set when paired; NULL while awaiting allocation.
--    status              : pending (awaiting partner) | complete (both seats
--                          confirmed/held) | cancelled (one side cancelled
--                          or hold expired).
--    requested_by        : the profile that initiated the partnership row.
--                          Used for audit + future "swap partner" flows.
CREATE TABLE IF NOT EXISTS public.booking_partnerships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id UUID NOT NULL REFERENCES public.games(id) ON DELETE CASCADE,
  player_a_booking_id UUID REFERENCES public.bookings(id) ON DELETE CASCADE,
  player_b_booking_id UUID REFERENCES public.bookings(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'complete', 'cancelled')),
  requested_by UUID NOT NULL REFERENCES public.profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT booking_partnerships_has_player_a
    CHECK (player_a_booking_id IS NOT NULL),

  CONSTRAINT booking_partnerships_no_self_pair
    CHECK (
      player_b_booking_id IS NULL
      OR player_a_booking_id <> player_b_booking_id
    )
);

-- 3. One booking can only be `player_a` in one active (pending|complete)
--    partnership. Cancelled rows are excluded so a re-pair after a cancel
--    is allowed.
CREATE UNIQUE INDEX IF NOT EXISTS one_active_partnership_player_a
  ON public.booking_partnerships(player_a_booking_id)
  WHERE status IN ('pending', 'complete');

-- 4. Same for `player_b`, but only when it is set. allocate-me rows
--    (NULL player_b) coexist freely until paired.
CREATE UNIQUE INDEX IF NOT EXISTS one_active_partnership_player_b
  ON public.booking_partnerships(player_b_booking_id)
  WHERE player_b_booking_id IS NOT NULL
    AND status IN ('pending', 'complete');

-- 5. RLS enabled, no policies. P2+ SECURITY DEFINER RPCs are the only writer.
--    SELECT policy lands in the slice where iOS starts reading partnership
--    rows; until then PostgREST returns zero rows for direct reads.
ALTER TABLE public.booking_partnerships ENABLE ROW LEVEL SECURITY;
