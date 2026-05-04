-- Add attendance_status to game_attendance table
--
-- PROBLEM:
--   Attendance is currently binary: a row in game_attendance = "attended",
--   no row = "not checked in". There is no way to explicitly mark a player
--   as "no show" vs "unmarked". Both states look identical in the database.
--
-- FIX:
--   Add attendance_status TEXT column with two allowed values:
--     'attended'  — player was present (existing rows retain this value)
--     'no_show'   — player did not show up (new, explicit state)
--   "Unmarked" is represented by the absence of a row (unchanged).
--
-- BACKWARD COMPAT:
--   DEFAULT 'attended' means every existing row is correctly migrated to attended.
--   No data loss. No row deletions. iOS app logic that reads presence-of-row
--   continues to work until the new column is read.
--
-- SAFE TO RE-RUN: ADD COLUMN IF NOT EXISTS is idempotent.

ALTER TABLE game_attendance
  ADD COLUMN IF NOT EXISTS attendance_status TEXT NOT NULL DEFAULT 'attended'
  CHECK (attendance_status IN ('attended', 'no_show'));
