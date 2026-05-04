-- Fix: Club members can read booking records for their club's games
--
-- PROBLEM:
--   fetchGameAttendees (iOS) queries bookings with the authenticated user JWT.
--   The existing SELECT policy is own-rows-only (auth.uid() = user_id), so
--   approved members see 0 attendees for any game they haven't personally booked.
--
--   fetchGames booking count query uses resolvedAccessToken() which can fall
--   back to the anon key at bootstrap, hitting a more permissive anon policy.
--   This causes confirmedCount (on the Game model) to be correct while the
--   live attendee fetch returns empty — the inconsistency the user sees:
--     "2 spots left" (correct, from baked-in confirmedCount)
--     "Players Registered (0)" (wrong, from RLS-empty attendee fetch)
--
-- FIX:
--   Add a second SELECT policy that allows approved club members and club admins
--   to read all booking records for games in their club.
--   The existing own-rows policy is retained (policies are OR'd by Postgres).
--
-- SAFETY:
--   Read-only. Does not change INSERT, UPDATE, DELETE policies.
--   Scoped to games g -> club membership/admin — no cross-club leakage.
--   Approved members can already see the player list in the iOS UI (canViewAttendees);
--   this makes the database enforce the same access that the app already grants.
--
-- RUN IN: Supabase Dashboard SQL Editor (as postgres / service_role).
-- SAFE TO RE-RUN: CREATE POLICY IF NOT EXISTS guard.

-- Drop if re-running to avoid duplicate policy error.
DROP POLICY IF EXISTS "Club members can read bookings for club games" ON bookings;

CREATE POLICY "Club members can read bookings for club games"
  ON bookings
  FOR SELECT
  USING (
    -- Approved club members can see all bookings for their club's games.
    EXISTS (
      SELECT 1
      FROM   games        g
      JOIN   club_members cm ON cm.club_id = g.club_id
      WHERE  g.id           = bookings.game_id
        AND  cm.user_id     = auth.uid()
        AND  cm.status      = 'approved'
    )
    OR
    -- Club admins can see all bookings for their club's games.
    EXISTS (
      SELECT 1
      FROM   games      g
      JOIN   club_admins ca ON ca.club_id = g.club_id
      WHERE  g.id          = bookings.game_id
        AND  ca.user_id    = auth.uid()
    )
  );
