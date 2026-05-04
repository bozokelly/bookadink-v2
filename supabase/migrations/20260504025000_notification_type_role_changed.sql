-- Add 'role_changed' to the notification_type enum.
-- Used by supabase/functions/role-change-push to insert in-app notifications
-- when a user's role in a club changes (promoted/demoted/transferred). The
-- enum value must exist BEFORE 20260504030000_role_audit_and_logging.sql can
-- be safely applied — ALTER TYPE ADD VALUE cannot be referenced in the same
-- transaction that adds it (Postgres rule), so this lives in its own migration
-- ordered before the audit/push migration.

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'role_changed';
