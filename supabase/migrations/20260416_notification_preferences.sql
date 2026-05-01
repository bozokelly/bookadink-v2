-- notification_preferences
-- Per-user opt-in/out for push and email notifications by category.
-- A missing row means all defaults (true) apply — fetched as nil → iOS defaults to all on.

CREATE TABLE IF NOT EXISTS notification_preferences (
  user_id                 UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  booking_confirmed_push  BOOL NOT NULL DEFAULT true,
  booking_confirmed_email BOOL NOT NULL DEFAULT true,
  new_game_push           BOOL NOT NULL DEFAULT true,
  new_game_email          BOOL NOT NULL DEFAULT true,
  waitlist_push           BOOL NOT NULL DEFAULT true,
  waitlist_email          BOOL NOT NULL DEFAULT true,
  chat_push               BOOL NOT NULL DEFAULT true,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;

-- Users can read their own preferences
CREATE POLICY "Users can select own notification_preferences"
  ON notification_preferences FOR SELECT
  USING (auth.uid() = user_id);

-- Users can insert their own preferences row
CREATE POLICY "Users can insert own notification_preferences"
  ON notification_preferences FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Users can update their own preferences
CREATE POLICY "Users can update own notification_preferences"
  ON notification_preferences FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
