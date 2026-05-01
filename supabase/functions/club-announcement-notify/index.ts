// club-announcement-notify — Supabase Edge Function
// Fan-out: inserts a notification row for every approved club member
// (excluding the poster) and sends APNs push when an announcement is posted.
//
// Changes from v1:
//   - thread-id: "club.{club_id}" for iOS Notification Center grouping
//   - Stale token (APNs 410) clears profiles.push_token automatically
//
// Deploy: supabase functions deploy club-announcement-notify --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr } from "../_shared/validate.ts";
import { isRateLimited } from "../_shared/rateLimit.ts";
import { getCallerID } from "../_shared/auth.ts";

interface RequestBody {
  club_id: string;
  post_id: string;
  poster_user_id: string;
  // club_name and poster_name are accepted for backward compatibility but
  // are always overridden by DB-sourced values to prevent content injection.
  club_name?: string;
  poster_name?: string;
  post_body: string;
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

  // Normalise UUIDs to lowercase — Swift's UUID.uuidString is uppercase; DB and auth return lowercase.
  const club_id = (body.club_id as string)?.toLowerCase();
  const post_id = (body.post_id as string)?.toLowerCase();
  const poster_user_id = (body.poster_user_id as string)?.toLowerCase();
  const rawPostBody = body.post_body;
  if (!club_id || !isUUID(club_id) || !post_id || !isUUID(post_id) || !poster_user_id || !isUUID(poster_user_id)) {
    return new Response("Missing or invalid required fields: club_id, post_id, poster_user_id (UUIDs required)", { status: 400 });
  }

  // Cap post_body to prevent huge notification payloads
  const post_body = clampStr(rawPostBody, 500);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Enforce caller identity: the poster must be the authenticated user.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response("Authentication required", { status: 401 });
  }
  if (callerID !== poster_user_id) {
    console.warn("[club-announcement-notify] caller", callerID, "tried to post as", poster_user_id);
    return new Response("Forbidden: poster_user_id must match the authenticated caller", { status: 403 });
  }

  // Rate limit: 10 announcements per club per minute
  if (await isRateLimited(supabase, `announcement:${club_id}`, 60, 10)) {
    console.warn("[club-announcement-notify] rate limited for club:", club_id);
    return new Response(JSON.stringify({ notified: 0, reason: "rate_limited" }), {
      status: 429,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Always resolve club_name and poster_name from DB — never trust client-supplied values
  const [clubResult, posterResult] = await Promise.all([
    supabase.from("clubs").select("name").eq("id", club_id).single(),
    supabase.from("profiles").select("full_name").eq("id", poster_user_id).single(),
  ]);
  const club_name = clubResult.data?.name ?? "your club";
  const poster_name = posterResult.data?.full_name ?? "Someone";

  // Fetch all approved club members, excluding the poster
  const { data: members, error: membersError } = await supabase
    .from("club_members")
    .select("user_id")
    .eq("club_id", club_id)
    .eq("status", "approved")
    .neq("user_id", poster_user_id);

  if (membersError || !members || members.length === 0) {
    return new Response(JSON.stringify({ notified: 0, reason: "no_members" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const inAppTitle = `Announcement from ${club_name}`;
  const notifBody = post_body
    ? (post_body.length > 120 ? post_body.slice(0, 120) + "…" : post_body)
    : `${poster_name} posted an announcement.`;

  // Push uses subtitle field for club attribution
  const pushTitle = `📢 ${club_name}`;
  const pushBody = notifBody;

  // Fetch push tokens for all members
  const userIDs = members.map((m: { user_id: string }) => m.user_id);
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
    members.map(async (member: { user_id: string }) => {
      // Insert in-app notification row (triggers send-notification-email hook)
      const { data: notifRow } = await supabase
        .from("notifications")
        .insert({
          user_id: member.user_id,
          title: inAppTitle,
          body: notifBody,
          type: "club_announcement",
          reference_id: club_id,
          read: false,
        })
        .select("id")
        .single();

      notifiedCount++;
      const notificationID = notifRow?.id ?? null;
      const deviceToken = tokenByUserID[member.user_id];

      if (deviceToken) {
        try {
          await sendAPNS({
            deviceToken,
            title: pushTitle,
            body: pushBody,
            data: { club_id, post_id, type: "club_announcement" },
            threadID: `club.${club_id}`,
          });
          pushedCount++;
          await supabase.from("push_notification_log").insert({
            user_id: member.user_id,
            notification_id: notificationID,
            device_token: deviceToken,
            title: pushTitle,
            body: pushBody,
            payload: { club_id, post_id, type: "club_announcement" },
            apns_status: 200,
          });
        } catch (err) {
          if (err instanceof StaleTokenError) {
            staleTokenUserIDs.push(member.user_id);
          } else {
            const errMsg = String(err);
            console.error(`APNs failed for user ${member.user_id}:`, errMsg);
            await supabase.from("push_notification_log").insert({
              user_id: member.user_id,
              notification_id: notificationID,
              device_token: deviceToken,
              title: pushTitle,
              body: pushBody,
              payload: { club_id, post_id, type: "club_announcement" },
              apns_status: 0,
              apns_error: errMsg,
            });
          }
        }
      }
    })
  );

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
