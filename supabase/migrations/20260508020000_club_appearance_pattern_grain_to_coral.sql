-- Club appearance: rename 'grain' pattern → 'coral'
--
-- The previous `grain` texture was a deterministic 1px dot field; visually
-- it ended up indistinguishable from `none` (Minimal) at the canonical
-- 0.04–0.05 white-opacity overlay weight. The slot is being repurposed
-- for a Truchet-style winding pattern under the friendly label "Coral".
--
-- Migration steps:
--   1. Rewrite any existing pinned values from 'grain' to 'coral' so
--      clubs that already pinned the texture keep their selection (only
--      the visual changes; the slot stays).
--   2. Replace the CHECK constraint allow-list, swapping 'grain' for
--      'coral'. All other curated values are preserved exactly.

UPDATE clubs
SET appearance_pattern_key = 'coral'
WHERE appearance_pattern_key = 'grain';

ALTER TABLE clubs
  DROP CONSTRAINT IF EXISTS clubs_appearance_pattern_check;

ALTER TABLE clubs
  ADD CONSTRAINT clubs_appearance_pattern_check
    CHECK (
      appearance_pattern_key IS NULL
      OR appearance_pattern_key IN (
        'diagonal',
        'mesh',
        'contour',
        'bubbles',
        'flow',
        'coral',
        'none'
      )
    );

COMMENT ON COLUMN clubs.appearance_pattern_key IS
  'HeroSurface pattern texture pinned by the club owner. NULL = automatic (deterministic from club.id). Allowed: diagonal, mesh, contour, bubbles, flow, coral, none. The court pattern is intentionally not selectable.';
