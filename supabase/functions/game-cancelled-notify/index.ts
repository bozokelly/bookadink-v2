// game-cancelled-notify — Supabase Edge Function
// Fan-out: notifies all confirmed and waitlisted players when a game is cancelled.
// Inserts a notifications row per player (triggering email hook) and sends push.
//
// Deploy: supabase functions deploy game-cancelled-notify --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  game_id: string;
  game_title: string;
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

  const { game_id, game_title } = body;
  if (!game_id || !game_title) {
    return new Response("Missing required fields: game_id, game_title", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

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

  const title = "Game Cancelled";
  const notifBody = `${game_title} has been cancelled by the organiser. We're sorry for the inconvenience.`;

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

  await Promise.allSettled(
    bookings.map(async (booking: { id: string; user_id: string }) => {
      // Insert notification row
      const { data: notifRow } = await supabase
        .from("notifications")
        .insert({
          user_id: booking.user_id,
          title,
          body: notifBody,
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
          await sendAPNS({ deviceToken, title, body: notifBody, data: { game_id, type: "game_cancelled" } });
          pushedCount++;
          await supabase.from("push_notification_log").insert({
            user_id: booking.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title,
            body: notifBody,
            payload: { game_id, type: "game_cancelled" },
            apns_status: 200,
          });
        } catch (err) {
          const errMsg = String(err);
          console.error(`APNs failed for user ${booking.user_id}:`, errMsg);
          await supabase.from("push_notification_log").insert({
            user_id: booking.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title,
            body: notifBody,
            payload: { game_id, type: "game_cancelled" },
            apns_status: 0,
            apns_error: errMsg,
          });
        }
      }
    })
  );

  return new Response(JSON.stringify({ notified: notifiedCount, pushed: pushedCount }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

// ---------------------------------------------------------------------------
// APNs helpers
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
  const useSandbox = Deno.env.get("APNS_USE_SANDBOX") === "true";
  const apnsHost = useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";

  const jwt = await makeAPNSJWT(keyId, teamId, privateKeyPem);
  const apnsUrl = `https://${apnsHost}/3/device/${opts.deviceToken}`;
  const payload = {
    aps: { alert: { title: opts.title, body: opts.body }, sound: "default" },
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
