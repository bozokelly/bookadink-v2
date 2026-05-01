// _shared/rateLimit.ts — Supabase-backed rate limiter for Edge Functions
//
// Uses the `rate_limit_log` table (created by 20260421_security_hardening.sql).
// Each call inserts a record then counts recent records for the key.
// Fails open on any DB error to avoid disrupting legitimate users.

// deno-lint-ignore no-explicit-any
export async function isRateLimited(
  supabase: any,
  key: string,
  windowSecs: number,
  limit: number
): Promise<boolean> {
  try {
    // Insert first so this request is always counted.
    const { error: insertErr } = await supabase
      .from("rate_limit_log")
      .insert({ key });

    if (insertErr) {
      console.warn("[rateLimit] insert error:", insertErr.message);
      return false; // fail open
    }

    const windowStart = new Date(Date.now() - windowSecs * 1000).toISOString();
    const { count, error: countErr } = await supabase
      .from("rate_limit_log")
      .select("*", { count: "exact", head: true })
      .eq("key", key)
      .gte("created_at", windowStart);

    if (countErr) {
      console.warn("[rateLimit] count error:", countErr.message);
      return false; // fail open
    }

    const exceeded = (count ?? 0) > limit;
    if (exceeded) {
      console.warn(`[rateLimit] blocked key=${key} count=${count} limit=${limit}`);
    }
    return exceeded;
  } catch (err) {
    console.warn("[rateLimit] unexpected error:", err);
    return false;
  }
}
