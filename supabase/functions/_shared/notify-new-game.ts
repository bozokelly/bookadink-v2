// _shared/notify-new-game.ts
// Shared fan-out: notify approved club members that a new game is published.
//
// Used by:
//   - game-published-notify  (caller: club admin/owner via iOS, immediate publish)
//   - game-publish-release   (caller: pg_cron via service role, delayed publish)
//
// The two callers differ only in how they authorize: immediate publish requires
// a club-admin JWT; delayed publish runs as service role on a cron schedule and
// is gated by the release_scheduled_games() RPC which atomically claims each
// game via published_notification_sent_at. Once a payload reaches this module
// the fan-out behaviour is identical regardless of source.
//
// Multi-device fan-out (2026-05-07): tokens resolved through
// _shared/push-tokens.ts so iPhone+iPad both receive the push. Per-token APNs
// failures are isolated.

import { getPushTokensForUser, tokenShort, clearStaleToken } from "./push-tokens.ts";

const FALLBACK_TZ = "Australia/Perth";

export interface NewGameNotifyPayload {
  gameID: string;
  gameTitle: string;
  gameDateTime: string; // ISO8601
  clubID: string;
  clubName: string;
  createdByUserID: string;
  skillLevel?: string | null;  // "all" | "beginner" | "intermediate" | "advanced"
  clubTimezone?: string | null;
}

export interface NewGameNotifyResult {
  notified: number;
  pushed: number;
  staleTokensCleared: number;
  reason?: string;
}

