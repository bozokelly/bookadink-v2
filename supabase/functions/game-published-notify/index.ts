// game-published-notify — Supabase Edge Function
// Fan-out: notifies all approved club members when a new game is published.
//
// Only called for immediately-published games (no publish delay).
// Delayed-publish games are handled by game-publish-release on a pg_cron tick.
// Both functions share the same fan-out logic via _shared/notify-new-game.ts.
//
// Deploy: supabase functions deploy game-published-notify --no-verify-jwt
// Auth:   requires valid user JWT; caller must be a club admin or owner.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr } from "../_shared/validate.ts";
import { getCallerID, isClubAdmin } from "../_shared/auth.ts";
import { notifyNewGameMembers } from "../_shared/notify-new-game.ts";

interface RequestBody {
  game_id: string;
  game_title: string;
  game_date_time: string; // ISO8601
  club_id: string;
  club_name: string;
  created_by_user_id: string;
  skill_level?: string;  // "all" | "beginner" | "intermediate" | "advanced"
  club_timezone?: string; // IANA identifier, e.g. "Australia/Perth"
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

  const { game_id, game_title: rawGameTitle, game_date_time, club_id, club_name: rawClubName, created_by_user_id, skill_level, club_timezone } = body;
  if (!isUUID(game_id) || !isUUID(club_id) || !isUUID(created_by_user_id) || !rawGameTitle || !rawClubName) {
    return new Response("game_id, club_id, and created_by_user_id must be valid UUIDs; game_title and club_name are required", { status: 400 });
  }
  const game_title = clampStr(rawGameTitle, 200);
  const club_name = clampStr(rawClubName, 200);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Require an authenticated club admin or owner.
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response("Authentication required", { status: 401 });
  }
  const adminOK = await isClubAdmin(supabase, callerID, club_id);
  if (!adminOK) {
    console.warn("[game-published-notify] caller", callerID, "not admin for club", club_id);
    return new Response("Forbidden: caller is not an admin of this club", { status: 403 });
  }

  // Idempotency: stamp the game as notified before the fan-out so a retry of
  // this endpoint can't double-notify. The delayed path stamps inside the RPC
  // for the same reason.
  const { data: claimRows, error: claimError } = await supabase
    .from("games")
    .update({ published_notification_sent_at: new Date().toISOString() })
    .eq("id", game_id)
    .is("published_notification_sent_at", null)
    .select("id");
  if (claimError) {
    console.error("[game-published-notify] failed to stamp idempotency:", claimError);
    return new Response(JSON.stringify({ error: claimError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (!claimRows || claimRows.length === 0) {
    console.log(`[game-published-notify] game ${game_id} already notified — skipping (publish_source=immediate)`);
    return new Response(JSON.stringify({ notified: 0, pushed: 0, reason: "already_notified" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  let result;
  try {
    result = await notifyNewGameMembers(supabase, {
      gameID: game_id,
      gameTitle: game_title,
      gameDateTime: game_date_time,
      clubID: club_id,
      clubName: club_name,
      createdByUserID: created_by_user_id,
      skillLevel: skill_level,
      clubTimezone: club_timezone,
    });
  } catch (err) {
    // Roll back the idempotency stamp so the next call (or cron, if publish_at
    // is non-null) can retry.
    await supabase
      .from("games")
      .update({ published_notification_sent_at: null })
      .eq("id", game_id);
    console.error("[game-published-notify] fan-out failed:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  console.log(`[game-published-notify] game=${game_id} club=${club_id} publish_source=immediate notified=${result.notified} pushed=${result.pushed} stale=${result.staleTokensCleared}`);
  return new Response(JSON.stringify({
    notified: result.notified,
    pushed: result.pushed,
    stale_tokens_cleared: result.staleTokensCleared,
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
