-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — P2.1 corrective: track intended partner.
--
-- The P2 book_game() partnered branch rejected any p_partner_user_id whose
-- target was already booked into the same game. That made the "A books with
-- B as intended partner, B later books and the partnership completes" flow
-- impossible without a separate manual-pair RPC.
--
-- This slice adds a nullable `requested_partner_user_id` column to
-- booking_partnerships so a partnership row can record who the requester
-- intends to pair with BEFORE that user has a booking. The P2.1 function
-- update (20260511041000) reads this column to either:
--   • complete the requester's pending partnership when the named partner
--     later books and names the requester back, or
--   • reject a third caller who tries to claim the same intended partner
--     (enforced by the new partial unique index).
--
-- WHAT THIS MIGRATION DOES:
--   1. ALTER TABLE booking_partnerships ADD COLUMN requested_partner_user_id
--      UUID NULL REFERENCES profiles(id). Nullable because:
--        • allocate-partner rows leave the column NULL (intent is "any peer")
--        • legacy P2 rows (created before this slice) keep NULL until
--          superseded by future writes
--   2. Partial UNIQUE index on (game_id, requested_partner_user_id) WHERE
--      requested_partner_user_id IS NOT NULL AND status IN ('pending',
--      'complete'). This enforces "the same partner cannot be reserved by
--      multiple active partnerships in the same game unless cancelled" at
--      the DB level — a clean fallback when client/function logic races.
--
-- WHAT THIS MIGRATION DOES NOT DO:
--   • Does not back-fill the column for legacy P2 rows. Pre-2.1 partnerships
--     created via the old branch had no concept of intent; leaving them NULL
--     is correct — they behave as "no intent recorded", which the P2.1
--     book_game() treats as "cannot be auto-completed by a later partner
--     book_game call" (P3 manual pair RPC is the path).
--   • Does not change book_game(). The function update is a separate
--     migration (20260511041000) so this schema add and the function rewrite
--     can be reasoned about independently.
--
-- INVARIANTS PRESERVED:
--   • RLS on booking_partnerships remains ENABLED with no policies. PostgREST
--     reads still return zero rows for anon/authenticated. SECURITY DEFINER
--     RPCs remain the only write path.
--   • Existing partial unique indexes on player_a_booking_id and
--     player_b_booking_id are untouched.
--   • Existing CHECKs (has_player_a, no_self_pair, status_check) untouched.
--
-- VERIFICATION AFTER APPLY:
--   -- column shape
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='booking_partnerships'
--      AND column_name='requested_partner_user_id';
--   --   uuid | YES | (null)
--
--   -- foreign-key constraint
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conrelid='public.booking_partnerships'::regclass
--      AND conname LIKE '%requested_partner%';
--
--   -- partial unique index
--   SELECT indexname, indexdef FROM pg_indexes
--    WHERE schemaname='public' AND tablename='booking_partnerships'
--      AND indexname='one_active_partnership_per_intended_partner';
--
-- ROLLBACK (in a single transaction):
--   BEGIN;
--     DROP INDEX IF EXISTS public.one_active_partnership_per_intended_partner;
--     ALTER TABLE public.booking_partnerships
--       DROP COLUMN IF EXISTS requested_partner_user_id;
--   COMMIT;
--   -- After this, the live book_game() must also be reverted to the P2
--   -- body (20260511030000) since it would otherwise reference the dropped
--   -- column. Apply the rollback for 20260511041000 first if both exist.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.booking_partnerships
  ADD COLUMN IF NOT EXISTS requested_partner_user_id UUID NULL
    REFERENCES public.profiles(id);

CREATE UNIQUE INDEX IF NOT EXISTS one_active_partnership_per_intended_partner
  ON public.booking_partnerships(game_id, requested_partner_user_id)
  WHERE requested_partner_user_id IS NOT NULL
    AND status IN ('pending', 'complete');
