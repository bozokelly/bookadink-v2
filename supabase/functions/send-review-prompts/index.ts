// send-review-prompts
// Finds games that ended 24 hours ago (±1h window for cron jitter) and sends a
// review prompt notification + APNs push to each confirmed attendee who hasn't
// already received one.
//
// Schedule via pg_cron (run hourly):
//   SELECT cron.schedule('send-review-prompts', '0 * * * *', $$
//     SELECT net.http_post(
//       url := 'https://<project-ref>.supabase.co/functions/v1/send-review-prompts',
//       headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb
//     )
//   $$);
//
// Required secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID,
//                   APNS_USE_SANDBOX, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Multi-device fan-out (2026-05-07): tokens resolved through
// _shared/push-tokens.ts so iPhone+iPad both receive the prompt. Per-token
// APNs failures are isolated.
//
// Deploy: supabase functions deploy send-review-prompts --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getPushTokensForUser, tokenShort, clearStaleToken } from "../_shared/push-tokens.ts";

const NOTIFICATION_TYPE = "game_review_request";

serve(async (req: Request) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } }
  );

  // Find games that ended between 23h and 25h ago (2h window absorbs cron drift).
  // Uses games_ending_between() RPC since PostgREST can't filter on column arithmetic.
  const now = new Date();
  const windowEnd   = new Date(now.getTime() - 23 * 60 * 60 * 1000).toISOString();
  const windowStart = new Date(now.getTime() - 25 * 60 * 60 * 1000).toISOString();

  const { data: games, error: gamesError } = await supabase.rpc(
    "games_ending_between",
    { window_start: windowStart, window_end: windowEnd }
  );

  if (gamesError) {
    console.error("Error fetching games:", gamesError);
    return new Response(JSON.stringify({ error: gamesError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!games || games.length === 0) {
    return new Response(
      JSON.stringify({ sent: 0, pushed: 0, reason: "no_games_in_window" }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  let totalSent = 0;
  let totalPushed = 0;
  let totalStale = 0;
  let totalErrors = 0;

  for (const game of games) {
    // Fetch all confirmed bookings for this game
    const { data: bookings } = await supabase
      .from("bookings")
      .select("user_id")
      .eq("game_id", game.id)
      .eq("status", "confirmed");

    if (!bookings || bookings.length === 0) continue;

    const userIDs = bookings.map((b: { user_id: string }) => b.user_id);

    // Deduplication: skip users who already have a review prompt notification for this game
    const { data: alreadySent } = await supabase
      .from("notifications")
      .select("user_id")
      .eq("type", NOTIFICATION_TYPE)
      .eq("reference_id", game.id)
      .in("user_id", userIDs);

    const alreadySentUserIDs = new Set<string>(
      (alreadySent ?? []).map((r: { user_id: string }) => r.user_id)
    );

    const eligibleUserIDs = userIDs.filter(
      (uid: string) => !alreadySentUserIDs.has(uid)
    );

    if (eligibleUserIDs.length === 0) continue;

    const pushTitle = `How was ${game.title}?`;
    const pushBody  = "Tap to leave a quick rating and help your club improve future sessions.";

    await Promise.allSettled(
      eligibleUserIDs.map(async (userID: string) => {
        // Insert in-app notification row first (acts as deduplication guard for reruns)
        const { data: notifRow, error: notifError } = await supabase
          .from("notifications")
          .insert({
            user_id: userID,
            title: pushTitle,
            body: pushBody,
            type: NOTIFICATION_TYPE,
            reference_id: game.id,
            read: false,
          })
          .select("id")
          .single();

        if (notifError) {
          console.error(`notification insert failed for user ${userID}:`, notifError);
          return;
        }

        totalSent++;
        const notificationID = notifRow?.id ?? null;
        const userShort = String(userID).slice(0, 8);
        const { tokens, fallbackUsed } = await getPushTokensForUser(supabase, userID);

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
              data: { type: NOTIFICATION_TYPE, reference_id: game.id },
              collapseID: `review.${game.id}`,
            });
            totalPushed++;
            console.log(`[push] sent target=${userShort} token=${tokenShort(deviceToken)} ok=true`);
            await supabase.from("push_notification_log").insert({
              user_id: userID,
              notification_id: notificationID,
              device_token: deviceToken,
              title: pushTitle,
              body: pushBody,
              payload: { type: NOTIFICATION_TYPE, reference_id: game.id },
              apns_status: 200,
            });
          } catch (err) {
            if (err instanceof StaleTokenError) {
              totalStale++;
              const cleanup = await clearStaleToken(supabase, userID, deviceToken);
              console.log(
                `[push] stale target=${userShort} token=${tokenShort(deviceToken)} removed_table=${cleanup.removedFromTable} cleared_profile=${cleanup.clearedOnProfile}`,
              );
              continue;
            }
            totalErrors++;
            const errMsg = err instanceof Error ? err.message : String(err);
            console.error(`[push] error target=${userShort} token=${tokenShort(deviceToken)} err=${errMsg}`);
            await supabase.from("push_notification_log").insert({
              user_id: userID,
              notification_id: notificationID,
              device_token: deviceToken,
              title: pushTitle,
              body: pushBody,
              payload: { type: NOTIFICATION_TYPE, reference_id: game.id },
              apns_status: 0,
              apns_error: errMsg,
            });
          }
        }
      })
    );
  }

  console.log(
    `send-review-prompts: sent ${totalSent} prompt(s), pushed ${totalPushed}, ` +
    `stale tokens cleared: ${totalStale}, errors: ${totalErrors}, games: ${games.length}`
  );

  return new Response(
    JSON.stringify({
      sent: totalSent,
      pushed: totalPushed,
      stale_tokens_cleared: totalStale,
      error_count: totalErrors,
      games: games.length,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});

// ---------------------------------------------------------------------------
// APNs helpers (same implementation as game-reminder-2h / booking-confirmed)
// ---------------------------------------------------------------------------

class StaleTokenError extends Error {
  constructor() { super("StaleToken"); this.name = "StaleTokenError"; }
}

async function sendAPNS(opts: {
  deviceToken: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  collapseID?: string;
}): Promise<void> {
  const keyId         = Deno.env.get("APNS_KEY_ID")!;
  const teamId        = Deno.env.get("APNS_TEAM_ID")!;
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY")!.replace(/\\n/g, "\n");
  const bundleId      = Deno.env.get("APNS_BUNDLE_ID")!;
  const useSandbox    = Deno.env.get("APNS_USE_SANDBOX") === "true";
  const apnsHost      = useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";

  const jwt     = await makeAPNSJWT(keyId, teamId, privateKeyPem);
  const apnsUrl = `https://${apnsHost}/3/device/${opts.deviceToken}`;

  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": bundleId,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  };
  if (opts.collapseID) headers["apns-collapse-id"] = opts.collapseID;

  const resp = await fetch(apnsUrl, {
    method: "POST",
    headers,
    body: JSON.stringify({
      aps: { alert: { title: opts.title, body: opts.body }, sound: "default" },
      ...opts.data,
    }),
  });

  if (resp.status === 410) throw new StaleTokenError();
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`APNs ${resp.status}: ${text}`);
  }
}

async function makeAPNSJWT(keyId: string, teamId: string, privateKeyPem: string): Promise<string> {
  const now    = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId };
  const claims = { iss: teamId, iat: now };
  const encodedHeader = base64url(JSON.stringify(header));
  const encodedClaims = base64url(JSON.stringify(claims));
  const signingInput  = `${encodedHeader}.${encodedClaims}`;
  const keyData       = pemToArrayBuffer(privateKeyPem);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8", keyData, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, cryptoKey, new TextEncoder().encode(signingInput)
  );
  return `${signingInput}.${base64url(signature)}`;
}

function base64url(input: string | ArrayBuffer): string {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : new Uint8Array(input);
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
  const bytes  = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}
