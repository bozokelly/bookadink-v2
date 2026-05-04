-- 20260421_security_hardening.sql
-- Creates the rate_limit_log table used by Edge Function rate limiting.
-- Old rows are automatically purged every 15 minutes by pg_cron.

CREATE TABLE IF NOT EXISTS rate_limit_log (
  id         BIGSERIAL PRIMARY KEY,
  key        TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS rate_limit_log_key_ts_idx
  ON rate_limit_log (key, created_at);

-- Enable RLS and deny all direct access — only Edge Functions (service role) write here.
ALTER TABLE rate_limit_log ENABLE ROW LEVEL SECURITY;

-- Purge rows older than 1 hour every 15 minutes.
-- Requires pg_cron to be enabled in the Supabase Dashboard → Database → Extensions.
SELECT cron.schedule(
  'purge-rate-limit-log',
  '*/15 * * * *',
  $$ DELETE FROM rate_limit_log WHERE created_at < now() - INTERVAL '1 hour' $$
);
