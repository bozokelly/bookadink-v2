-- RLS policies for club_venues table.
--
-- club_venues had no RLS policies, causing INSERT/UPDATE/DELETE to return 403.
-- Four policies are needed:
--   SELECT  — all authenticated users (location displayed to all members)
--   INSERT  — club owner or club admin only
--   UPDATE  — club owner or club admin only
--   DELETE  — club owner or club admin only

ALTER TABLE club_venues ENABLE ROW LEVEL SECURITY;

-- SELECT: any authenticated user can read club venues
DROP POLICY IF EXISTS "Authenticated users can read club venues" ON club_venues;
CREATE POLICY "Authenticated users can read club venues"
  ON club_venues FOR SELECT
  USING (auth.role() = 'authenticated');

-- INSERT: club owner or club admin
DROP POLICY IF EXISTS "Club owner or admin can insert venues" ON club_venues;
CREATE POLICY "Club owner or admin can insert venues"
  ON club_venues FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM clubs
      WHERE clubs.id = club_venues.club_id
        AND clubs.created_by = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM club_admins
      WHERE club_admins.club_id = club_venues.club_id
        AND club_admins.user_id = auth.uid()
    )
  );

-- UPDATE: club owner or club admin
DROP POLICY IF EXISTS "Club owner or admin can update venues" ON club_venues;
CREATE POLICY "Club owner or admin can update venues"
  ON club_venues FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM clubs
      WHERE clubs.id = club_venues.club_id
        AND clubs.created_by = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM club_admins
      WHERE club_admins.club_id = club_venues.club_id
        AND club_admins.user_id = auth.uid()
    )
  );

-- DELETE: club owner or club admin
DROP POLICY IF EXISTS "Club owner or admin can delete venues" ON club_venues;
CREATE POLICY "Club owner or admin can delete venues"
  ON club_venues FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM clubs
      WHERE clubs.id = club_venues.club_id
        AND clubs.created_by = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM club_admins
      WHERE club_admins.club_id = club_venues.club_id
        AND club_admins.user_id = auth.uid()
    )
  );
