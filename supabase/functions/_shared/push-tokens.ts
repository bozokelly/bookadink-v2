// _shared/push-tokens.ts
// Multi-device APNs token resolution.
//
// History: every push-sending Edge Function originally read profiles.push_token
// (a single TEXT column on the user's profile). When a user signed in on a
// second device the new device's token overwrote the first, so only the
// most-recently-registered device received pushes. iOS already writes each
// device's token to the multi-row push_tokens table (Services/SupabaseService.swift),
// but until 2026-05-05 no sender read from it.
//
// This helper is the single read path. Senders pass the target user_id and
// receive every active token to fan out to. profiles.push_token is honoured
// as a fallback so users who haven't re-registered yet (push_tokens empty)
// continue to receive pushes — that path is removed in a follow-up once all
// senders are on the helper and iOS no longer writes the legacy column.

// deno-lint-ignore no-explicit-any
type SupabaseClient = any;

export interface PushTokensResolution {
  /// All distinct, non-empty APNs tokens to fan out to.
  tokens: string[];
  /// True iff push_tokens had no rows for this user and we used profiles.push_token.
  fallbackUsed: boolean;
}

/// Returns every APNs device token registered for `userID`.
///
/// Read order:
///   1. push_tokens (multi-row; one per device).
///   2. profiles.push_token (legacy single column) — fallback only.
///
/// De-dupes case-insensitively on the token string. Empty/whitespace tokens
/// are dropped. Errors querying push_tokens are logged but the function still
/// attempts the legacy fallback so a transient row-table failure does not
/// silently swallow all pushes for the user.
export async function getPushTokensForUser(
  supabase: SupabaseClient,
  userID: string,
): Promise<PushTokensResolution> {
  const collected: string[] = [];

  const { data: rows, error: rowsError } = await supabase
    .from("push_tokens")
    .select("token")
    .eq("user_id", userID);

  if (rowsError) {
    console.error("[push-tokens] push_tokens query failed:", rowsError.message ?? rowsError);
  } else if (rows) {
    for (const r of rows as Array<{ token: string | null }>) {
      const t = (r.token ?? "").trim();
      if (t) collected.push(t);
    }
  }

  let fallbackUsed = false;
  if (collected.length === 0) {
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("push_token")
      .eq("id", userID)
      .single();
    if (profileError && profileError.code !== "PGRST116") {
      console.error("[push-tokens] profiles fallback query failed:", profileError.message ?? profileError);
    }
    const legacy = (((profile?.push_token as string | undefined) ?? "")).trim();
    if (legacy) {
      collected.push(legacy);
      fallbackUsed = true;
    }
  }

  const seen = new Set<string>();
  const tokens: string[] = [];
  for (const t of collected) {
    const key = t.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    tokens.push(t);
  }

  return { tokens, fallbackUsed };
}

/// Compact form for log lines — never log the full APNs token.
export function tokenShort(token: string): string {
  if (token.length < 12) return "(short)";
  return `${token.slice(0, 6)}…${token.slice(-6)}`;
}

/// Drops a single APNs token after APNs returned 410 Gone (token unregistered).
///
/// - Always deletes the matching push_tokens row (scoped by user_id + token).
/// - profiles.push_token is NULLed only when it equals the stale token, so an
///   unrelated still-valid legacy token on the profile row is preserved.
///
/// Errors here are non-fatal — logged and swallowed. The push attempt has
/// already failed; clearing the dead token is best-effort cleanup.
export async function clearStaleToken(
  supabase: SupabaseClient,
  userID: string,
  token: string,
): Promise<{ removedFromTable: boolean; clearedOnProfile: boolean }> {
  let removedFromTable = false;
  let clearedOnProfile = false;

  const { error: delError } = await supabase
    .from("push_tokens")
    .delete()
    .eq("user_id", userID)
    .eq("token", token);
  if (delError) {
    console.error("[push-tokens] failed to delete stale push_tokens row:", delError.message ?? delError);
  } else {
    removedFromTable = true;
  }

  const { error: nullError } = await supabase
    .from("profiles")
    .update({ push_token: null })
    .eq("id", userID)
    .eq("push_token", token);
  if (nullError) {
    console.error("[push-tokens] failed to null matching profiles.push_token:", nullError.message ?? nullError);
  } else {
    clearedOnProfile = true;
  }

  return { removedFromTable, clearedOnProfile };
}
