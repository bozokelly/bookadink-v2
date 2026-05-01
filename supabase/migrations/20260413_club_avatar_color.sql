-- Add avatar_background_color column to clubs table.
-- Stores a hex color string (e.g. "#2E7D5B") chosen by the club owner
-- for the initials-based avatar background when no custom photo is uploaded.
-- NULL means use the deterministic hash-based color derived from the club name.

ALTER TABLE clubs ADD COLUMN IF NOT EXISTS avatar_background_color TEXT NULL;
