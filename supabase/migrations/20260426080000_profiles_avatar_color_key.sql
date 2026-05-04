-- Add avatar_color_key column to profiles for player avatar colour selection.
-- Stores a named palette key (e.g. 'electric_blue') from the Neon Accent Series.
-- NULL means use the deterministic fallback based on initials hash.

ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS avatar_color_key TEXT NULL;
