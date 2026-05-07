// _shared/auth.ts — JWT caller identity and club admin verification
//
// getCallerID: verifies the Bearer JWT via the Supabase Auth API, which handles
//   any signing algorithm the project uses (HS256, ES256, RS256). Deployed with
//   --no-verify-jwt to bypass the gateway check; auth is enforced here instead:
//     - missing token                → null → 401
//     - expired / malformed token   → null → 401
//     - anon key / service role key → null → 401 (not a user session)
//
// resolveClubAdminRole / isClubAdmin: canonical admin-or-owner gate.
//   The previous implementation consulted club_members.role='admin', which
//   stopped being authoritative when the role lifecycle moved to a separate
//   club_admins (club_id, user_id, role) table (CLAUDE.md → "Club Role
//   Lifecycle"). Per that section: owner is dual-source — clubs.created_by
//   AND a club_admins row with role='owner' kept in sync by triggers — and
//   admins live in club_admins with role='admin'. club_members.role no
//   longer drives admin authorization.

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

export interface ClubAdminRole {
  /// True if userID is the club owner (clubs.created_by). Authoritative.
  isOwner: boolean;
  /// True if userID has a club_admins row for this club with role='admin'.
  /// Owner is excluded from this flag — owners surface via isOwner only.
  isAdmin: boolean;
}

/// Resolves the caller's relationship to a club using the canonical sources:
///   - clubs.created_by  → owner
///   - club_admins(role='owner' | 'admin')  → admin or owner
///
/// Returns { isOwner, isAdmin } so callers can log the structured outcome
/// without re-querying. Either flag true means the caller is authorized for
/// admin-only operations.
// deno-lint-ignore no-explicit-any
export async function resolveClubAdminRole(supabase: any, userID: string, clubID: string): Promise<ClubAdminRole> {
  if (!isUUID(userID) || !isUUID(clubID)) {
    return { isOwner: false, isAdmin: false };
  }
  const [ownerResult, adminResult] = await Promise.all([
    supabase.from("clubs").select("created_by").eq("id", clubID).maybeSingle(),
    supabase
      .from("club_admins")
      .select("role")
      .eq("club_id", clubID)
      .eq("user_id", userID)
      .in("role", ["owner", "admin"])
      .maybeSingle(),
  ]);
  const isOwner = ownerResult.data?.created_by === userID;
  // Treat any club_admins row as authorization; owner trigger may have
  // populated role='owner' for the same user — surface that as isOwner only.
  const adminRole = (adminResult.data as { role?: string } | null)?.role ?? null;
  const isAdmin = adminRole === "admin";
  return { isOwner, isAdmin };
}

/// Convenience wrapper preserving the prior boolean contract for callers that
/// only need a yes/no gate. Returns true for both club owners and admins.
// deno-lint-ignore no-explicit-any
export async function isClubAdmin(supabase: any, userID: string, clubID: string): Promise<boolean> {
  const role = await resolveClubAdminRole(supabase, userID, clubID);
  return role.isOwner || role.isAdmin;
}
