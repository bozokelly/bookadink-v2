-- ============================================================================
-- RLS Hardening — Enable Row Level Security on all public tables
-- ============================================================================
--
-- Fixes Supabase security warnings:
--   rls_disabled_in_public  — tables accessible without restriction
--   sensitive_columns_exposed — push tokens, Stripe keys, payments readable by anon
--
-- Strategy:
--   • Enable RLS on every public table (idempotent — no-op if already enabled)
--   • Drop and recreate all policies so this file is safe to re-run
--   • Tables already with RLS: player_credits, club_venues, club_entitlements, reviews
--     — their existing policies are preserved; we add any missing ones only
--   • clubs + club_members SELECT: allow anon role — iOS fetchClubs/fetchClubDetail
--     uses the anon key as its Authorization bearer (authBearerToken: nil falls back
--     to SupabaseConfig.anonKey in buildRequest). All write paths use auth tokens.
--   • All other tables: require authenticated role minimum
--   • Service-managed tables (club_stripe_accounts, club_subscriptions): SELECT for
--     owner/admin only; INSERT/UPDATE/DELETE handled exclusively by Edge Functions
--     via service_role (which bypasses RLS)
--   • SECURITY DEFINER RPCs (get_club_reviews, admin_update_member_dupr,
--     promote_waitlist_player, derive_club_entitlements) bypass RLS — no change needed
--
-- SAFE TO RE-RUN: all statements use DROP POLICY IF EXISTS + IF NOT EXISTS guards.
-- ============================================================================


-- ────────────────────────────────────────────────────────────────────────────
-- 1. profiles
-- ────────────────────────────────────────────────────────────────────────────
-- Sensitive columns: email, push_token (if present), full_name
-- Access: authenticated read needed for member directory, attendees, chat authors.
--         The app queries profiles with explicit select (id,full_name) for most paths;
--         admin moderation uses (id,full_name,email) — both remain authenticated-only.

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- SELECT: authenticated users can read profiles (member directory, attendee list, chat)
DROP POLICY IF EXISTS "Authenticated users can read profiles" ON profiles;
CREATE POLICY "Authenticated users can read profiles"
  ON profiles FOR SELECT
  USING (auth.role() = 'authenticated');

-- UPDATE: own profile only — WITH CHECK required (per CLAUDE.md: silently fails without it)
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING  (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- INSERT: own profile only
DROP POLICY IF EXISTS "Users can insert own profile" ON profiles;
CREATE POLICY "Users can insert own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);


-- ────────────────────────────────────────────────────────────────────────────
-- 2. clubs
-- ────────────────────────────────────────────────────────────────────────────
-- Note: iOS fetchClubs / fetchClubDetail use authBearerToken: nil → anon key.
--       SELECT must allow anon role to avoid breaking those calls.

ALTER TABLE clubs ENABLE ROW LEVEL SECURITY;

-- SELECT: public (anon + authenticated) — club discovery is intentionally open
DROP POLICY IF EXISTS "Public can read clubs" ON clubs;
CREATE POLICY "Public can read clubs"
  ON clubs FOR SELECT
  USING (true);

-- INSERT: authenticated users can create clubs (they become owner via created_by)
DROP POLICY IF EXISTS "Authenticated users can create clubs" ON clubs;
CREATE POLICY "Authenticated users can create clubs"
  ON clubs FOR INSERT
  WITH CHECK (auth.role() = 'authenticated' AND auth.uid() = created_by);

-- UPDATE: club owner or club admin
DROP POLICY IF EXISTS "Club owner or admin can update clubs" ON clubs;
CREATE POLICY "Club owner or admin can update clubs"
  ON clubs FOR UPDATE
  USING (
    auth.uid() = created_by
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = clubs.id AND user_id = auth.uid())
  )
  WITH CHECK (
    auth.uid() = created_by
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = clubs.id AND user_id = auth.uid())
  );

-- DELETE: club owner only
DROP POLICY IF EXISTS "Club owner can delete club" ON clubs;
CREATE POLICY "Club owner can delete club"
  ON clubs FOR DELETE
  USING (auth.uid() = created_by);


-- ────────────────────────────────────────────────────────────────────────────
-- 3. games
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE games ENABLE ROW LEVEL SECURITY;

