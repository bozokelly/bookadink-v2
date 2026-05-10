-- Add explicit is_free flag to games so we can distinguish three pricing modes:
--   1. Free game           -> is_free = TRUE,  fee_amount IS NULL
--   2. Paid online         -> is_free = FALSE, fee_amount > 0      (requires Stripe-connected club)
--   3. Pay on arrival      -> is_free = FALSE, fee_amount IS NULL
--
-- Previously "Free" was inferred from fee_amount IS NULL OR fee_amount = 0 — that
-- conflated genuinely free games with games where the club intends to collect cash
-- on the day. Splitting these requires a dedicated column.
--
-- INTENTIONALLY NO BACKFILL of is_free = TRUE.
-- Existing no-price games (fee_amount IS NULL) cannot be assumed to have been
-- "explicitly free" — the admin never expressed that intent. Marking them all
-- Free would lock in a meaning they didn't choose. Instead, every existing row
-- defaults to is_free = FALSE, which under the new model renders as
-- "Pay on arrival" — a neutral, accurate description until the admin opens
-- Edit Game and explicitly toggles Free.

ALTER TABLE games
    ADD COLUMN IF NOT EXISTS is_free BOOLEAN NOT NULL DEFAULT FALSE;

-- Invariant: a game cannot simultaneously be marked free and carry a positive fee.
ALTER TABLE games
    DROP CONSTRAINT IF EXISTS games_is_free_no_fee;

ALTER TABLE games
    ADD CONSTRAINT games_is_free_no_fee
        CHECK (NOT (is_free = TRUE AND fee_amount IS NOT NULL AND fee_amount > 0));
