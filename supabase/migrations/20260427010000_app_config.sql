-- app_config — server-authoritative key/value store for cross-platform runtime constants.
--
-- Clients (iOS, Android, Web) and Edge Functions read these values at bootstrap
-- so that timing and behaviour rules have a single source of truth in the DB.
--
-- Initial values:
--   game_reminder_offset_minutes = 120
--     T-2h push and local notification reminder offset.
--     Changing this value takes effect on the next cron tick and the next iOS app launch.
--     Must also update:
--       - game-reminder-2h Edge Function (reads at invocation via app_config)
--       - AppState.gameReminderOffsetMinutes constant (iOS bootstrap)
--       - pg_cron window in game-reminder-2h (centred ±15 min on this value)

CREATE TABLE IF NOT EXISTS app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  description TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS: all authenticated users can read; only service role can write.
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read app_config"
  ON app_config FOR SELECT
  USING (auth.role() = 'authenticated');

-- Seed the canonical timing constant.
INSERT INTO app_config (key, value, description)
VALUES (
  'game_reminder_offset_minutes',
  '120',
  'Minutes before game start to send the pre-game reminder push and local notification.'
)
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value,
      description = EXCLUDED.description,
      updated_at = now();