-- SELECT: authenticated users (publish_at filtering handled at query level, not RLS)
DROP POLICY IF EXISTS "Authenticated users can read games" ON games;
CREATE POLICY "Authenticated users can read games"
  ON games FOR SELECT
  USING (auth.role() = 'authenticated');

-- INSERT: club owner or admin
DROP POLICY IF EXISTS "Club owner or admin can create games" ON games;
CREATE POLICY "Club owner or admin can create games"
  ON games FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM clubs WHERE id = games.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = games.club_id AND user_id = auth.uid())
  );

-- UPDATE: club owner or admin
DROP POLICY IF EXISTS "Club owner or admin can update games" ON games;
CREATE POLICY "Club owner or admin can update games"
  ON games FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = games.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = games.club_id AND user_id = auth.uid())
  );

-- DELETE: club owner or admin
DROP POLICY IF EXISTS "Club owner or admin can delete games" ON games;
CREATE POLICY "Club owner or admin can delete games"
  ON games FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = games.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = games.club_id AND user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 4. bookings
-- ────────────────────────────────────────────────────────────────────────────
-- Note: "Club members can read bookings for club games" policy was created by
--       20260407_bookings_member_read_policy.sql but RLS was never enabled.
--       Enabling RLS here activates that existing policy as well.

ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;

-- SELECT: own bookings
DROP POLICY IF EXISTS "Users can read own bookings" ON bookings;
CREATE POLICY "Users can read own bookings"
  ON bookings FOR SELECT
  USING (auth.uid() = user_id);

-- The "Club members can read bookings for club games" + "Club admins can read..." policies
-- from 20260407_bookings_member_read_policy.sql are preserved (DROP IF EXISTS is not called
-- on them here — they already exist and OR with the policy above).

-- INSERT: user books themselves
DROP POLICY IF EXISTS "Users can create own bookings" ON bookings;
CREATE POLICY "Users can create own bookings"
  ON bookings FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- INSERT: club owner/admin can book other players (ownerCreateBooking)
DROP POLICY IF EXISTS "Club owner or admin can create bookings for others" ON bookings;
CREATE POLICY "Club owner or admin can create bookings for others"
  ON bookings FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM games g
      JOIN clubs c ON c.id = g.club_id
      WHERE g.id = bookings.game_id AND c.created_by = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM games g
      JOIN club_admins ca ON ca.club_id = g.club_id
      WHERE g.id = bookings.game_id AND ca.user_id = auth.uid()
    )
  );

-- UPDATE: user can update own booking (cancel, confirm pending payment)
DROP POLICY IF EXISTS "Users can update own bookings" ON bookings;
CREATE POLICY "Users can update own bookings"
  ON bookings FOR UPDATE
  USING (auth.uid() = user_id);

-- UPDATE: club owner/admin can update any booking in their club
DROP POLICY IF EXISTS "Club owner or admin can update bookings" ON bookings;
CREATE POLICY "Club owner or admin can update bookings"
  ON bookings FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM games g
      JOIN clubs c ON c.id = g.club_id
      WHERE g.id = bookings.game_id AND c.created_by = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM games g
      JOIN club_admins ca ON ca.club_id = g.club_id
      WHERE g.id = bookings.game_id AND ca.user_id = auth.uid()
    )
  );

-- No DELETE — bookings use status = 'cancelled', never hard-deleted by clients


-- ────────────────────────────────────────────────────────────────────────────
-- 5. club_members
-- ────────────────────────────────────────────────────────────────────────────
-- Note: fetchClubs uses authBearerToken: nil (anon) to fetch member counts.
--       SELECT must allow anon role for the member count query.

ALTER TABLE club_members ENABLE ROW LEVEL SECURITY;

-- SELECT: public (anon + authenticated) — member counts shown on club cards
DROP POLICY IF EXISTS "Public can read club members" ON club_members;
CREATE POLICY "Public can read club members"
  ON club_members FOR SELECT
  USING (true);

-- INSERT: user can request own membership
DROP POLICY IF EXISTS "Users can request membership" ON club_members;
CREATE POLICY "Users can request membership"
  ON club_members FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- UPDATE: own membership (e.g., user updating their own record)
