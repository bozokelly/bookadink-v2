-- player_credits UPDATE RLS policy
--
-- Required for the iOS credit deduction path, which uses a direct PostgREST
-- PATCH on player_credits instead of the use_credits RPC.
-- (The RPC exists but PostgREST schema-cache on Supabase hosted does not
-- reliably pick up newly created functions — direct table PATCH is used instead.)
--
-- The CHECK (amount_cents >= 0) mirrors the table-level CHECK constraint and
-- prevents any client-crafted PATCH from setting a negative balance.
-- Safe to re-run: DROP POLICY IF EXISTS before CREATE.

DROP POLICY IF EXISTS "Users can update own credits" ON player_credits;

CREATE POLICY "Users can update own credits"
  ON player_credits
  FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id AND amount_cents >= 0);
