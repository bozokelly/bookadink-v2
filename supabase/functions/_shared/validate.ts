// _shared/validate.ts — lightweight input validation helpers for Edge Functions

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUUID(s: unknown): s is string {
  return typeof s === "string" && UUID_RE.test(s);
}

/** Truncate to max length; returns "" for null/undefined. */
export function clampStr(s: string | null | undefined, max: number): string {
  if (!s) return "";
  return s.length > max ? s.slice(0, max) : s;
}

/** True if n is an integer in [min, max]. */
export function inIntRange(n: unknown, min: number, max: number): n is number {
  return typeof n === "number" && Number.isInteger(n) && n >= min && n <= max;
}

/** Remove non-printable control characters (keeps space, tab, newline). */
export function sanitizeText(s: string): string {
  return s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "");
}

/** Valid notification types accepted by the notify function and the DB enum. */
export const VALID_NOTIFICATION_TYPES = new Set([
  "booking_confirmed",
  "booking_cancelled",
  "booking_waitlisted",
  "waitlist_promoted",
  "membership_approved",
  "membership_rejected",
  "membership_removed",
  "membership_request_received",
  "admin_promoted",
  "club_announcement",
  "club_new_post",
  "club_new_comment",
  "game_cancelled",
  "game_updated",
  "game_review_request",
  "game_reminder_2h",
  "new_game",
]);