DROP POLICY IF EXISTS "Users can update own membership" ON club_members;
CREATE POLICY "Users can update own membership"
  ON club_members FOR UPDATE
  USING (auth.uid() = user_id);

-- UPDATE: club owner/admin approves, rejects, or modifies members
DROP POLICY IF EXISTS "Club owner or admin can update memberships" ON club_members;
CREATE POLICY "Club owner or admin can update memberships"
  ON club_members FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_members.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_members.club_id AND user_id = auth.uid())
  );

-- DELETE: user can leave a club
DROP POLICY IF EXISTS "Users can delete own membership" ON club_members;
CREATE POLICY "Users can delete own membership"
  ON club_members FOR DELETE
  USING (auth.uid() = user_id);

-- DELETE: club owner/admin can remove members
DROP POLICY IF EXISTS "Club owner or admin can delete memberships" ON club_members;
CREATE POLICY "Club owner or admin can delete memberships"
  ON club_members FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_members.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_members.club_id AND user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 6. club_admins
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE club_admins ENABLE ROW LEVEL SECURITY;

-- SELECT: own admin record (each admin can see their own status)
DROP POLICY IF EXISTS "Users can read own admin status" ON club_admins;
CREATE POLICY "Users can read own admin status"
  ON club_admins FOR SELECT
  USING (auth.uid() = user_id);

-- SELECT: club owner can read all admins in their club
DROP POLICY IF EXISTS "Club owner can read club admins" ON club_admins;
CREATE POLICY "Club owner can read club admins"
  ON club_admins FOR SELECT
  USING (EXISTS (SELECT 1 FROM clubs WHERE id = club_admins.club_id AND created_by = auth.uid()));

-- SELECT: club admins can see sibling admins (for coordination)
DROP POLICY IF EXISTS "Club admins can read sibling admins" ON club_admins;
CREATE POLICY "Club admins can read sibling admins"
  ON club_admins FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM club_admins ca
      WHERE ca.club_id = club_admins.club_id AND ca.user_id = auth.uid()
    )
  );

-- INSERT: club owner can add admins
DROP POLICY IF EXISTS "Club owner can insert club admins" ON club_admins;
CREATE POLICY "Club owner can insert club admins"
  ON club_admins FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM clubs WHERE id = club_admins.club_id AND created_by = auth.uid()));

-- UPDATE: club owner can update admin roles
DROP POLICY IF EXISTS "Club owner can update club admins" ON club_admins;
CREATE POLICY "Club owner can update club admins"
  ON club_admins FOR UPDATE
  USING (EXISTS (SELECT 1 FROM clubs WHERE id = club_admins.club_id AND created_by = auth.uid()));

-- DELETE: club owner can remove admins
DROP POLICY IF EXISTS "Club owner can delete club admins" ON club_admins;
CREATE POLICY "Club owner can delete club admins"
  ON club_admins FOR DELETE
  USING (EXISTS (SELECT 1 FROM clubs WHERE id = club_admins.club_id AND created_by = auth.uid()));

-- DELETE: users can remove their own admin record (e.g., when leaving the club)
-- removeMembership() strips the club_admins row for departing members via try?
DROP POLICY IF EXISTS "Users can delete own admin record" ON club_admins;
CREATE POLICY "Users can delete own admin record"
  ON club_admins FOR DELETE
  USING (auth.uid() = user_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 7. game_attendance
-- ────────────────────────────────────────────────────────────────────────────
-- Only club owner/admin performs check-in; players read their own attendance record.

ALTER TABLE game_attendance ENABLE ROW LEVEL SECURITY;

-- SELECT: own attendance record
DROP POLICY IF EXISTS "Users can read own attendance" ON game_attendance;
CREATE POLICY "Users can read own attendance"
  ON game_attendance FOR SELECT
  USING (auth.uid() = user_id);

-- SELECT: club owner/admin can read all attendance for games in their club
DROP POLICY IF EXISTS "Club owner or admin can read game attendance" ON game_attendance;
CREATE POLICY "Club owner or admin can read game attendance"
  ON game_attendance FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM games g
      JOIN clubs c ON c.id = g.club_id
      WHERE g.id = game_attendance.game_id AND c.created_by = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM games g
      JOIN club_admins ca ON ca.club_id = g.club_id
      WHERE g.id = game_attendance.game_id AND ca.user_id = auth.uid()
    )
  );

