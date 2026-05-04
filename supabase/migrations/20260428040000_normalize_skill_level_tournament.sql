-- Normalize legacy 'tournament' and title-case skill_level values in games and profiles.
-- The canonical DB values are: all, beginner, intermediate, advanced (lowercase only).
-- 'tournament' was a client-only iOS enum case that was never a valid DB value.

-- games.skill_level — normalize any legacy rows
UPDATE games
SET skill_level = 'advanced'
WHERE lower(skill_level) = 'tournament';

-- Normalize any stale title-case values written before the enum fix
UPDATE games
SET skill_level = lower(skill_level)
WHERE skill_level IN ('All', 'Beginner', 'Intermediate', 'Advanced')
  AND lower(skill_level) != skill_level;

-- profiles.skill_level — same normalization (column exists, was not enforced)
UPDATE profiles
SET skill_level = 'advanced'
WHERE lower(skill_level) = 'tournament';

UPDATE profiles
SET skill_level = lower(skill_level)
WHERE skill_level IN ('All', 'Beginner', 'Intermediate', 'Advanced')
  AND lower(skill_level) != skill_level;
