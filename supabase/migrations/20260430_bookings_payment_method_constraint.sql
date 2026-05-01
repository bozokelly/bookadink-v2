-- Enforce canonical payment_method values on bookings.
--
-- Canonical set (matches all current Swift write paths):
--   'stripe'  — Stripe card/Apple Pay (createBooking, confirmPendingBooking, updateBookingPaymentMethod)
--   'admin'   — owner/admin manually added player (ownerCreateBooking, updateBookingPaymentMethod)
--   'cash'    — admin-recorded cash payment at check-in (updateBookingPaymentMethod)
--   'credits' — credits-only booking confirmation (confirmPendingBooking)
--   NULL      — free game, no payment collected
--
-- 'free' is a legacy non-canonical value written by early test code that no longer exists
-- in the codebase. It is normalised to NULL here before the constraint is added.

-- Step 1: normalise any legacy 'free' rows to NULL
UPDATE bookings
SET payment_method = NULL
WHERE payment_method = 'free';

-- Step 2: add CHECK constraint — rejects any future non-canonical value
ALTER TABLE bookings
  ADD CONSTRAINT bookings_payment_method_check
  CHECK (
    payment_method IS NULL
    OR payment_method IN ('stripe', 'admin', 'cash', 'credits')
  );
