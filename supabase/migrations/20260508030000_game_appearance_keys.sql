-- Game appearance: HeroSurface palette + pattern selection per game
--
-- Mirrors the club-level appearance system (`clubs.appearance_palette_key`
-- / `clubs.appearance_pattern_key`) so admins can pin a curated visual
-- style to a game — typically used to make recurring sessions visually
-- recognisable ("Wednesday night = teal / mesh"). Both NULL means the
-- game renders with HeroSurface auto-rotation deterministically seeded
-- from `games.id`.
--
-- The CHECK allow-lists must stay in sync with the club-side allow-lists
-- (last updated by `20260508020000_club_appearance_pattern_grain_to_coral.sql`):
-- 8 palette families and 7 selectable patterns. The `court` pattern is
-- intentionally excluded from selection and from auto-rotation per the
-- premium-direction brief.

ALTER TABLE games
  ADD COLUMN IF NOT EXISTS appearance_palette_key TEXT NULL,
  ADD COLUMN IF NOT EXISTS appearance_pattern_key TEXT NULL;

ALTER TABLE games
  DROP CONSTRAINT IF EXISTS games_appearance_palette_check;

ALTER TABLE games
  ADD CONSTRAINT games_appearance_palette_check
    CHECK (
      appearance_palette_key IS NULL
      OR appearance_palette_key IN (
        'midnightNavy',
        'graphiteCharcoal',
        'emeraldForest',
        'premiumTan',
        'roseBurgundy',
        'slateAtmosphere',
        'plumNoir',
        'deepTeal'
      )
    );

ALTER TABLE games
  DROP CONSTRAINT IF EXISTS games_appearance_pattern_check;

ALTER TABLE games
  ADD CONSTRAINT games_appearance_pattern_check
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

COMMENT ON COLUMN games.appearance_palette_key IS
  'HeroSurface palette family pinned for this game. NULL = automatic (deterministic from games.id). Allowed values must match the club-side allow-list.';

COMMENT ON COLUMN games.appearance_pattern_key IS
  'HeroSurface pattern texture pinned for this game. NULL = automatic. The court pattern is intentionally not selectable.';
