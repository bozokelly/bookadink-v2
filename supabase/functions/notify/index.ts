// notify — Supabase Edge Function
// Inserts a row into the notifications table (triggering the email hook automatically)
// and optionally sends an APNs push notification to the user's device.
//
// Required secrets (same as booking-confirmed):
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID
//   APNS_USE_SANDBOX — set "true" for development builds
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-injected
//
// Multi-device fan-out (2026-05-07): when send_push=true, the push fans out
// to every APNs token registered for the target user (iPhone+iPad+…). The
// in-app notification row is still inserted exactly once per call.
//
// Deploy: supabase functions deploy notify --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr, VALID_NOTIFICATION_TYPES } from "../_shared/validate.ts";
import { getCallerID } from "../_shared/auth.ts";
import { getPushTokensForUser, tokenShort, clearStaleToken } from "../_shared/push-tokens.ts";

interface RequestBody {
  user_id: string;
  title: string;
  body: string;
  type: string;
  reference_id?: string;
  send_push?: boolean;
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

  const { user_id, title: rawTitle, body: rawBody, type, reference_id, send_push } = body;
  if (!isUUID(user_id) || !rawTitle || !rawBody || !type) {
    return new Response("Missing required fields; user_id must be a valid UUID", { status: 400 });
  }
  if (!VALID_NOTIFICATION_TYPES.has(type)) {
    return new Response(`Invalid notification type: ${type}`, { status: 400 });
  }
  if (reference_id !== undefined && reference_id !== null && !isUUID(reference_id)) {
    return new Response("reference_id must be a valid UUID", { status: 400 });
  }
  const title = clampStr(rawTitle, 200);
  const notifBody = clampStr(rawBody, 1000);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Require an authenticated caller. Cross-user notifications (admin → member, member → admin)
  // are intentional — the caller need not be the notification target.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response("Authentication required", { status: 401 });
  }

  // Insert into notifications table — DB trigger fires send-notification-email automatically
  const { data: notifRow, error: insertError } = await supabase
    .from("notifications")
    .insert({
      user_id,
      title,
      body: notifBody,
      type,
      reference_id: reference_id ?? null,
      read: false,
    })
    .select("id")
    .single();

  if (insertError) {
    console.error("notification insert error:", insertError);
    return new Response(JSON.stringify({ error: insertError.message }), { status: 500 });
  }

  const notificationID = notifRow?.id ?? null;
  let pushedCount = 0;
  let tokenCount = 0;
  let staleCount = 0;
  let errorCount = 0;
  let fallbackUsed = false;

  if (send_push) {
    const userShort = String(user_id).slice(0, 8);
    const resolution = await getPushTokensForUser(supabase, user_id);
    const tokens = resolution.tokens;
    fallbackUsed = resolution.fallbackUsed;
    tokenCount = tokens.length;

    if (tokens.length === 0) {
      console.log(`[push] target=${userShort} tokens=0 fallback=${fallbackUsed}`);
    } else {
      console.log(`[push] target=${userShort} tokens=${tokens.length} fallback=${fallbackUsed}`);
      for (const token of tokens) {
        try {
          await sendAPNS({ deviceToken: token, title, body: notifBody, data: { type, reference_id } });
          pushedCount++;
          console.log(`[push] sent target=${userShort} token=${tokenShort(token)} ok=true`);
          await supabase.from("push_notification_log").insert({
            user_id,
            notification_id: notificationID,
            device_token: token,
            title,
            body: notifBody,
            payload: { type, reference_id },
            apns_status: 200,
          });
        } catch (err) {
          if (err instanceof StaleTokenError) {
            staleCount++;
            const cleanup = await clearStaleToken(supabase, user_id, token);
            console.log(
              `[push] stale target=${userShort} token=${tokenShort(token)} removed_table=${cleanup.removedFromTable} cleared_profile=${cleanup.clearedOnProfile}`,
            );
            continue;
          }
          errorCount++;
          const errMsg = err instanceof Error ? err.message : String(err);
          console.error(`[push] error target=${userShort} token=${tokenShort(token)} err=${errMsg}`);
          await supabase.from("push_notification_log").insert({
            user_id,
            notification_id: notificationID,
            device_token: token,
            title,
            body: notifBody,
            payload: { type, reference_id },
            apns_status: 0,
            apns_error: errMsg,
          });
        }
      }
    }
  }

  return new Response(JSON.stringify({
    notified: true,
    pushed: pushedCount > 0,
    token_count: tokenCount,
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
// APNs helpers (shared pattern with booking-confirmed and club-chat-push)
// ---------------------------------------------------------------------------

class StaleTokenError extends Error {
  constructor() { super("StaleToken"); this.name = "StaleTokenError"; }
}

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
