-- ─────────────────────────────────────────────────────────────────────────────
-- Chat privacy fix — drop permissive SELECT policies on feed_posts /
-- feed_comments / feed_reactions so non-members cannot read club chat.
--
-- PROBLEM:
--   feed_posts / feed_comments / feed_reactions each had two SELECT policies
--   whose `USING` qualifier was the literal `true`:
--     - "Anyone authenticated can read feed posts"
--     - "Feed posts public read"
--     (mirror pair on feed_comments and feed_reactions)
--
--   PostgreSQL OR-combines RLS policies. The membership-gated policies
--   added later ("Club members can read news posts", "Users can read club
--   posts", "Club members can read comments", "Club members can read
--   reactions") were entirely shadowed — any authenticated caller could
--   read every club's chat.
--
-- THIS MIGRATION:
--   Drops the six permissive policies. The remaining membership-gated
--   policies become authoritative.
--
-- INVARIANTS PRESERVED:
--   - Approved members + owners + club_admins continue to read posts /
--     comments / reactions for their clubs (via the gated policies that
--     were already in place).
--   - INSERT / UPDATE / DELETE policies on all three tables are
--     untouched.
--   - SECURITY DEFINER functions (e.g. get_club_reviews, any future
--     read RPC) bypass RLS and are unaffected.
--   - iOS fetchClubNewsPosts uses an authenticated bearer, so an
--     approved member's read returns the same rows as today.
--
-- VERIFICATION AFTER APPLY:
--   -- Exactly the four remaining SELECT policies should be present:
--   SELECT tablename, policyname
--     FROM pg_policies
--    WHERE tablename IN ('feed_posts','feed_comments','feed_reactions')
--      AND cmd = 'SELECT'
--    ORDER BY tablename, policyname;
--   --   feed_comments  | Club members can read comments
--   --   feed_posts     | Club members can read news posts
--   --   feed_posts     | Users can read club posts
--   --   feed_reactions | Club members can read reactions
--
-- ROLLBACK:
--   BEGIN;
--     CREATE POLICY "Anyone authenticated can read feed posts"
--       ON public.feed_posts FOR SELECT USING (true);
--     CREATE POLICY "Feed posts public read"
--       ON public.feed_posts FOR SELECT USING (true);
--     CREATE POLICY "Anyone authenticated can read comments"
--       ON public.feed_comments FOR SELECT USING (true);
--     CREATE POLICY "Feed comments public read"
--       ON public.feed_comments FOR SELECT USING (true);
--     CREATE POLICY "Anyone authenticated can read reactions"
--       ON public.feed_reactions FOR SELECT USING (true);
--     CREATE POLICY "Feed reactions public read"
--       ON public.feed_reactions FOR SELECT USING (true);
--   COMMIT;
-- ─────────────────────────────────────────────────────────────────────────────

BEGIN;

DROP POLICY IF EXISTS "Anyone authenticated can read feed posts" ON public.feed_posts;
DROP POLICY IF EXISTS "Feed posts public read"                   ON public.feed_posts;

DROP POLICY IF EXISTS "Anyone authenticated can read comments"   ON public.feed_comments;
DROP POLICY IF EXISTS "Feed comments public read"                ON public.feed_comments;

DROP POLICY IF EXISTS "Anyone authenticated can read reactions"  ON public.feed_reactions;
DROP POLICY IF EXISTS "Feed reactions public read"               ON public.feed_reactions;

COMMIT;
