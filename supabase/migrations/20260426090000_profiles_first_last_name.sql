-- Add first_name and last_name columns to profiles table.
-- full_name is kept as the compatibility display name.
-- Backfill: split existing full_name into first/last tokens for rows not yet populated.

ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS first_name TEXT,
    ADD COLUMN IF NOT EXISTS last_name  TEXT;

-- Safe backfill for existing rows that have full_name but no first/last yet.
UPDATE profiles
SET
    first_name = TRIM(SPLIT_PART(full_name, ' ', 1)),
    last_name  = TRIM(
        CASE
            WHEN POSITION(' ' IN TRIM(full_name)) > 0
            THEN SUBSTRING(TRIM(full_name) FROM POSITION(' ' IN TRIM(full_name)) + 1)
            ELSE ''
        END
    )
WHERE full_name IS NOT NULL
  AND full_name != ''
  AND first_name IS NULL;
