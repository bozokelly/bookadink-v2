-- Canonical avatar palette definitions — single source of truth for all platforms.
-- iOS, Android, and Web resolve avatar gradients by palette_key only.
-- Clients never independently compute or assign a colour; they only render what the DB defines.

CREATE TABLE IF NOT EXISTS avatar_palettes (
    palette_key        TEXT PRIMARY KEY,
    palette_name       TEXT NOT NULL,
    category           TEXT NOT NULL CHECK (category IN ('premium_dark', 'neon_accent', 'soft_luxury')),
    gradient_start_hex TEXT NOT NULL CHECK (gradient_start_hex ~ '^[0-9A-Fa-f]{6}$'),
    gradient_end_hex   TEXT NOT NULL CHECK (gradient_end_hex ~ '^[0-9A-Fa-f]{6}$'),
    is_default         BOOLEAN NOT NULL DEFAULT FALSE,
    is_active          BOOLEAN NOT NULL DEFAULT TRUE,
    display_order      INT NOT NULL DEFAULT 0
);

-- Only one palette may be marked as the platform-neutral default fallback.
CREATE UNIQUE INDEX IF NOT EXISTS avatar_palettes_single_default_idx
    ON avatar_palettes (is_default) WHERE is_default = TRUE;

ALTER TABLE avatar_palettes ENABLE ROW LEVEL SECURITY;

-- Read-only for all authenticated users; admin DML only via service-role key.
CREATE POLICY "Authenticated users can read active palettes"
    ON avatar_palettes FOR SELECT
    USING (auth.role() = 'authenticated' AND is_active = TRUE);

-- ── Seed canonical palette data ───────────────────────────────────────────────
INSERT INTO avatar_palettes
    (palette_key, palette_name, category, gradient_start_hex, gradient_end_hex, is_default, is_active, display_order)
VALUES
    -- Premium Dark Series — high contrast, white-text safe.
    -- midnight_navy is the authoritative default for all platforms when no palette_key is stored.
    ('midnight_navy',  'Midnight Navy',  'premium_dark', '0B1F3A', '1E3A5F', TRUE,  TRUE, 10),
    ('deep_forest',    'Deep Forest',    'premium_dark', '0F3D2E', '1E5A45', FALSE, TRUE, 11),
    ('plum_noir',      'Plum Noir',      'premium_dark', '2B1638', '4A2A5E', FALSE, TRUE, 12),
    ('espresso',       'Espresso',       'premium_dark', '3A2418', '5C3A28', FALSE, TRUE, 13),
    ('obsidian',       'Obsidian',       'premium_dark', '111111', '2A2A2A', FALSE, TRUE, 14),
    ('graphite',       'Graphite',       'premium_dark', '1E1E1E', '3B3B3B', FALSE, TRUE, 15),
    -- Neon Accent Series — vibrant, white-text safe, offered to players.
    ('neon_lime',      'Neon Lime',      'neon_accent',  '80FF00', '3A7D00', FALSE, TRUE, 20),
    ('electric_blue',  'Electric Blue',  'neon_accent',  '0066FF', '00A3FF', FALSE, TRUE, 21),
    ('neon_violet',    'Neon Violet',    'neon_accent',  '7B2DFF', 'B066FF', FALSE, TRUE, 22),
    ('sunset_ember',   'Sunset Ember',   'neon_accent',  'FF5A36', 'FF8A3D', FALSE, TRUE, 23),
    ('aqua_pulse',     'Aqua Pulse',     'neon_accent',  '00C2A8', '007D73', FALSE, TRUE, 24),
    ('hot_magenta',    'Hot Magenta',    'neon_accent',  'D726FF', '7B2DFF', FALSE, TRUE, 25),
    -- Soft Luxury Series — refined, white-text safe, offered to clubs.
    ('sandstone',      'Sandstone',      'soft_luxury',  'C7A97A', '8F6F42', FALSE, TRUE, 30),
    ('sage',           'Sage',           'soft_luxury',  '7E9F88', '51755F', FALSE, TRUE, 31),
    ('frost_blue',     'Frost Blue',     'soft_luxury',  '4B6FA5', '2E4E7A', FALSE, TRUE, 32),
    ('dusty_rose',     'Dusty Rose',     'soft_luxury',  'B76A7D', '8A4356', FALSE, TRUE, 33),
    ('silver_mist',    'Silver Mist',    'soft_luxury',  '6B7280', '374152', FALSE, TRUE, 34),
    ('soft_lavender',  'Soft Lavender',  'soft_luxury',  '7B68AC', '4A3C7A', FALSE, TRUE, 35)
ON CONFLICT (palette_key) DO NOTHING;

-- ── Foreign key constraints ───────────────────────────────────────────────────
-- NOT VALID: enforced only on future writes. Existing rows (incl. legacy hex values in
-- clubs.avatar_background_color) are not retroactively validated. New saves must use a
-- valid palette_key from this table.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'profiles_avatar_color_key_fk'
    ) THEN
        ALTER TABLE profiles
            ADD CONSTRAINT profiles_avatar_color_key_fk
            FOREIGN KEY (avatar_color_key)
            REFERENCES avatar_palettes(palette_key)
            ON DELETE SET NULL ON UPDATE CASCADE
            NOT VALID;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'clubs_avatar_background_color_fk'
    ) THEN
        ALTER TABLE clubs
            ADD CONSTRAINT clubs_avatar_background_color_fk
            FOREIGN KEY (avatar_background_color)
            REFERENCES avatar_palettes(palette_key)
            ON DELETE SET NULL ON UPDATE CASCADE
            NOT VALID;
    END IF;
END $$;
