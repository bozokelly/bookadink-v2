// game-updated-notify — Supabase Edge Function
// Fan-out: notifies all confirmed and waitlisted players when a game's details change.
// Inserts a notifications row per player (triggering email hook) and sends push.
//
// Called from iOS (AppState.updateGameForClub) after a successful game edit.
//
// Required secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID,
//                   APNS_USE_SANDBOX, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Multi-device fan-out (2026-05-07): tokens resolved through
// _shared/push-tokens.ts so iPhone+iPad both receive the push. Per-token APNs
// failures are isolated.
//
// Deploy: supabase functions deploy game-updated-notify --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr } from "../_shared/validate.ts";
import { getCallerID, isClubAdmin } from "../_shared/auth.ts";
import { getPushTokensForUser, tokenShort, clearStaleToken } from "../_shared/push-tokens.ts";

const FALLBACK_TZ = "Australia/Perth";

interface RequestBody {
  game_id: string;
  club_id: string;
  game_title: string;
  club_name: string;
  game_date_time?: string;     // ISO8601 — new value after update
  changed_fields?: string[];   // e.g. ["date_time", "venue_name", "fee_amount"]
  club_timezone?: string;      // IANA identifier, e.g. "Australia/Perth"
}

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }

  const { game_id, club_id, game_title: rawGameTitle, club_name: rawClubName, game_date_time, changed_fields = [], club_timezone } = body;
  const clubTZ = club_timezone || FALLBACK_TZ;
  if (!isUUID(game_id) || !isUUID(club_id) || !rawGameTitle || !rawClubName) {
    return new Response("game_id and club_id must be valid UUIDs; game_title and club_name are required", { status: 400 });
  }
  const game_title = clampStr(rawGameTitle, 200);
  const club_name = clampStr(rawClubName, 200);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Require an authenticated club admin or owner.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response("Authentication required", { status: 401 });
  }
  const adminOK = await isClubAdmin(supabase, callerID, club_id);
  if (!adminOK) {
    console.warn("[game-updated-notify] caller", callerID, "not admin for club", club_id);
    return new Response("Forbidden: caller is not an admin of this club", { status: 403 });
  }

  // Fetch all confirmed and waitlisted bookings for this game
  const { data: bookings, error: bookingsError } = await supabase
    .from("bookings")
    .select("id,user_id")
    .eq("game_id", game_id)
    .in("status", ["confirmed", "waitlisted"]);

  if (bookingsError || !bookings || bookings.length === 0) {
    return new Response(JSON.stringify({ sent: 0, reason: "no_bookings" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Pre-format date once using the club's venue timezone — same value for all recipients
  const dateStr = game_date_time ? formatGameDatetime(game_date_time, clubTZ) : null;
  const changeDescription = buildChangeDescription(changed_fields, dateStr);

  const inAppTitle = `Game updated: ${game_title}`;
  const inAppBody = changeDescription
    ? `${changeDescription} · Tap to see full details.`
    : `Details for ${game_title} have changed. Check before you go.`;
  const pushTitle = "Game details changed";
  const pushBody = changeDescription
    ? `${game_title} · ${changeDescription}`
    : `${game_title}${dateStr ? " · " + dateStr : ""} — details have changed.`;

  let notifiedCount = 0;
  let pushedCount = 0;
  let staleCount = 0;
  let errorCount = 0;

  await Promise.allSettled(
    bookings.map(async (booking: { id: string; user_id: string }) => {
      // Insert one in-app notification row per recipient (triggers email hook)
      const { data: notifRow } = await supabase
        .from("notifications")
        .insert({
          user_id: booking.user_id,
          title: inAppTitle,
          body: inAppBody,
          type: "game_updated",
          reference_id: game_id,
          read: false,
        })
        .select("id")
        .single();

      notifiedCount++;
      const notificationID = notifRow?.id ?? null;
      const userShort = String(booking.user_id).slice(0, 8);
      const { tokens, fallbackUsed } = await getPushTokensForUser(supabase, booking.user_id);

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
            body: pushBody,
            data: { game_id, club_id, type: "game_updated" },
            threadID: `game.${game_id}`,
          });
          pushedCount++;
          console.log(`[push] sent target=${userShort} token=${tokenShort(deviceToken)} ok=true`);
          await supabase.from("push_notification_log").insert({
            user_id: booking.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { game_id, club_id, type: "game_updated", changed_fields },
            apns_status: 200,
          });
        } catch (err) {
          if (err instanceof StaleTokenError) {
            staleCount++;
            const cleanup = await clearStaleToken(supabase, booking.user_id, deviceToken);
            console.log(
              `[push] stale target=${userShort} token=${tokenShort(deviceToken)} removed_table=${cleanup.removedFromTable} cleared_profile=${cleanup.clearedOnProfile}`,
            );
            continue;
          }
          errorCount++;
          const errMsg = err instanceof Error ? err.message : String(err);
          console.error(`[push] error target=${userShort} token=${tokenShort(deviceToken)} err=${errMsg}`);
          await supabase.from("push_notification_log").insert({
            user_id: booking.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { game_id, club_id, type: "game_updated", changed_fields },
            apns_status: 0,
            apns_error: errMsg,
          });
        }
      }
    })
  );

  return new Response(JSON.stringify({
    notified: notifiedCount,
    pushed: pushedCount,
    stale_tokens_cleared: staleCount,
    error_count: errorCount,
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

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
    return formatGameDatetime(isoString, "Australia/Perth");
  }
}

/**
 * Converts changed_fields array into a human-readable string.
 * Returns null if no actionable description can be built.
 */
function buildChangeDescription(fields: string[], dateStr: string | null): string | null {
  const descriptions: string[] = [];

  if (fields.includes("date_time") && dateStr) {
    descriptions.push(`Now ${dateStr}`);
  } else if (fields.includes("date_time")) {
    descriptions.push("Time has changed");
  }

  if (fields.includes("venue_name") || fields.includes("location")) {
    descriptions.push("Venue has changed");
  }

  if (fields.includes("fee_amount")) {
    descriptions.push("Fee has changed");
  }

  if (fields.includes("max_spots")) {
    descriptions.push("Capacity has changed");
  }

  return descriptions.length > 0 ? descriptions.join(" · ") : null;
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
