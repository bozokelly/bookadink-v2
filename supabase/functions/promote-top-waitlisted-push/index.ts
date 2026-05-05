// promote-top-waitlisted-push
// Called by the promote_top_waitlisted() DB trigger via net.http_post.
// Sends an APNs push and inserts a notifications row for the promoted player.
//
// Changes from v1:
//   - thread-id: "game.{game_id}" for iOS Notification Center grouping
//   - Stale token (APNs 410) clears profiles.push_token automatically
//   - Game date included in push body for context
//
// Changes from v2 (2026-05-05):
//   - Multi-device fan-out: reads every APNs token from push_tokens via the
//     shared helper, falling back to profiles.push_token only when the table
//     is empty. Each device receives its own APNs payload; per-token failures
//     do not abort the others. Stale tokens (410) are deleted from push_tokens
//     and from profiles.push_token only when they match (so a still-valid
//     legacy token on the profile row is not collateral damage).
//   - One notifications row is still inserted per promotion event.
//
// Deploy: supabase functions deploy promote-top-waitlisted-push --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";
import { getPushTokensForUser, tokenShort, clearStaleToken } from "../_shared/push-tokens.ts";

const FALLBACK_TZ = "Australia/Perth";

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const { booking_id, user_id, game_id, type } = payload;

    if (!user_id || !game_id || !type) {
      return new Response(JSON.stringify({ error: "Missing required fields" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Load game details for notification copy
    const { data: game, error: gameError } = await supabase
      .from("games")
      .select("title, date_time, venue_name, clubs(name, timezone)")
      .eq("id", game_id)
      .single();

    if (gameError) throw gameError;

    const isPendingPayment = type === "waitlist_promoted_pending_payment";
    const isHoldExpired = type === "hold_expired_forfeit";
    const gameTitle = game?.title ?? "your game";
    const clubName = ((game?.clubs as { name?: string; timezone?: string } | null)?.name ?? "").trim();
    const clubTZ: string = ((game?.clubs as { timezone?: string } | null)?.timezone) || FALLBACK_TZ;
    const rawDateTime = game?.date_time ?? null;

    const locationSuffix = game?.venue_name
      ? ` · ${game.venue_name}`
      : clubName
      ? ` · ${clubName}`
      : "";

    // Fetch preference (single row). Tokens are resolved lazily below via the
    // shared helper so the legacy profiles.push_token query only runs when
    // push_tokens has no rows for this user (back-compat path).
    const prefResult = await supabase
      .from("notification_preferences")
      .select("waitlist_push")
      .eq("user_id", user_id)
      .single();

    // Format using the club's venue timezone for consistency with in-app display
    const dateStr = rawDateTime ? formatGameDatetime(rawDateTime, clubTZ) : null;

    let pushTitle: string;
    let pushBody: string;
    let notifType: string;
    let inAppTitle: string;
    let inAppBody: string;

    if (isHoldExpired) {
      pushTitle = "Your hold expired";
      pushBody = `${gameTitle}${dateStr ? " · " + dateStr : ""} · Tap to rejoin if a spot is still open`;
      notifType = "booking_cancelled";
      inAppTitle = "Your hold expired";
      inAppBody = `Your spot in ${gameTitle} was released. Tap to rejoin the game if a spot is still open.`;
    } else if (isPendingPayment) {
      pushTitle = "Spot open — pay to confirm";
      pushBody = `${gameTitle}${dateStr ? " · " + dateStr : ""} · Your hold expires in 30 min`;
      notifType = "waitlist_promoted";
      inAppTitle = "Action required: complete booking";
      inAppBody = `${gameTitle} — a spot opened up. Pay within 30 minutes or your hold expires.`;
    } else {
      pushTitle = "Spot opened — you're in!";
      pushBody = `${gameTitle}${dateStr ? " · " + dateStr : ""}${locationSuffix}`;
      notifType = "booking_confirmed";
      inAppTitle = "You're off the waitlist!";
      inAppBody = `${gameTitle}${dateStr ? " · " + dateStr : ""}${locationSuffix}`;
    }

    // Insert in-app notification row (triggers email hook automatically)
    const { error: insertError } = await supabase.from("notifications").insert({
      user_id,
      title: inAppTitle,
      body: inAppBody,
      type: notifType,
      reference_id: game_id,
      read: false,
    });

    if (insertError) {
      console.error("notification insert error:", insertError);
      // Non-fatal — still attempt push
    }

    if (prefResult.data?.waitlist_push === false) {
      return new Response(JSON.stringify({ notified: true, pushed: false, reason: "user_pref_off" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const userShort = String(user_id).slice(0, 8);
    const { tokens, fallbackUsed } = await getPushTokensForUser(supabase, user_id);

    if (tokens.length === 0) {
      console.log(`[push] target=${userShort} tokens=0 fallback=${fallbackUsed}`);
      return new Response(JSON.stringify({ notified: true, pushed: false, reason: "no_tokens", token_count: 0, fallback_used: fallbackUsed }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    console.log(`[push] target=${userShort} tokens=${tokens.length} fallback=${fallbackUsed}`);

    let pushedCount = 0;
    let staleCount = 0;
    let errorCount = 0;
    for (const token of tokens) {
      try {
        await sendAPNS({
          deviceToken: token,
          title: pushTitle,
          body: pushBody,
          data: { type: notifType, reference_id: game_id },
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

    return new Response(
      JSON.stringify({
        notified: true,
        pushed: pushedCount > 0,
        token_count: tokens.length,
        pushed_count: pushedCount,
        stale_count: staleCount,
        error_count: errorCount,
        fallback_used: fallbackUsed,
      }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }
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
