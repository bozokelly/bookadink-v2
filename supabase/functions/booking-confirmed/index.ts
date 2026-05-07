// booking-confirmed — Supabase Edge Function
// Sends an APNs push notification to the booked user's device.
// The in-app notification row is inserted separately via `notify` from iOS (sendPush: false)
// so this function handles push-only. Both paths fire concurrently from AppState.
//
// Required secrets:
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID
//   APNS_USE_SANDBOX — "true" for dev builds
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-injected
//
// Multi-device fan-out (2026-05-07): every APNs token registered for the user
// receives the booking-confirmed push (iPhone + iPad + …). Per-token failures
// are isolated so one stale device cannot block the others. Stale tokens (410)
// are cleared via the shared helper.
//
// Deploy: supabase functions deploy booking-confirmed

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID } from "../_shared/validate.ts";
import { getCallerID } from "../_shared/auth.ts";
import { getPushTokensForUser, tokenShort, clearStaleToken } from "../_shared/push-tokens.ts";

const FALLBACK_TZ = "Australia/Perth";

interface RequestBody {
  game_id: string;
  booking_id: string;
  user_id: string;
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

  const { game_id, booking_id, user_id } = body;
  if (!isUUID(game_id) || !isUUID(booking_id) || !isUUID(user_id)) {
    return new Response("game_id, booking_id, and user_id must be valid UUIDs", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Enforce caller identity: the user requesting the push must be the booking user.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response(JSON.stringify({ sent: false, reason: "auth_required" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (callerID !== user_id) {
    console.warn("[booking-confirmed] caller", callerID, "tried to push for user", user_id);
    return new Response(JSON.stringify({ sent: false, reason: "forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Check user's push preference for booking confirmations
  const { data: notifPrefs } = await supabase
    .from("notification_preferences")
    .select("booking_confirmed_push")
    .eq("user_id", user_id)
    .single();

  if (notifPrefs?.booking_confirmed_push === false) {
    return new Response(JSON.stringify({ sent: false, reason: "user_pref_off" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Fetch tokens (multi-device) and game details concurrently
  const [tokensResult, gameResult] = await Promise.all([
    getPushTokensForUser(supabase, user_id),
    supabase.from("games").select("title, date_time, duration_minutes, venue_name, clubs(name, timezone)").eq("id", game_id).single(),
  ]);

  const { tokens, fallbackUsed } = tokensResult;
  const userShort = String(user_id).slice(0, 8);

  if (tokens.length === 0) {
    console.log(`[push] target=${userShort} tokens=0 fallback=${fallbackUsed}`);
    return new Response(JSON.stringify({
      sent: false,
      reason: "no_push_token",
      token_count: 0,
      pushed_count: 0,
      stale_count: 0,
      error_count: 0,
      fallback_used: fallbackUsed,
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const game = gameResult.data;
  const gameTitle = game?.title ?? "your game";
  const clubTZ: string = ((game?.clubs as { timezone?: string } | null)?.timezone) || FALLBACK_TZ;

  // Structured body parts (timezone-aware, locale-formatted)
  const dt = game?.date_time ? formatGameDatetimeParts(game.date_time, clubTZ) : null;
  const duration = typeof game?.duration_minutes === "number" ? formatDuration(game.duration_minutes) : null;

  // Location rule: venue_name → club name → omit
  const venueName = (game?.venue_name as string | null)?.trim() ?? "";
  const clubName = ((game?.clubs as { name?: string } | null)?.name ?? "").trim();
  const locationDisplay = venueName || clubName;

  const dateTimeLine = dt
    ? duration
      ? `${dt.day}, ${dt.date} · ${dt.time} (${duration})`
      : `${dt.day}, ${dt.date} · ${dt.time}`
    : "";

  const pushBody = buildBookingConfirmedBody(gameTitle, dateTimeLine, locationDisplay);

  console.log(`[push] target=${userShort} tokens=${tokens.length} fallback=${fallbackUsed}`);

  let pushedCount = 0;
  let staleCount = 0;
  let errorCount = 0;
  for (const token of tokens) {
    try {
      await sendAPNS({
        deviceToken: token,
        title: "Booking confirmed",
        body: pushBody,
        data: { game_id, booking_id, type: "booking_confirmed" },
        threadID: `game.${game_id}`,
      });
      pushedCount += 1;
      console.log(`[push] sent target=${userShort} token=${tokenShort(token)} ok=true`);
    } catch (err) {
      if (err instanceof StaleTokenError) {
        staleCount += 1;
        const cleanup = await clearStaleToken(supabase, user_id, token);
        console.log(
          `[push] stale target=${userShort} token=${tokenShort(token)} removed_table=${cleanup.removedFromTable} cleared_profile=${cleanup.clearedOnProfile}`,
        );
        continue;
      }
      errorCount += 1;
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[push] error target=${userShort} token=${tokenShort(token)} err=${message}`);
    }
  }

  return new Response(JSON.stringify({
    sent: pushedCount > 0,
    token_count: tokens.length,
    pushed_count: pushedCount,
    stale_count: staleCount,
    error_count: errorCount,
    fallback_used: fallbackUsed,
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/**
 * Splits a UTC ISO timestamp into day / date / time parts in the given IANA
 * timezone. Returns: { day: "Tuesday", date: "5 May", time: "2:00 pm" }.
 * Falls back to "Australia/Perth" if tz is invalid.
 */
function formatGameDatetimeParts(
  isoString: string,
  tz: string,
): { day: string; date: string; time: string } {
  const d = new Date(isoString);
  try {
    const fmt = new Intl.DateTimeFormat("en-AU", {
      weekday: "long",
      day: "numeric",
      month: "short",
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
      timeZone: tz,
    });
    const parts = fmt.formatToParts(d);
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
    const period = get("dayPeriod").toLowerCase();
    return {
      day: get("weekday"),
      date: `${get("day")} ${get("month")}`,
      time: `${get("hour")}:${get("minute")} ${period}`,
    };
  } catch {
    return formatGameDatetimeParts(isoString, "Australia/Perth");
  }
}

function formatDuration(minutes: number): string {
  if (minutes < 60) return `${minutes}m`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

/**
 * Three-line body. If the assembled string would exceed the soft cap, the
 * venue is truncated first — game title and date/time line are preserved.
 */
function buildBookingConfirmedBody(gameTitle: string, dateTimeLine: string, venue: string): string {
  const MAX_LEN = 178;
  const join = (v: string) => {
    const lines: string[] = [gameTitle];
    if (dateTimeLine) lines.push(dateTimeLine);
    if (v) lines.push(`📍 ${v}`);
    return lines.join("\n");
  };
  const full = join(venue);
  if (full.length <= MAX_LEN || !venue) return full;
  const overhead = full.length - venue.length;
  const room = MAX_LEN - overhead - 1; // 1 char for ellipsis
  const truncated = room > 0 ? venue.slice(0, room) + "…" : "";
  return join(truncated);
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
