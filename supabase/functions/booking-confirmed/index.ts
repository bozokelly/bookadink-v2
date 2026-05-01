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
// Deploy: supabase functions deploy booking-confirmed

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID } from "../_shared/validate.ts";
import { getCallerID } from "../_shared/auth.ts";

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

  // Fetch push token and game details concurrently
  const [profileResult, gameResult] = await Promise.all([
    supabase.from("profiles").select("push_token").eq("id", user_id).single(),
    supabase.from("games").select("title, date_time, venue_name, clubs(name, timezone)").eq("id", game_id).single(),
  ]);

  if (profileResult.error || !profileResult.data?.push_token) {
    return new Response(JSON.stringify({ sent: false, reason: "no_push_token" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const pushToken: string = profileResult.data.push_token;
  const game = gameResult.data;
  const gameTitle = game?.title ?? "your game";
  const clubTZ: string = ((game?.clubs as { timezone?: string } | null)?.timezone) || FALLBACK_TZ;

  // Format time using the club's venue timezone for consistency with in-app display
  const formattedDatetime = game?.date_time ? formatGameDatetime(game.date_time, clubTZ) : null;

  // Location rule: venue_name → club name → omit
  const venueName = (game?.venue_name as string | null)?.trim() ?? "";
  const clubName = ((game?.clubs as { name?: string } | null)?.name ?? "").trim();
  const locationDisplay = venueName || clubName;
  const locationSuffix = locationDisplay ? ` · ${locationDisplay}` : "";

  const pushBody = formattedDatetime
    ? `${gameTitle} · ${formattedDatetime}${locationSuffix}`
    : `You're booked for ${gameTitle}${locationSuffix ? " at " + locationSuffix.slice(3) : ""}.`;

  try {
    await sendAPNS({
      deviceToken: pushToken,
      title: "You're in!",
      body: pushBody,
      data: { game_id, booking_id, type: "booking_confirmed" },
      threadID: `game.${game_id}`,
    });
  } catch (err) {
    if (err instanceof StaleTokenError) {
      // Token is invalid — clear it so we stop attempting delivery
      await supabase.from("profiles").update({ push_token: null }).eq("id", user_id);
      return new Response(JSON.stringify({ sent: false, reason: "stale_token_cleared" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    console.error("APNs send failed:", err);
    return new Response(JSON.stringify({ sent: false, reason: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ sent: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/**
 * Formats a UTC ISO timestamp as "Sat, 20 Apr · 9:00 AM" in the given IANA timezone.
 * Falls back to "Australia/Perth" if tz is invalid.
 */
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
    // Invalid timezone — fall back to Perth
    return formatGameDatetime(isoString, "Australia/Perth");
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
