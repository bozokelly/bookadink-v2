// club-chat-push — Supabase Edge Function
// Sends APNs push notifications to all club members (except the actor)
// when a new post or comment is created in the club news feed.
//
// Required secrets (same as booking-confirmed):
//   APNS_KEY_ID        — Apple Push Notification key ID
//   APNS_TEAM_ID       — Apple Developer Team ID
//   APNS_PRIVATE_KEY   — Contents of the .p8 auth key file (newlines as \n)
//   APNS_BUNDLE_ID     — App bundle ID, e.g. Brayden.BookadinkV2
//   SUPABASE_URL       — Auto-injected by Supabase
//   SUPABASE_SERVICE_ROLE_KEY — Auto-injected by Supabase
//
// Deploy: supabase functions deploy club-chat-push

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  club_id: string;
  actor_user_id: string;
  event: string;
  reference_id?: string;
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

  const { club_id, actor_user_id, event } = body;
  if (!club_id || !actor_user_id || !event) {
    return new Response("Missing required fields: club_id, actor_user_id, event", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Fetch club name
  const { data: clubData } = await supabase
    .from("clubs")
    .select("name")
    .eq("id", club_id)
    .single();

  const clubName = clubData?.name ?? "your club";

  // Build notification copy based on event type
  const title = event === "new_announcement" ? `📢 ${clubName}` : clubName;
  let notificationBody: string;
  switch (event) {
    case "new_post":
      notificationBody = "A new post was shared in the club feed.";
      break;
    case "new_announcement":
      notificationBody = "A new announcement has been posted.";
      break;
    case "new_comment":
      notificationBody = "Someone commented on a club post.";
      break;
    default:
      notificationBody = "There is new activity in your club.";
  }

  // Fetch all approved club members (excluding the actor) who have a push token
  const { data: members, error: membersError } = await supabase
    .from("club_members")
    .select("user_id")
    .eq("club_id", club_id)
    .eq("status", "approved")
    .neq("user_id", actor_user_id);

  if (membersError || !members || members.length === 0) {
    return new Response(JSON.stringify({ sent: 0, reason: "no_members" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const memberIDs = members.map((m: { user_id: string }) => m.user_id);

  // Fetch push tokens for those members
  const { data: profiles } = await supabase
    .from("profiles")
    .select("id, push_token")
    .in("id", memberIDs)
    .not("push_token", "is", null);

  if (!profiles || profiles.length === 0) {
    return new Response(JSON.stringify({ sent: 0, reason: "no_push_tokens" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Send push to each member in parallel, ignore individual failures
  let sentCount = 0;
  await Promise.allSettled(
    profiles.map(async (profile: { id: string; push_token: string }) => {
      try {
        await sendAPNS({
          deviceToken: profile.push_token,
          title,
          body: notificationBody,
          data: { club_id, event },
        });
        sentCount++;
      } catch (err) {
        console.error(`APNs failed for user ${profile.id}:`, err);
      }
    })
  );

  return new Response(JSON.stringify({ sent: sentCount }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

// ---------------------------------------------------------------------------
// APNs JWT + HTTP/2 push delivery (same implementation as booking-confirmed)
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
