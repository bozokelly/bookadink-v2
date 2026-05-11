-- ─────────────────────────────────────────────────────────────────────────────
-- Partnered game format — P2 corrective: drop the orphaned 9-arg overload.
--
-- 20260511030000_book_game_partnered_branch.sql added two new trailing params
-- to book_game(). PostgreSQL treats functions with different argument
-- signatures as distinct objects, so the original 9-arg variant persisted
-- alongside the new 11-arg one. PostgREST resolves overloads by named-arg
-- subset, which would leave existing iOS callers (which send exactly 9 named
-- args) dispatching to the OLD function body — the partnered branch never
-- fires.
--
-- This migration drops the 9-arg variant so the 11-arg version is the unique
-- public.book_game and serves both old and new callers via DEFAULTs on the
-- trailing p_partner_user_id / p_allocate_partner params.
--
-- INVARIANTS PRESERVED:
--   • The 11-arg function body — installed by 20260511030000 — is not
--     touched. We only DROP the orphan.
--   • Both functions share the same name + RETURNS TABLE shape, so any
--     callers currently mid-flight will route cleanly to the 11-arg
--     version once the 9-arg is gone (the trailing params default).
--   • Solo games behave identically: with the 11-arg function and the
--     new params defaulted, the solo branch executes byte-identical work
--     to the pre-P2 9-arg body.
--
-- VERIFICATION AFTER APPLY:
--   -- exactly one function named book_game must remain
--   SELECT count(*) FROM pg_proc WHERE proname='book_game';        -- 1
--   SELECT pronargs FROM pg_proc WHERE proname='book_game';        -- 11
--   SELECT pg_get_function_identity_arguments(oid)
--     FROM pg_proc WHERE proname='book_game';
--   --   p_game_id uuid, p_user_id uuid, p_fee_paid boolean, ...
--   --   p_hold_for_payment boolean, p_partner_user_id uuid, p_allocate_partner boolean
--
-- ROLLBACK:
--   Re-create the 9-arg version by re-applying
--   supabase/migrations/20260510010000_book_game_publish_gate.sql verbatim.
--   Doing so brings back the parallel 9-arg overload but does not touch
--   the 11-arg version installed by 20260511030000.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.book_game(
    UUID,      -- p_game_id
    UUID,      -- p_user_id
    BOOLEAN,   -- p_fee_paid
    TEXT,      -- p_stripe_pi_id
    TEXT,      -- p_payment_method
    INT,       -- p_platform_fee_cents
    INT,       -- p_club_payout_cents
    INT,       -- p_credits_applied_cents
    BOOLEAN    -- p_hold_for_payment
);
