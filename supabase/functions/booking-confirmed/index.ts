// booking-confirmed — Supabase Edge Function
// Sends an APNs push notification to the booked user's device.
//
// Required secrets (set via `supabase secrets set`):
//   APNS_KEY_ID        — Apple Push Notification key ID (from Apple Developer portal)
//   APNS_TEAM_ID       — Apple Developer Team ID
//   APNS_PRIVATE_KEY   — Contents of the .p8 auth key file (newlines as \n)
//   APNS_BUNDLE_ID     — App bundle ID, e.g. com.yourdomain.BookadinkV2
//   SUPABASE_URL       — Auto-injected by Supabase
//   SUPABASE_SERVICE_ROLE_KEY — Auto-injected by Supabase
//
// Deploy: supabase functions deploy booking-confirmed

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
  if (!game_id || !booking_id || !user_id) {
    return new Response("Missing required fields: game_id, booking_id, user_id", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Fetch the user's push token, game details, and club name via join
  const [profileResult, gameResult] = await Promise.all([
    supabase.from("profiles").select("push_token").eq("id", user_id).single(),
    supabase.from("games").select("title, date_time, venue_name, clubs(name)").eq("id", game_id).single(),
  ]);

  if (profileResult.error || !profileResult.data?.push_token) {
    // No push token registered — nothing to do, not an error
    return new Response(JSON.stringify({ sent: false, reason: "no_push_token" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const pushToken: string = profileResult.data.push_token;
  const game = gameResult.data;
  const gameTitle = game?.title ?? "your game";
  const gameTime = game?.date_time
    ? new Date(game.date_time).toLocaleTimeString("en-US", {
        hour: "numeric",
        minute: "2-digit",
        timeZone: "UTC",
      })
    : "";

  // Location rule (mirrors iOS LocalNotificationManager.locationSuffix):
  //   venue_name → club name → omit. Never use placeholder text.
  const venueName = (game?.venue_name as string | null)?.trim() ?? "";
  const clubName = ((game?.clubs as { name?: string } | null)?.name ?? "").trim();
  const locationDisplay = venueName || clubName;
  const locationSuffix = locationDisplay ? ` at ${locationDisplay}` : "";

  const notificationBody = gameTime
    ? `${gameTitle} is confirmed for ${gameTime}${locationSuffix}.`
    : `You're booked for ${gameTitle}${locationSuffix}.`;

  // Send APNs push notification
  try {
    await sendAPNS({
      deviceToken: pushToken,
      title: "Booking Confirmed",
      body: notificationBody,
      data: { game_id, booking_id },
    });
  } catch (err) {
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
// APNs JWT + HTTP/2 push delivery
// ---------------------------------------------------------------------------

async function sendAPNS(opts: {
  deviceToken: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
}) {
  const keyId = Deno.env.get("APNS_KEY_ID")!;
  const teamId = Deno.env.get("APNS_TEAM_ID")!;
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY")!.replace(/\\n/g, "\n");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;

  const jwt = await makeAPNSJWT(keyId, teamId, privateKeyPem);

  const useSandbox = Deno.env.get("APNS_USE_SANDBOX") === "true";
  const apnsHost = useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const apnsUrl = `https://${apnsHost}/3/device/${opts.deviceToken}`;
  const payload = {
    aps: {
      alert: { title: opts.title, body: opts.body },
      sound: "default",
    },
    ...opts.data,
  };

  const resp = await fetch(apnsUrl, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

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
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput)
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
