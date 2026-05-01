-- Add new_game to notification_type enum
--
-- Required by the game-published-notify Edge Function, which inserts
-- notifications with type = 'new_game' when a game is published immediately.
--
-- IF NOT EXISTS prevents an error if the value already exists (PostgreSQL 9.6+).

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'new_game';
