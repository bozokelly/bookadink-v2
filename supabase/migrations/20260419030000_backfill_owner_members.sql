-- Backfill existing club owners into club_members as approved members.
-- The createClub flow already does this for new clubs, but clubs created
-- before that logic was added have no club_members row for the owner.
-- This is idempotent via ON CONFLICT DO NOTHING.

INSERT INTO club_members (club_id, user_id, status)
SELECT c.id, c.created_by, 'approved'
FROM clubs c
WHERE c.created_by IS NOT NULL
ON CONFLICT (club_id, user_id) DO NOTHING;
