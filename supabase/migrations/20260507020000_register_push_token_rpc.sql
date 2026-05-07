-- Migration: register_push_token RPC for cross-user device-token reassignment
--
-- Why: when the same physical device signs out of user A and into user B, iOS
-- registers the same APNs token for user B. The direct PostgREST upsert with
-- `on_conflict=token` issues `UPDATE push_tokens SET user_id = <B>` against a
-- row currently owned by user A — and the RLS UPDATE policy on push_tokens is
-- `auth.uid() = user_id`, evaluated against the EXISTING row, so it blocks
-- with `new row violates row-level security policy for table "push_tokens"`.
-- Result: user B's iPad never persists its token.
--
-- Loosening RLS is wrong (it would let any authenticated user steal another
-- user's token row by guessing it). Instead we expose a SECURITY DEFINER RPC
-- that performs exactly the upsert we want — and only that upsert — running
-- as the function owner so it bypasses RLS, while still pinning the resulting
-- `user_id` to `auth.uid()`. Callers cannot pass a `user_id`; the only
-- parameter is the token itself.
--
-- Hard constraints:
-- * RLS on push_tokens is unchanged. Direct INSERT/UPDATE/DELETE from clients
--   still requires ownership — only this RPC can reassign a row.
-- * `user_id` is taken from `auth.uid()`, never from a parameter — a caller
--   cannot register a token under another user's account.
-- * Token globally unique (`push_tokens_token_unique`) is the conflict target.
-- * No other tables touched. No notification logic touched.

CREATE OR REPLACE FUNCTION public.register_push_token(p_token TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF p_token IS NULL OR length(trim(p_token)) = 0 THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;

  INSERT INTO public.push_tokens (user_id, token)
  VALUES (v_user_id, p_token)
  ON CONFLICT (token)
  DO UPDATE SET user_id = EXCLUDED.user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.register_push_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_push_token(TEXT) TO authenticated;

COMMENT ON FUNCTION public.register_push_token(TEXT) IS
  'Upserts caller''s APNs token into push_tokens. SECURITY DEFINER so a token row owned by a previous user on the same device can be reassigned to the current auth.uid() without weakening the table''s UPDATE RLS policy. user_id is bound to auth.uid() — callers cannot pass it.';
