// game-cancelled-notify — Supabase Edge Function
// Fan-out: notifies all confirmed and waitlisted players when a game is cancelled.
// Inserts a notifications row per player (triggering email hook) and sends push.
//
// Changes from v1:
//   - thread-id: "game.{game_id}" for iOS Notification Center grouping
//   - Stale token (APNs 410) clears profiles.push_token automatically
//
// Deploy: supabase functions deploy game-cancelled-notify --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr } from "../_shared/validate.ts";
import { getCallerID, isClubAdmin } from "../_shared/auth.ts";

const FALLBACK_TZ = "Australia/Perth";

interface RequestBody {
  game_id: string;
  game_title: string;
  club_timezone?: string; // IANA identifier — fallback only, authoritative value fetched from DB
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

  const { game_id, game_title: rawGameTitle, club_timezone } = body;
  if (!isUUID(game_id) || !rawGameTitle) {
    return new Response("game_id must be a valid UUID and game_title is required", { status: 400 });
  }
  const game_title = clampStr(rawGameTitle, 200);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Require an authenticated club admin or owner.
  // Resolve club_id from the DB (not the client payload) to prevent spoofing.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response("Authentication required", { status: 401 });
  }
  const { data: gameRow } = await supabase
    .from("games").select("club_id").eq("id", game_id).single();
  if (!gameRow?.club_id) {
    return new Response("Game not found", { status: 404 });
  }
  const adminOK = await isClubAdmin(supabase, callerID, gameRow.club_id);
  if (!adminOK) {
    console.warn("[game-cancelled-notify] caller", callerID, "not admin for club", gameRow.club_id);
    return new Response("Forbidden: caller is not an admin of this club", { status: 403 });
  }

  // Fetch game details and bookings concurrently
  const [gameResult, bookingsResult] = await Promise.all([
    supabase
      .from("games")
      .select("title, date_time, venue_name, club_id, clubs(name, timezone)")
      .eq("id", game_id)
      .single(),
    supabase
      .from("bookings")
      .select("id,user_id")
      .eq("game_id", game_id)
      .in("status", ["confirmed", "waitlisted"]),
  ]);

  const { data: bookings, error: bookingsError } = bookingsResult;
  if (bookingsError || !bookings || bookings.length === 0) {
    return new Response(JSON.stringify({ sent: 0, reason: "no_bookings" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Enrich from DB — authoritative over iOS payload
  const game = gameResult.data;
  const clubID: string = (game?.club_id as string | null) ?? "";
  const clubName = ((game?.clubs as { name?: string; timezone?: string } | null)?.name ?? "").trim();
  const clubTZ: string =
    ((game?.clubs as { timezone?: string } | null)?.timezone) ||
    club_timezone ||
    FALLBACK_TZ;

  const dateStr = game?.date_time ? formatGameDatetime(game.date_time, clubTZ) : null;
  const venueName = (game?.venue_name as string | null)?.trim() ?? "";
  const locationDisplay = venueName || clubName;
  const locationSuffix = locationDisplay ? ` · ${locationDisplay}` : "";

  const inAppTitle = "Game cancelled";
  const inAppBody = dateStr
    ? `${game_title} · ${dateStr}${locationSuffix} has been cancelled.`
    : `${game_title} has been cancelled by the organiser.`;
  const pushTitle = "Game cancelled";
  const pushBody = dateStr
    ? `${game_title} · ${dateStr}${locationSuffix}`
    : `${game_title} has been cancelled.`;

  // Fetch push tokens for affected users
  const userIDs = bookings.map((b: { user_id: string }) => b.user_id);
  const { data: profiles } = await supabase
    .from("profiles")
    .select("id,push_token")
    .in("id", userIDs);

  const tokenByUserID: Record<string, string> = {};
  for (const p of profiles ?? []) {
    if (p.push_token) tokenByUserID[p.id] = p.push_token;
  }

  let notifiedCount = 0;
  let pushedCount = 0;
  const staleTokenUserIDs: string[] = [];

  await Promise.allSettled(
    bookings.map(async (booking: { id: string; user_id: string }) => {
      // Insert in-app notification row (triggers email hook)
      const { data: notifRow } = await supabase
        .from("notifications")
        .insert({
          user_id: booking.user_id,
          title: inAppTitle,
          body: inAppBody,
          type: "game_cancelled",
          reference_id: game_id,
          read: false,
        })
        .select("id")
        .single();

      notifiedCount++;
      const notificationID = notifRow?.id ?? null;
      const deviceToken = tokenByUserID[booking.user_id];

      if (deviceToken) {
        try {
          await sendAPNS({
            deviceToken,
            title: pushTitle,
            body: pushBody,
            data: { game_id, club_id: clubID, type: "game_cancelled" },
            threadID: `game.${game_id}`,
          });
          pushedCount++;
          await supabase.from("push_notification_log").insert({
            user_id: booking.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { game_id, club_id: clubID, type: "game_cancelled" },
            apns_status: 200,
          });
        } catch (err) {
          if (err instanceof StaleTokenError) {
            staleTokenUserIDs.push(booking.user_id);
          } else {
            const errMsg = String(err);
            console.error(`APNs failed for user ${booking.user_id}:`, errMsg);
            await supabase.from("push_notification_log").insert({
              user_id: booking.user_id,
              notification_id: notificationID,
              device_token: deviceToken,
              title: pushTitle,
              body: pushBody,
              payload: { game_id, club_id: clubID, type: "game_cancelled" },
              apns_status: 0,
              apns_error: errMsg,
            });
          }
        }
      }
    })
  );

  // Clear stale tokens
  if (staleTokenUserIDs.length > 0) {
    await Promise.allSettled(
      staleTokenUserIDs.map((uid) =>
        supabase.from("profiles").update({ push_token: null }).eq("id", uid)
      )
    );
  }

  return new Response(JSON.stringify({ notified: notifiedCount, pushed: pushedCount, stale_tokens_cleared: staleTokenUserIDs.length }), {
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
