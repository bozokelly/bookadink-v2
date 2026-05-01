// _shared/auth.ts — JWT caller identity and club admin verification
//
// getCallerID: verifies the Bearer JWT via the Supabase Auth API, which handles
//   any signing algorithm the project uses (HS256, ES256, RS256). Deployed with
//   --no-verify-jwt to bypass the gateway check; auth is enforced here instead:
//     - missing token                → null → 401
//     - expired / malformed token   → null → 401
//     - anon key / service role key → null → 401 (not a user session)
//   isClubAdmin DB query is the authoritative ownership gate on top of this.
// isClubAdmin: true if the user is the club owner (clubs.created_by) or has
//   role="admin" in club_members.

import { isUUID } from "./validate.ts";

// deno-lint-ignore no-explicit-any
export async function getCallerID(supabase: any, req: Request): Promise<string | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!token) return null;

  try {
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data?.user?.id) return null;
    return data.user.id;
  } catch {
    return null;
  }
}

// True if userID is the club owner (clubs.created_by) or an approved admin member.
// deno-lint-ignore no-explicit-any
export async function isClubAdmin(supabase: any, userID: string, clubID: string): Promise<boolean> {
  if (!isUUID(userID) || !isUUID(clubID)) return false;
  const [ownerResult, adminResult] = await Promise.all([
    supabase.from("clubs").select("created_by").eq("id", clubID).maybeSingle(),
    supabase
      .from("club_members")
      .select("user_id")
      .eq("club_id", clubID)
      .eq("user_id", userID)
      .eq("role", "admin")
      .maybeSingle(),
  ]);
  return ownerResult.data?.created_by === userID || !!adminResult.data;
}
