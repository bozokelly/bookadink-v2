// send-review-prompts
// Finds games that ended 24 hours ago and sends a review prompt notification
// to each confirmed attendee who hasn't already received one.
//
// Schedule via pg_cron (run hourly, window catches games ending 23–25h ago):
//   SELECT cron.schedule('send-review-prompts', '0 * * * *', $$
//     SELECT net.http_post(
//       url := 'https://<project-ref>.supabase.co/functions/v1/send-review-prompts',
//       headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb
//     )
//   $$);

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req: Request) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Find games that ended between 23h and 25h ago (2h window to handle cron drift)
  const now = new Date();
  const windowEnd = new Date(now.getTime() - 23 * 60 * 60 * 1000).toISOString();
  const windowStart = new Date(now.getTime() - 25 * 60 * 60 * 1000).toISOString();

  // We compute game end time as date_time + duration_minutes via a raw RPC
  // since PostgREST can't do column arithmetic in filters.
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
    return new Response(JSON.stringify({ sent: 0, reason: "no_games_in_window" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  let sentCount = 0;

  for (const game of games) {
    // Get all confirmed bookings for this game
    const { data: bookings, error: bookingsError } = await supabase
      .from("bookings")
      .select("user_id")
      .eq("game_id", game.id)
      .eq("status", "confirmed");

    if (bookingsError || !bookings) continue;

    for (const booking of bookings) {
      const userID = booking.user_id;

      // Check if a review prompt notification already exists for this user+game
      const { data: existing } = await supabase
        .from("notifications")
        .select("id")
        .eq("user_id", userID)
        .eq("type", "game_review_request")
        .eq("reference_id", game.id)
        .maybeSingle();

      if (existing) continue; // Already sent

      // Insert notification — DB trigger fires email via send-notification-email
      const { error: notifError } = await supabase
        .from("notifications")
        .insert({
          user_id: userID,
          title: `How was ${game.title}?`,
          body: "Tap to leave a quick rating and help your club improve future sessions.",
          type: "game_review_request",
          reference_id: game.id,
          read: false,
        });

      if (notifError) {
        console.error(`Failed to insert review notification for user ${userID}:`, notifError);
      } else {
        sentCount++;
      }
    }
  }

  console.log(`send-review-prompts: sent ${sentCount} prompt(s) for ${games.length} game(s)`);
  return new Response(
    JSON.stringify({ sent: sentCount, games: games.length }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});