-- INSERT: club owner/admin does check-in (upsertAttendance)
DROP POLICY IF EXISTS "Club owner or admin can insert attendance" ON game_attendance;
CREATE POLICY "Club owner or admin can insert attendance"
  ON game_attendance FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM games g
      JOIN clubs c ON c.id = g.club_id
      WHERE g.id = game_attendance.game_id AND c.created_by = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM games g
      JOIN club_admins ca ON ca.club_id = g.club_id
      WHERE g.id = game_attendance.game_id AND ca.user_id = auth.uid()
    )
  );

-- UPDATE: club owner/admin updates attendance or payment status
DROP POLICY IF EXISTS "Club owner or admin can update attendance" ON game_attendance;
CREATE POLICY "Club owner or admin can update attendance"
  ON game_attendance FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM games g
      JOIN clubs c ON c.id = g.club_id
      WHERE g.id = game_attendance.game_id AND c.created_by = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM games g
      JOIN club_admins ca ON ca.club_id = g.club_id
      WHERE g.id = game_attendance.game_id AND ca.user_id = auth.uid()
    )
  );

-- DELETE: club owner/admin can undo a check-in (deleteAttendanceCheckIn)
DROP POLICY IF EXISTS "Club owner or admin can delete attendance" ON game_attendance;
CREATE POLICY "Club owner or admin can delete attendance"
  ON game_attendance FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM games g
      JOIN clubs c ON c.id = g.club_id
      WHERE g.id = game_attendance.game_id AND c.created_by = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM games g
      JOIN club_admins ca ON ca.club_id = g.club_id
      WHERE g.id = game_attendance.game_id AND ca.user_id = auth.uid()
    )
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 8. feed_posts  (club news / chat posts)
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE feed_posts ENABLE ROW LEVEL SECURITY;

-- SELECT: approved members, owner, or admin of the club
DROP POLICY IF EXISTS "Club members can read news posts" ON feed_posts;
CREATE POLICY "Club members can read news posts"
  ON feed_posts FOR SELECT
  USING (
    auth.role() = 'authenticated' AND (
      EXISTS (SELECT 1 FROM clubs WHERE id = feed_posts.club_id AND created_by = auth.uid())
      OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = feed_posts.club_id AND user_id = auth.uid())
      OR EXISTS (
        SELECT 1 FROM club_members
        WHERE club_id = feed_posts.club_id AND user_id = auth.uid() AND status = 'approved'
      )
    )
  );

-- INSERT: approved members (and owner/admin) can create posts
DROP POLICY IF EXISTS "Club members can create news posts" ON feed_posts;
CREATE POLICY "Club members can create news posts"
  ON feed_posts FOR INSERT
  WITH CHECK (
    auth.uid() = user_id AND (
      EXISTS (SELECT 1 FROM clubs WHERE id = feed_posts.club_id AND created_by = auth.uid())
      OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = feed_posts.club_id AND user_id = auth.uid())
      OR EXISTS (
        SELECT 1 FROM club_members
        WHERE club_id = feed_posts.club_id AND user_id = auth.uid() AND status = 'approved'
      )
    )
  );

-- UPDATE: post author can edit; owner/admin can moderate
DROP POLICY IF EXISTS "Post authors and club admins can update posts" ON feed_posts;
CREATE POLICY "Post authors and club admins can update posts"
  ON feed_posts FOR UPDATE
  USING (
    auth.uid() = user_id
    OR EXISTS (SELECT 1 FROM clubs WHERE id = feed_posts.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = feed_posts.club_id AND user_id = auth.uid())
  );

