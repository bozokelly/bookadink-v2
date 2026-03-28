// archive-old-games
// Invoked by pg_cron (or manually) to soft-delete free games whose end time has passed.
// Paid games are never archived here — they are handled by Stripe webhooks / manual admin action.
//
// Schedule (add in Supabase Dashboard → Database → Extensions → pg_cron):
//   SELECT cron.schedule('archive-old-games', '0 * * * *', $$
//     SELECT net.http_post(
//       url := 'https://<project-ref>.supabase.co/functions/v1/archive-old-games',
//       headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb
//     )
//   $$);

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req: Request) => {
  // Allow manual GET calls during testing in addition to POST from pg_cron
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Archive free games where the game has actually finished (scheduled_at + duration_minutes)
  // plus a grace window, and haven't been archived yet.
  //
  // PostgREST can't do column arithmetic in a filter, so we use a raw RPC / SQL approach:
  // cast scheduled_at + duration interval and compare to now - grace.
  const GRACE_MINUTES = 30;

  const { data, error } = await supabase.rpc("archive_finished_free_games", {
    grace_minutes: GRACE_MINUTES,
  });

  if (error) {
    console.error("archive-old-games error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // rpc returns the count directly as an integer
  const archivedCount = typeof data === "number" ? data : (data?.length ?? 0);
  console.log(`archive-old-games: archived ${archivedCount} game(s)`);

  return new Response(
    JSON.stringify({ archived: archivedCount }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});
