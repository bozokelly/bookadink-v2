-- Add hold_expires_at column to bookings table
--
-- PROBLEM:
--   fetchGameAttendees, fetchUserBookings, ownerCreateBooking, and several other
--   booking SELECT queries include hold_expires_at in their select strings.
--   The column does not exist in the database, causing PostgREST to return
--   HTTP 400: "column bookings.hold_expires_at does not exist".
--
--   This surfaces in the iOS app as:
--     - "Something went wrong loading data. Please try again." error banner
--     - Players list stuck at "Players Registered (0)" after booking
--     - "Book Your Spot" button remains visible after a successful booking
--       (because refreshBookings fails, so the user's booking state never updates)
--
-- PURPOSE OF THE COLUMN:
--   Stores the expiry timestamp for pending_payment bookings created during
--   the Stripe payment flow. A spot is held while the user completes payment;
--   hold_expires_at drives the countdown timer shown in GameDetailView.
--   NULL for free games and admin-created bookings.
--
-- SAFE TO RE-RUN: ADD COLUMN IF NOT EXISTS is idempotent.

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS hold_expires_at TIMESTAMPTZ NULL;
