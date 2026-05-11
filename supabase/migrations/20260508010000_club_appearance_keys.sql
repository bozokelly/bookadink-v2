-- Club appearance: HeroSurface palette + pattern selection
--
-- Adds two nullable text columns to `clubs` so club owners can pin a curated
-- HeroSurface palette and / or pattern. Both NULL means the club is in
-- "automatic" mode — the renderer derives a deterministic surface from
-- club.id. Either column being non-NULL locks that axis to the chosen value;
-- the other axis stays auto until it is also pinned.
--
-- The legacy `hero_image_key` column (preset banner illustrations) is
-- retained for one release as deprecated. Swift stops reading and writing it
-- as of this migration; existing rows with `hero_image_key` set will render
-- as automatic HeroSurface from now on (uploaded `custom_banner_url` rows
-- are unaffected and continue to render the user's banner). The column will
-- be dropped in a follow-up migration once production has rolled forward.
--
-- The two new columns are constrained to the curated enum values that the
-- iOS HeroSurfaces system supports. Note: `court` is intentionally NOT in
-- the pattern allow-list — it is excluded from user selection and from the
-- automatic rotation per the premium-direction brief.

ALTER TABLE clubs
  ADD COLUMN IF NOT EXISTS appearance_palette_key TEXT NULL,
  ADD COLUMN IF NOT EXISTS appearance_pattern_key TEXT NULL;

ALTER TABLE clubs
  DROP CONSTRAINT IF EXISTS clubs_appearance_palette_check;

ALTER TABLE clubs
  ADD CONSTRAINT clubs_appearance_palette_check
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
        'grain',
        'none'
      )
    );

COMMENT ON COLUMN clubs.appearance_palette_key IS
  'HeroSurface palette family pinned by the club owner. NULL = automatic (deterministic from club.id). Allowed: midnightNavy, graphiteCharcoal, emeraldForest, premiumTan, roseBurgundy, slateAtmosphere, plumNoir, deepTeal.';

COMMENT ON COLUMN clubs.appearance_pattern_key IS
  'HeroSurface pattern texture pinned by the club owner. NULL = automatic (deterministic from club.id). Allowed: diagonal, mesh, contour, bubbles, flow, grain, none. The court pattern is intentionally not selectable.';