-- DELETE: post author or club admin/owner can delete
DROP POLICY IF EXISTS "Post authors and club admins can delete posts" ON feed_posts;
CREATE POLICY "Post authors and club admins can delete posts"
  ON feed_posts FOR DELETE
  USING (
    auth.uid() = user_id
    OR EXISTS (SELECT 1 FROM clubs WHERE id = feed_posts.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = feed_posts.club_id AND user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 9. feed_comments
-- ────────────────────────────────────────────────────────────────────────────
-- Joins through feed_posts to enforce club membership at the comment level.

ALTER TABLE feed_comments ENABLE ROW LEVEL SECURITY;

-- SELECT: club members of the post's parent club
DROP POLICY IF EXISTS "Club members can read comments" ON feed_comments;
CREATE POLICY "Club members can read comments"
  ON feed_comments FOR SELECT
  USING (
    auth.role() = 'authenticated' AND
    EXISTS (
      SELECT 1 FROM feed_posts fp
      WHERE fp.id = feed_comments.post_id AND (
        EXISTS (SELECT 1 FROM clubs WHERE id = fp.club_id AND created_by = auth.uid())
        OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = fp.club_id AND user_id = auth.uid())
        OR EXISTS (
          SELECT 1 FROM club_members
          WHERE club_id = fp.club_id AND user_id = auth.uid() AND status = 'approved'
        )
      )
    )
  );

-- INSERT: club members can comment
DROP POLICY IF EXISTS "Club members can create comments" ON feed_comments;
CREATE POLICY "Club members can create comments"
  ON feed_comments FOR INSERT
  WITH CHECK (
    auth.uid() = user_id AND
    EXISTS (
      SELECT 1 FROM feed_posts fp
      WHERE fp.id = feed_comments.post_id AND (
        EXISTS (SELECT 1 FROM clubs WHERE id = fp.club_id AND created_by = auth.uid())
        OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = fp.club_id AND user_id = auth.uid())
        OR EXISTS (
          SELECT 1 FROM club_members
          WHERE club_id = fp.club_id AND user_id = auth.uid() AND status = 'approved'
        )
      )
    )
  );

-- DELETE: comment author or club admin/owner (moderation)
DROP POLICY IF EXISTS "Comment authors and club admins can delete comments" ON feed_comments;
CREATE POLICY "Comment authors and club admins can delete comments"
  ON feed_comments FOR DELETE
  USING (
    auth.uid() = user_id
    OR EXISTS (
      SELECT 1 FROM feed_posts fp
      WHERE fp.id = feed_comments.post_id AND (
        EXISTS (SELECT 1 FROM clubs WHERE id = fp.club_id AND created_by = auth.uid())
        OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = fp.club_id AND user_id = auth.uid())
      )
    )
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 10. feed_reactions
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE feed_reactions ENABLE ROW LEVEL SECURITY;

-- SELECT: club members
DROP POLICY IF EXISTS "Club members can read reactions" ON feed_reactions;
CREATE POLICY "Club members can read reactions"
  ON feed_reactions FOR SELECT
  USING (
    auth.role() = 'authenticated' AND
    EXISTS (
      SELECT 1 FROM feed_posts fp
      WHERE fp.id = feed_reactions.post_id AND (
        EXISTS (SELECT 1 FROM clubs WHERE id = fp.club_id AND created_by = auth.uid())
        OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = fp.club_id AND user_id = auth.uid())
        OR EXISTS (
          SELECT 1 FROM club_members
          WHERE club_id = fp.club_id AND user_id = auth.uid() AND status = 'approved'
        )
      )
    )
  );

-- INSERT: club members can react (like toggle)
DROP POLICY IF EXISTS "Club members can create reactions" ON feed_reactions;
CREATE POLICY "Club members can create reactions"
  ON feed_reactions FOR INSERT
  WITH CHECK (
    auth.uid() = user_id AND
    EXISTS (
      SELECT 1 FROM feed_posts fp
      WHERE fp.id = feed_reactions.post_id AND (
        EXISTS (SELECT 1 FROM clubs WHERE id = fp.club_id AND created_by = auth.uid())
        OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = fp.club_id AND user_id = auth.uid())
        OR EXISTS (
          SELECT 1 FROM club_members
          WHERE club_id = fp.club_id AND user_id = auth.uid() AND status = 'approved'
        )
      )
    )
  );

