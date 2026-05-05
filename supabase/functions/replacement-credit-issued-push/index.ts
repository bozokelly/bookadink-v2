// replacement-credit-issued-push
// Called by the credit_on_replacement_confirmed() DB trigger via net.http_post
// after the deferred-credit path has issued credit to the original cancelling
// user. Inserts an in-app notification and sends an APNs push so the user
// learns their cancelled spot was filled and their account was credited.
//
// The trigger only invokes this function AFTER successful credit issuance for
// a 'managed'-policy club with credit_issued_cents > 0, so this function does
// not need to re-validate eligibility — it simply notifies + pushes.
//
// Idempotency: the trigger sets bookings.replacement_credit_issued_at on the
// same UPDATE that authorises this call. The trigger's filter requires that
// column to be NULL on entry, so this Edge Function is invoked at most once
// per cancelled booking.
//
// Payload (from PostgreSQL trigger):
//   {
//     user_id:             UUID,    // original cancelling user
//     booking_id:          UUID,    // cancelled booking that just received credit
//     game_id:             UUID,    // game the booking was on
//     club_id:             UUID,    // club where the credit lives (deep-link target)
//     credit_issued_cents: integer  // amount credited
//   }
//
// Notification type written to notifications table:
//   'replacement_credit_issued'
//
// Deploy: supabase functions deploy replacement-credit-issued-push --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

interface Payload {
  user_id: string;
  booking_id: string;
  game_id: string;
  club_id: string;
  credit_issued_cents: number;
}

Deno.serve(async (req) => {
  try {
    const payload = (await req.json()) as Payload;
    const { user_id, booking_id, game_id, club_id, credit_issued_cents } = payload;

    if (!user_id || !booking_id || !game_id || !club_id) {
      return jsonResponse({ error: "missing_required_fields" }, 400);
    }

    // Defence-in-depth: the trigger should never invoke us with 0 cents,
    // but if something does, do nothing rather than insert a misleading
    // "credited your account" notification with no actual credit.
    if (typeof credit_issued_cents !== "number" || credit_issued_cents <= 0) {
      return jsonResponse({ skipped: true, reason: "zero_or_invalid_amount" });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Notification copy per spec — title/body verbatim. Amount is exposed
    // through the data payload so the iOS app can read it for richer UI
    // without modifying the visible body string.
    const inAppTitle = "Spot filled — credit issued";
    const inAppBody = "Your cancelled spot was filled, so we've credited your account.";
    const pushTitle = inAppTitle;
    const pushBody = inAppBody;

    // Insert in-app notification row (also fires the email hook trigger).
    // reference_id = club_id so the iOS notification cell deep-links to the
    // club where the credit balance is displayed.
    const { error: insertError } = await supabase.from("notifications").insert({
      user_id,
      title: inAppTitle,
      body: inAppBody,
      type: "replacement_credit_issued",
      reference_id: club_id,
      read: false,
    });

    if (insertError) {
      // Most likely the notification_type enum value is missing on the live
      // DB (migration 20260505050000 not yet applied). Log and continue —
      // the APNs push still alerts the user, and the credit balance will
      // appear on next refreshCreditBalance.
      console.error("replacement-credit-issued-push: notifications insert failed", insertError);
    }

    // Optional preference gate. No dedicated column exists today; try to
    // honour `booking_confirmed_push` if the row exists since this is a
    // booking-outcome notification. If the column or row is missing, default
    // to ON — financial notifications should not be silently swallowed.
    let pushEnabled = true;
    try {
      const { data: pref } = await supabase
        .from("notification_preferences")
        .select("booking_confirmed_push")
        .eq("user_id", user_id)
        .single();
      if (pref && (pref as { booking_confirmed_push?: boolean }).booking_confirmed_push === false) {
        pushEnabled = false;
      }
    } catch (_) { /* missing row or column — default ON */ }

    if (!pushEnabled) {
      return jsonResponse({ notified: true, pushed: false, reason: "user_pref_off" });
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("push_token")
      .eq("id", user_id)
      .single();

    if (!profile?.push_token) {
      return jsonResponse({ notified: true, pushed: false, reason: "no_token" });
    }

    let pushed = false;
    try {
      await sendAPNS({
        deviceToken: profile.push_token,
        title: pushTitle,
        body: pushBody,
        data: {
          type: "replacement_credit_issued",
          reference_id: club_id,
          booking_id,
          game_id,
          club_id,
          credit_issued_cents,
        },
        threadID: `club.${club_id}`,
      });
      pushed = true;
    } catch (err) {
      if (err instanceof StaleTokenError) {
        await supabase.from("profiles").update({ push_token: null }).eq("id", user_id);
        return jsonResponse({ notified: true, pushed: false, reason: "stale_token_cleared" });
      }
      console.error("replacement-credit-issued-push: APNs error", err);
    }

    return jsonResponse({ notified: true, pushed });
  } catch (err) {
    console.error("replacement-credit-issued-push: fatal", err);
    return jsonResponse({ error: (err as Error).message }, 400);
  }
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// APNs (lifted from promote-top-waitlisted-push to keep deployment standalone)
// ─────────────────────────────────────────────────────────────────────────────

class StaleTokenError extends Error {
  constructor() {
    super("StaleToken");
    this.name = "StaleTokenError";
  }
}

async function sendAPNS(opts: {
  deviceToken: string;
  title: string;
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

  const aps: Record<string, unknown> = {
    alert: { title: opts.title, body: opts.body },
    sound: "default",
  };
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
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(signature)}`;
}

function base64url(input: string | ArrayBuffer): string {
  let bytes: Uint8Array;
  if (typeof input === "string") bytes = new TextEncoder().encode(input);
  else bytes = new Uint8Array(input);
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
