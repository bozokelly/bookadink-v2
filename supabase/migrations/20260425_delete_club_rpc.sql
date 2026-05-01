-- Safe club deletion RPC
--
-- Deletes a club and all its child records in dependency order.
-- SECURITY DEFINER so it runs as postgres, bypassing per-table RLS on child rows.
-- Caller must be the club owner (created_by check enforced inside the function).
--
-- Called from iOS instead of a direct DELETE on clubs, which fails when FK
-- constraints on child tables (games, club_members, etc.) lack ON DELETE CASCADE.

CREATE OR REPLACE FUNCTION delete_club(p_club_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_owner_id  UUID;
BEGIN
  -- Verify caller owns the club
  SELECT created_by INTO v_owner_id FROM clubs WHERE id = p_club_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_caller_id IS DISTINCT FROM v_owner_id THEN
    RAISE EXCEPTION 'Only the club owner can delete this club' USING ERRCODE = '42501';
  END IF;

  -- 1. Bookings (FK → games)
  DELETE FROM bookings
  WHERE game_id IN (SELECT id FROM games WHERE club_id = p_club_id);

  -- 2. Game attendance rows (FK → games)
  DELETE FROM game_attendance
  WHERE game_id IN (SELECT id FROM games WHERE club_id = p_club_id);

  -- 3. Reviews (FK → games — must be before games delete)
  DELETE FROM reviews
  WHERE game_id IN (SELECT id FROM games WHERE club_id = p_club_id);

  -- 4. Games
  DELETE FROM games WHERE club_id = p_club_id;

  -- 5. Feed comments → posts
  DELETE FROM feed_comments
  WHERE post_id IN (SELECT id FROM feed_posts WHERE club_id = p_club_id);

  -- 6. Feed reactions → posts
  DELETE FROM feed_reactions
  WHERE post_id IN (SELECT id FROM feed_posts WHERE club_id = p_club_id);

  -- 7. Feed posts
  DELETE FROM feed_posts WHERE club_id = p_club_id;

  -- 8. Memberships / join requests
  DELETE FROM club_members   WHERE club_id = p_club_id;
  DELETE FROM club_admins    WHERE club_id = p_club_id;

  -- 9. Player credits for this club
  DELETE FROM player_credits WHERE club_id = p_club_id;

  -- 10. Club venues
  DELETE FROM club_venues    WHERE club_id = p_club_id;

  -- 12. Entitlements (has ON DELETE CASCADE but explicit is safer)
  DELETE FROM club_entitlements WHERE club_id = p_club_id;

  -- 13. Finally, the club itself
  DELETE FROM clubs WHERE id = p_club_id;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_club(UUID) TO authenticated;
