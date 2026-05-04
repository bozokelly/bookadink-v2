// role-change-push
// Called by the trg_enqueue_role_change_push DB trigger via net.http_post.
// Sends an APNs push and inserts a notifications row whenever the target
// user's role in a club has changed. Closes the cross-device staleness gap:
// the device that performed the change is already in sync; this push reaches
// the OTHER devices logged into the same account.
//
// Payload (from PostgreSQL trigger):
//   {
//     audit_id:       UUID,
//     club_id:        UUID,
//     target_user_id: UUID,
//     actor_user_id:  UUID | null,
//     change_type:    'promoted_to_admin' | 'demoted_to_member' |
//                     'transferred_in' | 'transferred_out_to_admin' |
//                     'transferred_out_to_member' | 'club_created' |
//                     'member_removed_cascade' | 'self_relinquished',
//     old_role:       'owner' | 'admin' | 'member' | null,
//     new_role:       'owner' | 'admin' | 'member' | null
//   }
//
// Notification type written to notifications table (used by iOS to invalidate
// cached role state and refresh):
//   'role_changed'
//
// Deploy: supabase functions deploy role-change-push --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

interface Payload {
  audit_id: string;
  club_id: string;
  target_user_id: string;
  actor_user_id: string | null;
  change_type: string;
  old_role: string | null;
  new_role: string | null;
}

Deno.serve(async (req) => {
  try {
    const payload = (await req.json()) as Payload;
    const { club_id, target_user_id, change_type, new_role } = payload;

    if (!club_id || !target_user_id || !change_type) {
      return jsonResponse({ error: "missing_required_fields" }, 400);
    }

    // member_removed_cascade fires when someone is removed from the club entirely.
    // The "removed from club" notification is already sent by AppState.removeOwnerMember;
    // skip this one to avoid duplicate noise.
    if (change_type === "member_removed_cascade") {
      return jsonResponse({ skipped: true, reason: "duplicate_with_membership_removed" });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: club, error: clubError } = await supabase
      .from("clubs")
      .select("name")
      .eq("id", club_id)
      .single();

    if (clubError || !club) {
      console.error("role-change-push: club lookup failed", clubError);
      return jsonResponse({ error: "club_not_found" }, 404);
    }
    const clubName = (club.name ?? "").trim() || "your club";

    const copy = composeCopy(change_type, new_role, clubName);
    if (!copy) {
      // 'self_relinquished' or other no-notify event. Still 200 so the trigger
      // doesn't see it as an error.
      return jsonResponse({ skipped: true, reason: "no_copy_for_change_type" });
    }

    // Insert in-app notification row (also fires email hook).
    // Reference is the club_id so taps deep-link to the club.
    const { error: insertError } = await supabase.from("notifications").insert({
      user_id: target_user_id,
      title: copy.inAppTitle,
      body: copy.inAppBody,
      type: "role_changed",
      reference_id: club_id,
      read: false,
    });

    if (insertError) {
      // Most likely the notification_type enum doesn't yet have 'role_changed'.
      // The iOS app will still pull fresh role state next time it loads — this
      // path is best-effort. Log and continue to APNs anyway (push delivery
      // alone closes the staleness gap).
      console.error("role-change-push: notifications insert failed", insertError);
    }

    // Optional preference gate: notification_preferences.role_change_push if
    // the column exists. We swallow the error so missing column degrades to
    // "send the push".
    let pushEnabled = true;
    try {
      const { data: pref } = await supabase
        .from("notification_preferences")
        .select("role_change_push")
        .eq("user_id", target_user_id)
        .single();
      if (pref && (pref as { role_change_push?: boolean }).role_change_push === false) {
        pushEnabled = false;
      }
    } catch (_) { /* column missing — default ON */ }

    if (!pushEnabled) {
      return jsonResponse({ notified: true, pushed: false, reason: "user_pref_off" });
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("push_token")
      .eq("id", target_user_id)
      .single();

    if (!profile?.push_token) {
      return jsonResponse({ notified: true, pushed: false, reason: "no_token" });
    }

    let pushed = false;
    try {
      await sendAPNS({
        deviceToken: profile.push_token,
        title: copy.pushTitle,
        body: copy.pushBody,
        data: {
          type: "role_changed",
          reference_id: club_id,
          change_type,
          new_role: new_role ?? "",
        },
        threadID: `club.${club_id}`,
      });
      pushed = true;
    } catch (err) {
      if (err instanceof StaleTokenError) {
        await supabase.from("profiles").update({ push_token: null }).eq("id", target_user_id);
        return jsonResponse({ notified: true, pushed: false, reason: "stale_token_cleared" });
      }
      console.error("role-change-push: APNs error", err);
    }

    return jsonResponse({ notified: true, pushed });
  } catch (err) {
    console.error("role-change-push: fatal", err);
    return jsonResponse({ error: (err as Error).message }, 400);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Copy
// ─────────────────────────────────────────────────────────────────────────────

interface NotificationCopy {
  pushTitle: string;
  pushBody: string;
  inAppTitle: string;
  inAppBody: string;
}

function composeCopy(
  changeType: string,
  newRole: string | null,
  clubName: string,
): NotificationCopy | null {
  switch (changeType) {
    case "promoted_to_admin":
      return {
        pushTitle: "You're now an admin",
        pushBody: `${clubName} — you can now manage members and create games.`,
        inAppTitle: "Admin access granted",
        inAppBody: `You are now an admin of ${clubName}.`,
      };
    case "demoted_to_member":
      return {
        pushTitle: "Admin access removed",
        pushBody: `You no longer have admin access in ${clubName}.`,
        inAppTitle: "Admin access removed",
        inAppBody: `Your admin access for ${clubName} was removed.`,
      };
    case "transferred_in":
      return {
        pushTitle: "You're now the club owner",
        pushBody: `You have been made the owner of ${clubName}.`,
        inAppTitle: "Ownership transferred to you",
        inAppBody: `You are now the owner of ${clubName}.`,
      };
    case "transferred_out_to_admin":
      return {
        pushTitle: "Ownership transferred",
        pushBody: `You stepped down as owner of ${clubName} and are now an admin.`,
        inAppTitle: "You stepped down as owner",
        inAppBody: `You handed off ownership of ${clubName} and remain an admin.`,
      };
    case "transferred_out_to_member":
      return {
        pushTitle: "Ownership transferred",
        pushBody: `You stepped down as owner of ${clubName}.`,
        inAppTitle: "You stepped down as owner",
        inAppBody: `You handed off ownership of ${clubName}.`,
      };
    case "club_created":
      // Self-event; trigger should have already filtered. Defense in depth.
      return null;
    case "self_relinquished":
      return null;
    default:
      // Unknown change_type — log a generic message rather than swallow.
      return {
        pushTitle: "Your role changed",
        pushBody: `Your role in ${clubName} was updated${newRole ? ` to ${newRole}` : ""}.`,
        inAppTitle: "Your role changed",
        inAppBody: `Your role in ${clubName} was updated${newRole ? ` to ${newRole}` : ""}.`,
      };
  }
}

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