// deno-lint-ignore no-explicit-any
export async function notifyNewGameMembers(supabase: any, payload: NewGameNotifyPayload): Promise<NewGameNotifyResult> {
  const clubTZ = payload.clubTimezone || FALLBACK_TZ;
  const skillSuffix = payload.skillLevel ? prettifySkillLevel(payload.skillLevel) : null;

  const { data: members, error: membersError } = await supabase
    .from("club_members")
    .select("user_id")
    .eq("club_id", payload.clubID)
    .eq("status", "approved")
    .neq("user_id", payload.createdByUserID);

  if (membersError) {
    throw new Error(`club_members query failed: ${membersError.message}`);
  }

  if (!members || members.length === 0) {
    return { notified: 0, pushed: 0, staleTokensCleared: 0, reason: "no_members" };
  }

  const inAppTitle = `New game at ${payload.clubName}`;
  const pushTitle = `${payload.clubName}`;
  const pushSubtitle = "New game available";

  const formattedDate = payload.gameDateTime ? formatGameDatetime(payload.gameDateTime, clubTZ) : null;
  const inAppBodyParts = [payload.gameTitle, formattedDate, skillSuffix].filter(Boolean) as string[];
  const inAppBody = inAppBodyParts.join(" · ");
  const pushBodyParts = [formattedDate ?? payload.gameTitle, skillSuffix].filter(Boolean) as string[];
  const pushBody = pushBodyParts.join(" · ");

  const userIDs = members.map((m: { user_id: string }) => m.user_id);
  const { data: prefsData } = await supabase
    .from("notification_preferences")
    .select("user_id,new_game_push")
    .in("user_id", userIDs);

  const pushOptedOut = new Set<string>(
    (prefsData ?? [])
      .filter((r: { user_id: string; new_game_push: boolean }) => r.new_game_push === false)
      .map((r: { user_id: string }) => r.user_id)
  );

  let notifiedCount = 0;
  let pushedCount = 0;
  let staleCount = 0;
  let errorCount = 0;

  await Promise.allSettled(
    members.map(async (member: { user_id: string }) => {
      const { data: notifRow } = await supabase
        .from("notifications")
        .insert({
          user_id: member.user_id,
          title: inAppTitle,
          body: inAppBody,
          type: "new_game",
          reference_id: payload.gameID,
          read: false,
        })
        .select("id")
        .single();

      notifiedCount++;
      const notificationID = notifRow?.id ?? null;

      if (pushOptedOut.has(member.user_id)) return;

      const userShort = String(member.user_id).slice(0, 8);
      const { tokens, fallbackUsed } = await getPushTokensForUser(supabase, member.user_id);

      if (tokens.length === 0) {
        console.log(`[push] target=${userShort} tokens=0 fallback=${fallbackUsed}`);
        return;
      }

      console.log(`[push] target=${userShort} tokens=${tokens.length} fallback=${fallbackUsed}`);

      for (const deviceToken of tokens) {
        try {
          await sendAPNS({
            deviceToken,
            title: pushTitle,
            subtitle: pushSubtitle,
            body: pushBody,
            data: { game_id: payload.gameID, club_id: payload.clubID, type: "new_game" },
            threadID: `club.${payload.clubID}`,
          });
          pushedCount++;
          console.log(`[push] sent target=${userShort} token=${tokenShort(deviceToken)} ok=true`);
          await supabase.from("push_notification_log").insert({
            user_id: member.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { game_id: payload.gameID, club_id: payload.clubID, type: "new_game" },
            apns_status: 200,
          });
        } catch (err) {
          if (err instanceof StaleTokenError) {
            staleCount++;
            const cleanup = await clearStaleToken(supabase, member.user_id, deviceToken);
            console.log(
              `[push] stale target=${userShort} token=${tokenShort(deviceToken)} removed_table=${cleanup.removedFromTable} cleared_profile=${cleanup.clearedOnProfile}`,
            );
            continue;
          }
          errorCount++;
          const errMsg = err instanceof Error ? err.message : String(err);
          console.error(`[push] error target=${userShort} token=${tokenShort(deviceToken)} err=${errMsg}`);
          await supabase.from("push_notification_log").insert({
            user_id: member.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { game_id: payload.gameID, club_id: payload.clubID, type: "new_game" },
            apns_status: 0,
            apns_error: errMsg,
          });
        }
      }
    })
  );

  return {
    notified: notifiedCount,
    pushed: pushedCount,
    staleTokensCleared: staleCount,
  };
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

function formatGameDatetime(isoString: string, tz: string): string {
  const d = new Date(isoString);
  try {
    const fmt = new Intl.DateTimeFormat("en-AU", {
      weekday: "short",
      day: "numeric",
      month: "short",
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
      timeZone: tz,
    });
    const parts = fmt.formatToParts(d);
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
    const period = get("dayPeriod").toUpperCase();
    return `${get("weekday")}, ${get("day")} ${get("month")} · ${get("hour")}:${get("minute")} ${period}`;
  } catch {
    return formatGameDatetime(isoString, FALLBACK_TZ);
  }
}

function prettifySkillLevel(level: string): string | null {
  switch (level) {
    case "beginner":     return "Beginner";
    case "intermediate": return "Intermediate";
    case "advanced":     return "Advanced";
    case "all":          return null; // don't suffix "All levels" — it's implied
    default:             return null;
  }
}

// ---------------------------------------------------------------------------
// APNs helpers
// ---------------------------------------------------------------------------

class StaleTokenError extends Error {
  constructor() { super("StaleToken"); this.name = "StaleTokenError"; }
}

async function sendAPNS(opts: {
  deviceToken: string;
  title: string;
  subtitle?: string;
  body: string;
  data?: Record<string, unknown>;
  threadID?: string;
  collapseID?: string;
  priority?: 5 | 10;
}): Promise<void> {
  const keyId = Deno.env.get("APNS_KEY_ID")!;
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY")!.replace(/\\n/g, "\n");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;
  const useSandbox = Deno.env.get("APNS_USE_SANDBOX") === "true";
  const apnsHost = useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";

  const jwt = await makeAPNSJWT(keyId, teamId, privateKeyPem);
  const apnsUrl = `https://${apnsHost}/3/device/${opts.deviceToken}`;

  const alert: Record<string, string> = { title: opts.title, body: opts.body };
  if (opts.subtitle) alert.subtitle = opts.subtitle;

  const aps: Record<string, unknown> = { alert, sound: "default" };
  if (opts.threadID) aps["thread-id"] = opts.threadID;

  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": bundleId,
    "apns-push-type": "alert",
    "apns-priority": String(opts.priority ?? 10),
    "content-type": "application/json",
  };
  if (opts.collapseID) headers["apns-collapse-id"] = opts.collapseID;

  const resp = await fetch(apnsUrl, {
    method: "POST",
    headers,
    body: JSON.stringify({ aps, ...opts.data }),
  });

  if (resp.status === 410) throw new StaleTokenError();
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`APNs ${resp.status}: ${text}`);
  }
}

async function makeAPNSJWT(keyId: string, teamId: string, privateKeyPem: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId };
  const claims = { iss: teamId, iat: now };
  const encodedHeader = base64url(JSON.stringify(header));
  const encodedClaims = base64url(JSON.stringify(claims));
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const keyData = pemToArrayBuffer(privateKeyPem);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8", keyData, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, cryptoKey, new TextEncoder().encode(signingInput)
  );
  return `${signingInput}.${base64url(signature)}`;
}

function base64url(input: string | ArrayBuffer): string {
  let bytes: Uint8Array;
  if (typeof input === "string") {
    bytes = new TextEncoder().encode(input);
  } else {
    bytes = new Uint8Array(input);
  }
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}