-- DELETE: own reaction only (un-like toggle)
DROP POLICY IF EXISTS "Users can delete own reactions" ON feed_reactions;
CREATE POLICY "Users can delete own reactions"
  ON feed_reactions FOR DELETE
  USING (auth.uid() = user_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 11. club_messages  (moderation reports + internal system messages)
-- ────────────────────────────────────────────────────────────────────────────
-- Note: sender column is `sender_id`, not `user_id`, on this table.
--       Regular club chat lives in feed_posts/feed_comments (not here).
--       This table stores moderation reports (subject LIKE 'REPORT_%') and
--       other internal club-owner messages.

ALTER TABLE club_messages ENABLE ROW LEVEL SECURITY;

-- SELECT: club owner/admin can read all messages (including moderation reports)
DROP POLICY IF EXISTS "Club owner or admin can read club messages" ON club_messages;
CREATE POLICY "Club owner or admin can read club messages"
  ON club_messages FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_messages.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_messages.club_id AND user_id = auth.uid())
  );

-- INSERT: approved members (and owner/admin) can file moderation reports
DROP POLICY IF EXISTS "Club members can create club messages" ON club_messages;
CREATE POLICY "Club members can create club messages"
  ON club_messages FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id AND (
      EXISTS (SELECT 1 FROM clubs WHERE id = club_messages.club_id AND created_by = auth.uid())
      OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_messages.club_id AND user_id = auth.uid())
      OR EXISTS (
        SELECT 1 FROM club_members
        WHERE club_id = club_messages.club_id AND user_id = auth.uid() AND status = 'approved'
      )
    )
  );

-- UPDATE: club owner/admin (mark as read, etc.)
DROP POLICY IF EXISTS "Club owner or admin can update club messages" ON club_messages;
CREATE POLICY "Club owner or admin can update club messages"
  ON club_messages FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_messages.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_messages.club_id AND user_id = auth.uid())
  );

-- DELETE: club owner/admin resolves/dismisses moderation reports
DROP POLICY IF EXISTS "Club owner or admin can delete club messages" ON club_messages;
CREATE POLICY "Club owner or admin can delete club messages"
  ON club_messages FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_messages.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_messages.club_id AND user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 12. notifications
-- ────────────────────────────────────────────────────────────────────────────
-- INSERT is intentionally absent for authenticated clients — all notification
-- inserts are performed by Edge Functions (notify, send-review-prompts) via
-- service_role, which bypasses RLS.

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- SELECT: own notifications only
DROP POLICY IF EXISTS "Users can read own notifications" ON notifications;
CREATE POLICY "Users can read own notifications"
  ON notifications FOR SELECT
  USING (auth.uid() = user_id);

-- UPDATE: own notifications (mark as read)
DROP POLICY IF EXISTS "Users can update own notifications" ON notifications;
CREATE POLICY "Users can update own notifications"
  ON notifications FOR UPDATE
  USING (auth.uid() = user_id);

