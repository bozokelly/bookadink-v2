// game-publish-release — Supabase Edge Function (cron-driven)
//
// Released the delayed-publish notification path. Invoked every 2 minutes by
// pg_cron (see migration 20260430_release_scheduled_games_rpc.sql).
//
// Flow:
//   1. Call release_scheduled_games() RPC. The RPC atomically stamps
//      published_notification_sent_at = now() on every game whose publish_at
//      has arrived and that has not yet been notified, and RETURNs the rows.
//      The UPDATE...RETURNING is the idempotency guard — concurrent ticks
//      cannot double-claim a row.
//   2. For each returned row, fan out via _shared/notify-new-game.ts — the
//      same module used by game-published-notify for the immediate-publish
//      path. Identical payload, identical APNs grouping, identical email
//      hook (via the notifications row insert).
//   3. If a fan-out throws, roll back the idempotency stamp for that single
//      game so the next tick retries it.
//
// Deploy: supabase functions deploy game-publish-release --no-verify-jwt
// Auth:   anonymous; cron passes the project anon key in the Bearer header,
//         which is sufficient for --no-verify-jwt. The function uses the
//         service-role key from env to query and update the DB.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyNewGameMembers } from "../_shared/notify-new-game.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface ReleasedGameRow {
  game_id: string;
  game_title: string;
  game_date_time: string;
  club_id: string;
  club_name: string;
  created_by_user_id: string;
  skill_level: string | null;
  club_timezone: string | null;
}

serve(async (req: Request) => {
  // Allow GET for manual smoke testing in addition to POST from pg_cron.
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { data: rows, error: rpcError } = await supabase.rpc("release_scheduled_games");
  if (rpcError) {
    console.error("[game-publish-release] release_scheduled_games() failed:", rpcError);
    return new Response(JSON.stringify({ error: rpcError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const games = (rows ?? []) as ReleasedGameRow[];
  if (games.length === 0) {
    return new Response(JSON.stringify({ released: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  let totalNotified = 0;
  let totalPushed = 0;
  let totalStaleCleared = 0;
  let succeeded = 0;
  let failed = 0;

  // Fan out per game. Each game's idempotency was already claimed by the RPC,
  // so a partial failure on one game does not block the others. On a thrown
  // error we roll back that one game's stamp so the next tick retries it.
  for (const row of games) {
    try {
      const result = await notifyNewGameMembers(supabase, {
        gameID: row.game_id,
        gameTitle: row.game_title,
        gameDateTime: row.game_date_time,
        clubID: row.club_id,
        clubName: row.club_name,
        createdByUserID: row.created_by_user_id,
        skillLevel: row.skill_level,
        clubTimezone: row.club_timezone,
      });
      totalNotified += result.notified;
      totalPushed += result.pushed;
      totalStaleCleared += result.staleTokensCleared;
      succeeded++;
      console.log(`[game-publish-release] game=${row.game_id} club=${row.club_id} publish_source=delayed notified=${result.notified} pushed=${result.pushed} stale=${result.staleTokensCleared}`);
    } catch (err) {
      failed++;
      console.error(`[game-publish-release] game=${row.game_id} club=${row.club_id} publish_source=delayed FAILED:`, err);
      // Roll back the idempotency stamp so the next cron tick retries.
      const { error: rollbackError } = await supabase
        .from("games")
        .update({ published_notification_sent_at: null })
        .eq("id", row.game_id);
      if (rollbackError) {
        console.error(`[game-publish-release] game=${row.game_id} rollback failed:`, rollbackError);
      }
    }
  }

  return new Response(JSON.stringify({
    released: succeeded,
    failed,
    notified: totalNotified,
    pushed: totalPushed,
    stale_tokens_cleared: totalStaleCleared,
  }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
