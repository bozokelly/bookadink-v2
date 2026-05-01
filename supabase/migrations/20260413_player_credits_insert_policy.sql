-- Allow users to INSERT their own credit row.
--
-- Required for the client-side issueCancellationCredit path:
-- when a cancellation refund is issued and no player_credits row exists yet
-- for that user+club, the iOS client INSERTs a new row with the refund amount.
-- The existing UPDATE policy handles subsequent increments.
--
-- Note: the existing SELECT and UPDATE policies already live in:
--   20260413_credits_bootstrap.sql (SELECT)
--   20260413_player_credits_update_policy.sql (UPDATE)

DROP POLICY IF EXISTS "Users can insert own credit rows" ON player_credits;
CREATE POLICY "Users can insert own credit rows"
  ON player_credits FOR INSERT
  WITH CHECK (auth.uid() = user_id AND amount_cents >= 0);
