-- Add club-level cancellation policy text and per-member acceptance tracking.
-- Mirrors the code_of_conduct / conduct_accepted_at pattern exactly.

ALTER TABLE clubs        ADD COLUMN IF NOT EXISTS cancellation_policy         TEXT;
ALTER TABLE club_members ADD COLUMN IF NOT EXISTS cancellation_policy_accepted_at TIMESTAMPTZ;
