-- Stage 4: Primary venue as club location source of truth.
--
-- Three safe steps:
--   1. Deduplicate: if a club somehow has multiple is_primary=true venues,
--      keep the one with the best coordinates (non-null lat+lng first, then
--      earliest created_at). Set all others to is_primary=false.
--
--   2. Elect: for clubs that have venue rows but none marked primary,
--      elect the best candidate (coordinates preferred, then oldest row).
--
--   3. Backfill: for clubs with no venue rows at all, create one venue
--      from the club's existing address fields and mark it primary.
--      Clubs with no useful address data are skipped.

-- ── Step 1: Deduplicate multiple primary venues ────────────────────────────

WITH ranked AS (
  SELECT
    id,
    club_id,
    ROW_NUMBER() OVER (
      PARTITION BY club_id
      ORDER BY
        -- Prefer venues that already have coordinates
        CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL THEN 0 ELSE 1 END,
        created_at ASC NULLS LAST
    ) AS rn
  FROM club_venues
  WHERE is_primary = true
)
UPDATE club_venues
SET is_primary = false
WHERE id IN (
  SELECT id FROM ranked WHERE rn > 1
);

-- ── Step 2: Elect a primary for clubs with venues but no primary set ───────

WITH candidate AS (
  SELECT DISTINCT ON (club_id)
    id,
    club_id
  FROM club_venues
  ORDER BY
    club_id,
    CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL THEN 0 ELSE 1 END,
    created_at ASC NULLS LAST
)
UPDATE club_venues cv
SET is_primary = true
FROM candidate c
WHERE cv.id = c.id
  AND cv.club_id IN (
    -- Only for clubs that have at least one venue but no primary
    SELECT club_id
    FROM club_venues
    GROUP BY club_id
    HAVING COUNT(*) FILTER (WHERE is_primary = true) = 0
  );

-- ── Step 3: Backfill venues for clubs with no venue rows ──────────────────

INSERT INTO club_venues (
  id,
  club_id,
  venue_name,
  street_address,
  suburb,
  state,
  postcode,
  country,
  is_primary,
  latitude,
  longitude
)
SELECT
  gen_random_uuid(),
  c.id,
  -- Use venue_name if set, otherwise fall back to club name
  COALESCE(NULLIF(TRIM(c.venue_name), ''), c.name),
  NULLIF(TRIM(c.street_address), ''),
  NULLIF(TRIM(c.suburb), ''),
  NULLIF(TRIM(c.state), ''),
  NULLIF(TRIM(c.postcode), ''),
  COALESCE(NULLIF(TRIM(c.country), ''), 'Australia'),
  true,
  c.latitude,
  c.longitude
FROM clubs c
WHERE
  -- Only for clubs with no venue rows at all
  NOT EXISTS (
    SELECT 1 FROM club_venues cv WHERE cv.club_id = c.id
  )
  -- Only if there is at least some address data worth backfilling
  AND (
    (c.venue_name    IS NOT NULL AND TRIM(c.venue_name)    != '') OR
    (c.street_address IS NOT NULL AND TRIM(c.street_address) != '') OR
    (c.suburb        IS NOT NULL AND TRIM(c.suburb)        != '')
  );