-- DELETE: own notifications (clear all — per CLAUDE.md requirement)
DROP POLICY IF EXISTS "Users can delete own notifications" ON notifications;
CREATE POLICY "Users can delete own notifications"
  ON notifications FOR DELETE
  USING (auth.uid() = user_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 13. push_tokens
-- ────────────────────────────────────────────────────────────────────────────
-- Highly sensitive — contains APNs device tokens. Strict own-record policies.

ALTER TABLE push_tokens ENABLE ROW LEVEL SECURITY;

-- SELECT: own tokens only
DROP POLICY IF EXISTS "Users can read own push tokens" ON push_tokens;
CREATE POLICY "Users can read own push tokens"
  ON push_tokens FOR SELECT
  USING (auth.uid() = user_id);

-- INSERT: upsert own token (iOS sends with merge-duplicates header)
DROP POLICY IF EXISTS "Users can upsert own push tokens" ON push_tokens;
CREATE POLICY "Users can upsert own push tokens"
  ON push_tokens FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- UPDATE: own token only
DROP POLICY IF EXISTS "Users can update own push tokens" ON push_tokens;
CREATE POLICY "Users can update own push tokens"
  ON push_tokens FOR UPDATE
  USING (auth.uid() = user_id);

-- DELETE: own token (e.g., on sign-out)
DROP POLICY IF EXISTS "Users can delete own push tokens" ON push_tokens;
CREATE POLICY "Users can delete own push tokens"
  ON push_tokens FOR DELETE
  USING (auth.uid() = user_id);


-- ────────────────────────────────────────────────────────────────────────────
-- 14. club_stripe_accounts
-- ────────────────────────────────────────────────────────────────────────────
-- Sensitive: contains Stripe Connect account IDs and payout status.
-- INSERT/UPDATE/DELETE handled exclusively by Edge Functions (stripe-webhook,
-- connect-onboarding) via service_role — no client write policies needed.

ALTER TABLE club_stripe_accounts ENABLE ROW LEVEL SECURITY;

-- SELECT: club owner or admin can read their club's Stripe account
DROP POLICY IF EXISTS "Club owner or admin can read stripe accounts" ON club_stripe_accounts;
CREATE POLICY "Club owner or admin can read stripe accounts"
  ON club_stripe_accounts FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_stripe_accounts.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_stripe_accounts.club_id AND user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 15. club_subscriptions
-- ────────────────────────────────────────────────────────────────────────────
-- Sensitive: contains Stripe subscription IDs, plan types, billing status.
-- INSERT/UPDATE/DELETE handled exclusively by Edge Functions (stripe-webhook,
-- create-club-subscription, cancel-club-subscription) via service_role.

ALTER TABLE club_subscriptions ENABLE ROW LEVEL SECURITY;

-- SELECT: club owner or admin
DROP POLICY IF EXISTS "Club owner or admin can read club subscriptions" ON club_subscriptions;
CREATE POLICY "Club owner or admin can read club subscriptions"
  ON club_subscriptions FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM clubs WHERE id = club_subscriptions.club_id AND created_by = auth.uid())
    OR EXISTS (SELECT 1 FROM club_admins WHERE club_id = club_subscriptions.club_id AND user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────────────────
-- 16. reviews — supplement existing policies
-- ────────────────────────────────────────────────────────────────────────────
-- reviews was set up per CLAUDE.md with ENABLE ROW LEVEL SECURITY + two policies.
-- This block is idempotent: ensures both required policies exist regardless of
-- whether the table was created via the CLAUDE.md SQL or a separate migration.

ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

-- INSERT: users can submit their own review
DROP POLICY IF EXISTS "Users can insert own reviews" ON reviews;
CREATE POLICY "Users can insert own reviews"
  ON reviews FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- SELECT: authenticated users can read all reviews (shown on club pages)
DROP POLICY IF EXISTS "Authenticated users can read reviews" ON reviews;
CREATE POLICY "Authenticated users can read reviews"
  ON reviews FOR SELECT
  USING (auth.role() = 'authenticated');


-- ────────────────────────────────────────────────────────────────────────────
-- 17. player_credits — supplement existing policies
-- ────────────────────────────────────────────────────────────────────────────
-- Already has RLS enabled with SELECT/UPDATE/INSERT policies from earlier
-- migrations. No new policies needed — existing policies are sufficient.
-- Enabling RLS here is idempotent (no-op if already enabled).

ALTER TABLE player_credits ENABLE ROW LEVEL SECURITY;
-- Existing policies from 20260413_credits_bootstrap.sql,
-- 20260413_player_credits_update_policy.sql,
-- 20260413_player_credits_insert_policy.sql are preserved.


-- ────────────────────────────────────────────────────────────────────────────
-- 18. club_venues — supplement existing policies
-- ────────────────────────────────────────────────────────────────────────────
-- Already has RLS enabled with full CRUD policies from 20260413_club_venues_rls.sql.
-- Idempotent re-enable.

ALTER TABLE club_venues ENABLE ROW LEVEL SECURITY;
-- Existing policies from 20260413_club_venues_rls.sql are preserved.


-- ────────────────────────────────────────────────────────────────────────────
-- 19. club_entitlements — supplement existing policies
-- ────────────────────────────────────────────────────────────────────────────
-- Already has RLS enabled with SELECT-only policies from 20260403_club_entitlements.sql.
-- Idempotent re-enable.

ALTER TABLE club_entitlements ENABLE ROW LEVEL SECURITY;
-- Existing SELECT policies for owner and admin are preserved.
-- No write policies needed — INSERT/UPDATE via derive_club_entitlements()
-- SECURITY DEFINER function called by Edge Functions only.
