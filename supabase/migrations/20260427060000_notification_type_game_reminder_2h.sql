-- Add game_reminder_2h, club_new_post, club_new_comment to notification_type enum.
-- game_reminder_2h replaces the misnamed game_reminder_24h (actual behaviour was always 2h).
-- club_new_post and club_new_comment were already handled in iOS but missing from the DB enum,
-- causing silent insert failures if any server-side code tried to use them.
--
-- NOTE: game_reminder_24h is intentionally kept in the enum for backward compatibility —
-- existing notification rows in the table retain their type value without error.
-- The Edge Function and iOS client have been updated to use game_reminder_2h going forward.

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'game_reminder_2h';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'club_new_post';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'club_new_comment';
