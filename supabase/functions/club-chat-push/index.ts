// club-chat-push — Supabase Edge Function
//
// Notification routing for club member chat:
//
//   new_post          → all approved members except actor (lowest priority)
//   comment_on_post   → only the original post author (not all members)
//   mention           → only the explicitly @mentioned user(s)
//   new_announcement  → all approved members (unchanged, always priority 10)
//
// Deduplication rule (per recipient, same event):
//   mention (1) > comment_on_post (2) > new_post (3)
//
// Mention parsing: extracts @Name or @First Last tokens from content and
// resolves them case-insensitively against club member full_name.
//
// Required secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID,
//                   APNS_USE_SANDBOX, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy club-chat-push

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr } from "../_shared/validate.ts";
import { isRateLimited } from "../_shared/rateLimit.ts";
import { getCallerID } from "../_shared/auth.ts";

interface RequestBody {
  club_id: string;
  actor_user_id: string;
  event: string;            // "new_post" | "new_announcement" | "comment_on_post" | "new_comment" (legacy)
  reference_id?: string;    // post_id (new_post) or comment_id (comment_on_post)
  post_author_id?: string;  // comment_on_post: original post author's user_id
  content?: string;         // raw text — used for preview generation + @mention parsing
}

interface PendingNotification {
  title: string;
  body: string;
  reason: string;
  priority: number; // 1 = mention, 2 = comment_on_post, 3 = new_post
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

function buildPreview(content: string | undefined, maxLength = 100): string {
  if (!content) return "";
  const normalized = content.replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim();
  if (normalized.length === 0) return "";
  if (normalized.length <= maxLength) return normalized;
  return normalized.slice(0, maxLength).trimEnd() + "…";
}

// Returns an array of unique display names extracted from @mention tokens.
// Matches "@Word", "@First Last", "@Hyphen-Name", "@O'Brien" etc.
function parseMentions(content: string): string[] {
  const regex = /@([A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ''\-]+(?: [A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ''\-]+)*)/g;
  const names: string[] = [];
  const seen = new Set<string>();
  let match: RegExpExecArray | null;
  while ((match = regex.exec(content)) !== null) {
    const name = match[1].toLowerCase();
    if (!seen.has(name)) {
      seen.add(name);
      names.push(match[1]); // preserve original casing for logs; compare lowercase
    }
  }
  return names;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

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

  const { event } = body;
  // Structured session result posts embed JSON with a sentinel prefix — replace with
  // human-readable text before building notification previews or parsing mentions.
  const RESULT_SENTINEL = "__sr1__:";
  // Cap content before any further processing
  const rawContent = clampStr(body.content, 2000);
  const content = rawContent?.startsWith(RESULT_SENTINEL)
    ? "Session results posted"
    : rawContent;
  // Normalize all incoming UUIDs to lowercase — Swift's JSONEncoder produces uppercase UUIDs
  // (via UUID.uuidString) while the database stores and returns them in lowercase. Any map
  // lookup keyed by a DB-sourced ID against a request-supplied ID will silently miss without this.
  const club_id = (body.club_id as string)?.toLowerCase();
  const actor_user_id = (body.actor_user_id as string)?.toLowerCase();
  const reference_id = (body.reference_id as string | undefined)?.toLowerCase();
  const post_author_id = (body.post_author_id as string | undefined)?.toLowerCase();

  if (!club_id || !isUUID(club_id) || !actor_user_id || !isUUID(actor_user_id) || !event) {
    return new Response("Missing or invalid required fields: club_id, actor_user_id (UUIDs required), event", { status: 400 });
  }
  if (reference_id !== undefined && reference_id !== null && !isUUID(reference_id)) {
    return new Response("reference_id must be a valid UUID", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Enforce caller identity: the authenticated user must be the actor.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response("Authentication required", { status: 401 });
  }
  if (callerID !== actor_user_id) {
    console.warn("[club-chat-push] caller", callerID, "tried to act as", actor_user_id);
    return new Response("Forbidden: actor_user_id must match the authenticated caller", { status: 403 });
  }

  // Rate limit: 30 chat push events per actor per minute (generous for active chatters)
  if (await isRateLimited(supabase, `chat-push:${actor_user_id}`, 60, 30)) {
    console.warn("[club-chat-push] rate limited for actor:", actor_user_id);
    return jsonOK({ sent: 0, reason: "rate_limited" });
  }

  const isAnnouncement = event === "new_announcement";
  const isComment = event === "comment_on_post" || event === "new_comment";
  const isPost = event === "new_post";

  // Fetch club name and actor name in parallel
  const [clubResult, actorResult] = await Promise.all([
    supabase.from("clubs").select("name").eq("id", club_id).single(),
    supabase.from("profiles").select("full_name").eq("id", actor_user_id).single(),
  ]);

  const clubName = clubResult.data?.name ?? "your club";
  const actorFullName = actorResult.data?.full_name ?? "Someone";

  // ------------------------------------------------------------------
  // Announcement path — unchanged from prior implementation
  // ------------------------------------------------------------------
  if (isAnnouncement) {
    const { data: members } = await supabase
      .from("club_members")
      .select("user_id")
      .eq("club_id", club_id)
      .eq("status", "approved")
      .neq("user_id", actor_user_id);

    if (!members || members.length === 0) {
      return jsonOK({ sent: 0, reason: "no_members" });
    }

    const memberIDs = members.map((m: { user_id: string }) => m.user_id);
    const { data: profiles } = await supabase
      .from("profiles")
      .select("id, push_token")
      .in("id", memberIDs)
      .not("push_token", "is", null);

    const pushProfiles = profiles ?? [];
    let sentCount = 0;
    const staleTokenUIDs: string[] = [];

    await Promise.allSettled(
      pushProfiles.map(async (p: { id: string; push_token: string }) => {
        try {
          await sendAPNS({
            deviceToken: p.push_token,
            title: `📢 ${clubName}`,
            body: `${actorFullName} posted an announcement`,
            data: {
              type: "new_announcement",
              event: "new_announcement",
              club_id,
              reference_id: reference_id ?? null,
              actor_id: actor_user_id,
              actor_full_name: actorFullName,
              notification_reason: "new_announcement",
            },
            threadID: `club.${club_id}`,
            priority: 10,
          });
          sentCount++;
        } catch (err) {
          if (err instanceof StaleTokenError) staleTokenUIDs.push(p.id);
          else console.error(`APNs announcement failed for ${p.id}:`, err);
        }
      })
    );
    await clearStaleTokens(supabase, staleTokenUIDs);
    return jsonOK({ sent: sentCount, stale_tokens_cleared: staleTokenUIDs.length });
  }

  // ------------------------------------------------------------------
  // Chat event path: new_post / comment_on_post / mention
  // ------------------------------------------------------------------

  // Fetch all approved members for this club
  const { data: members, error: membersError } = await supabase
    .from("club_members")
    .select("user_id")
    .eq("club_id", club_id)
    .eq("status", "approved");

  if (membersError || !members || members.length === 0) {
    return jsonOK({ sent: 0, reason: "no_members" });
  }

  const memberIDs = (members as { user_id: string }[]).map((m) => m.user_id);

  // Fetch all member profiles (name + token) — needed for mention resolution and sending
  const [profilesResult, prefsResult] = await Promise.all([
    supabase.from("profiles").select("id, full_name, push_token").in("id", memberIDs),
    supabase.from("notification_preferences").select("user_id, chat_push").in("user_id", memberIDs),
  ]);

  const allProfiles: Array<{ id: string; full_name: string | null; push_token: string | null }> =
    profilesResult.data ?? [];

  const chatOptedOut = new Set<string>(
    ((prefsResult.data ?? []) as Array<{ user_id: string; chat_push: boolean }>)
      .filter((r) => r.chat_push === false)
      .map((r) => r.user_id)
  );

  // Map for fast lookup: lowercase full_name → profile
  const nameToProfile = new Map<string, { id: string; full_name: string | null; push_token: string | null }>();
  for (const p of allProfiles) {
    if (p.full_name) nameToProfile.set(p.full_name.toLowerCase(), p);
  }

  // Build preview text
  const preview = buildPreview(content);

  // ------------------------------------------------------------------
  // Build recipient map — highest priority per user wins
  // ------------------------------------------------------------------
  const recipients = new Map<string, PendingNotification>();

  const setPriority = (userID: string, notification: PendingNotification) => {
    const existing = recipients.get(userID);
    if (!existing || notification.priority < existing.priority) {
      recipients.set(userID, notification);
    }
  };

  // new_post → all members except actor (priority 3)
  if (isPost) {
    for (const profile of allProfiles) {
      if (profile.id === actor_user_id) continue;
      setPriority(profile.id, {
        title: `${clubName} · New post`,
        body: preview ? `${actorFullName}: ${preview}` : `${actorFullName} posted in member chat`,
        reason: "new_post",
        priority: 3,
      });
    }
    console.log(`new_post: queued ${allProfiles.length - 1} potential recipients`);
  }

  // comment_on_post → only post author (priority 2)
  if (isComment && post_author_id && post_author_id !== actor_user_id) {
    setPriority(post_author_id, {
      title: "New comment on your post",
      body: preview ? `${actorFullName}: ${preview}` : `${actorFullName} commented on your post`,
      reason: "comment_on_post",
      priority: 2,
    });
    console.log(`comment_on_post: queued notification for post author ${post_author_id}`);
  } else if (isComment && !post_author_id) {
    console.warn("comment_on_post event missing post_author_id — no notification sent");
  }

  // mentions → mentioned users only (priority 1, highest)
  const mentionedNames = content ? parseMentions(content) : [];
  let resolvedMentionCount = 0;
  for (const name of mentionedNames) {
    const profile = nameToProfile.get(name.toLowerCase());
    if (!profile) {
      console.log(`mention: no club member found for "@${name}"`);
      continue;
    }
    if (profile.id === actor_user_id) {
      console.log(`mention: self-mention suppressed for "@${name}"`);
      continue;
    }
    setPriority(profile.id, {
      title: `${actorFullName} mentioned you`,
      body: preview || `${actorFullName} mentioned you in member chat`,
      reason: "mention",
      priority: 1,
    });
    resolvedMentionCount++;
    console.log(`mention: queued notification for "${name}" (${profile.id})`);
  }

  if (mentionedNames.length > 0) {
    console.log(`mentions: parsed ${mentionedNames.length}, resolved ${resolvedMentionCount}`);
  }

  // Log deduplication summary
  const reasonCounts: Record<string, number> = {};
  for (const n of recipients.values()) {
    reasonCounts[n.reason] = (reasonCounts[n.reason] ?? 0) + 1;
  }
  console.log(`recipients: ${recipients.size} unique | breakdown: ${JSON.stringify(reasonCounts)}`);

  // ------------------------------------------------------------------
  // Send APNs to each unique recipient
  // ------------------------------------------------------------------
  const profileTokenMap = new Map<string, string>();
  for (const p of allProfiles) {
    if (p.push_token) profileTokenMap.set(p.id, p.push_token);
  }

  // The club owner (and admins) may not appear in club_members with status=approved,
  // so their profiles are absent from allProfiles. Do a supplementary lookup for any
  // recipient whose token wasn't covered by the initial member query.
  const uncoveredIDs = Array.from(recipients.keys()).filter((id) => !profileTokenMap.has(id));
  if (uncoveredIDs.length > 0) {
    const { data: extraProfiles } = await supabase
      .from("profiles")
      .select("id, push_token")
      .in("id", uncoveredIDs)
      .not("push_token", "is", null);
    for (const p of (extraProfiles ?? []) as Array<{ id: string; push_token: string }>) {
      profileTokenMap.set(p.id, p.push_token);
    }
    console.log(`supplementary profile lookup: ${uncoveredIDs.length} IDs → ${extraProfiles?.length ?? 0} tokens found`);
  }

  let sentCount = 0;
  const staleTokenUIDs: string[] = [];
  const skippedOptOut: string[] = [];
  const skippedNoToken: string[] = [];

  await Promise.allSettled(
    Array.from(recipients.entries()).map(async ([userID, notification]) => {
      if (chatOptedOut.has(userID)) {
        skippedOptOut.push(userID);
        return;
      }
      const token = profileTokenMap.get(userID);
      if (!token) {
        skippedNoToken.push(userID);
        return;
      }
      try {
        await sendAPNS({
          deviceToken: token,
          title: notification.title,
          body: notification.body,
          data: {
            type: notification.reason,
            event: notification.reason,
            club_id,
            reference_id: reference_id ?? null,
            actor_id: actor_user_id,
            actor_full_name: actorFullName,
            target_post_id: isComment ? reference_id ?? null : null,
            notification_reason: notification.reason,
            preview_text: preview || null,
          },
          threadID: `club.${club_id}`,
          collapseID: `chat.${club_id}`,
          priority: 10,
        });
        sentCount++;
      } catch (err) {
        if (err instanceof StaleTokenError) staleTokenUIDs.push(userID);
        else console.error(`APNs failed for ${userID}:`, err);
      }
    })
  );

  console.log(
    `push summary: sent=${sentCount} opted_out=${skippedOptOut.length} no_token=${skippedNoToken.length} stale=${staleTokenUIDs.length}`
  );

  await clearStaleTokens(supabase, staleTokenUIDs);

  return jsonOK({
    sent: sentCount,
    stale_tokens_cleared: staleTokenUIDs.length,
    skipped_opted_out: skippedOptOut.length,
    skipped_no_token: skippedNoToken.length,
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
async function clearStaleTokens(supabase: any, uids: string[]): Promise<void> {
  if (uids.length === 0) return;
  await Promise.allSettled(
    uids.map((uid) => supabase.from("profiles").update({ push_token: null }).eq("id", uid))
  );
}

function jsonOK(body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// APNs
// ---------------------------------------------------------------------------

class StaleTokenError extends Error {
  constructor() {
    super("StaleToken");
    this.name = "StaleTokenError";
  }
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
