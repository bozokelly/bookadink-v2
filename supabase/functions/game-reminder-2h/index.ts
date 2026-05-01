// game-reminder-2h — Supabase Edge Function
// Server-side automatic T-2h reminder for confirmed game players.
// Run hourly via pg_cron — finds games starting in 1h45m–2h15m and notifies
// confirmed players who haven't already received a reminder.
//
// pg_cron setup (run once in Supabase SQL Editor):
//   -- Remove old cron job if it exists:
//   SELECT cron.unschedule('game-reminder-24h');
//
//   SELECT cron.schedule(
//     'game-reminder-2h',
//     '0 * * * *',
//     $$
//     SELECT net.http_post(
//       url := 'https://<project-ref>.supabase.co/functions/v1/game-reminder-2h',
//       headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb
//     )
//     $$
//   );
//
// Required secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID,
//                   APNS_USE_SANDBOX, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy game-reminder-2h --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FALLBACK_TZ = "Australia/Perth";
const NOTIFICATION_TYPE = "game_reminder_2h";

serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Read reminder offset from app_config — canonical server-authoritative value.
  // Falls back to 120 if the row is missing (safe default, matches iOS constant).
  const { data: configRow } = await supabase
    .from("app_config")
    .select("value")
    .eq("key", "game_reminder_offset_minutes")
    .maybeSingle();
  const offsetMinutes = parseInt(configRow?.value ?? "120", 10);

  // 30-minute window centred on the offset to absorb cron jitter (±15 min)
  const windowStart = new Date(Date.now() + (offsetMinutes - 15) * 60 * 1000).toISOString();
  const windowEnd   = new Date(Date.now() + (offsetMinutes + 15) * 60 * 1000).toISOString();

  // Fetch games in window, filter client-side to exclude cancelled
  const { data: gamesRaw } = await supabase
    .from("games")
    .select("id, title, date_time, venue_name, club_id, status, clubs!inner(name, timezone)")
    .gte("date_time", windowStart)
    .lte("date_time", windowEnd);

  const activeGames = (gamesRaw ?? []).filter(
    (g: { status?: string | null }) => !g.status || g.status !== "cancelled"
  );

  if (!activeGames || activeGames.length === 0) {
    return new Response(JSON.stringify({ reminders_sent: 0, reason: "no_upcoming_games" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  let totalNotified = 0;
  let totalPushed = 0;
  const staleTokenUserIDs: string[] = [];

  for (const game of activeGames) {
    const clubName = ((game.clubs as { name?: string; timezone?: string } | null)?.name ?? "").trim();
    const clubTZ: string = ((game.clubs as { timezone?: string } | null)?.timezone) || FALLBACK_TZ;

    // Fetch confirmed bookings for this game
    const { data: bookings } = await supabase
      .from("bookings")
      .select("id, user_id")
      .eq("game_id", game.id)
      .eq("status", "confirmed");

    if (!bookings || bookings.length === 0) continue;

    const userIDs = bookings.map((b: { user_id: string }) => b.user_id);

    // Deduplication: find users who already have a 2h reminder notification for this game
    const { data: alreadySent } = await supabase
      .from("notifications")
      .select("user_id")
      .eq("type", NOTIFICATION_TYPE)
      .eq("reference_id", game.id)
      .in("user_id", userIDs);

    const alreadySentUserIDs = new Set<string>(
      (alreadySent ?? []).map((r: { user_id: string }) => r.user_id)
    );

    const pendingBookings = bookings.filter(
      (b: { user_id: string }) => !alreadySentUserIDs.has(b.user_id)
    );

    if (pendingBookings.length === 0) continue;

    const pendingUserIDs = pendingBookings.map((b: { user_id: string }) => b.user_id);

    // Fetch push tokens for pending users
    const { data: profiles } = await supabase
      .from("profiles")
      .select("id, push_token")
      .in("id", pendingUserIDs);

    const tokenByUserID: Record<string, string> = {};
    for (const p of profiles ?? []) {
      if (p.push_token) tokenByUserID[p.id] = p.push_token;
    }

    // Pre-format using the club's venue timezone — same value for all recipients
    const formattedDatetime = formatGameDatetime(game.date_time, clubTZ);
    const venueName = game.venue_name?.trim() ?? "";
    const locationDisplay = venueName || clubName;
    const locationSuffix = locationDisplay ? ` · ${locationDisplay}` : "";

    const confirmedCount = bookings.length;
    const playerSuffix = confirmedCount > 1 ? ` · ${confirmedCount} players confirmed` : "";

    const pushTitle = `Starting soon: ${game.title}`;
    const pushBody = `${formattedDatetime}${locationSuffix}${playerSuffix}`;
    const inAppTitle = "Game reminder";
    const inAppBody = `${game.title} · Starting in 2 hours · ${formattedDatetime}${locationSuffix}`;

    await Promise.allSettled(
      pendingBookings.map(async (booking: { id: string; user_id: string }) => {
        // Insert in-app notification row first (deduplication guard)
        const { data: notifRow, error: notifError } = await supabase
          .from("notifications")
          .insert({
            user_id: booking.user_id,
            title: inAppTitle,
            body: inAppBody,
            type: NOTIFICATION_TYPE,
            reference_id: game.id,
            read: false,
          })
          .select("id")
          .single();

        if (notifError) {
          console.error(`notification insert failed for user ${booking.user_id}:`, notifError);
          return;
        }

        totalNotified++;
        const notificationID = notifRow?.id ?? null;
        const deviceToken = tokenByUserID[booking.user_id];

        if (!deviceToken) return;

        try {
          await sendAPNS({
            deviceToken,
            title: pushTitle,
            body: pushBody,
            data: { game_id: game.id, type: NOTIFICATION_TYPE },
            threadID: `game.${game.id}`,
            collapseID: `reminder.${game.id}`,
          });
          totalPushed++;
          await supabase.from("push_notification_log").insert({
            user_id: booking.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { game_id: game.id, type: NOTIFICATION_TYPE },
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
              payload: { game_id: game.id, type: NOTIFICATION_TYPE },
              apns_status: 0,
              apns_error: errMsg,
            });
          }
        }
      })
    );
  }

  // Clear stale tokens
  if (staleTokenUserIDs.length > 0) {
    await Promise.allSettled(
      [...new Set(staleTokenUserIDs)].map((uid) =>
        supabase.from("profiles").update({ push_token: null }).eq("id", uid)
      )
    );
  }

  return new Response(
    JSON.stringify({
      reminders_sent: totalNotified,
      pushed: totalPushed,
      stale_tokens_cleared: staleTokenUserIDs.length,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
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
