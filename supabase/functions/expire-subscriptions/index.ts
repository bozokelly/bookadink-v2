// expire-subscriptions — Supabase Edge Function
//
// Safety-net cron job: catches any 'canceling' subscriptions whose billing period
// has already ended but whose status was not updated by the Stripe webhook
// (e.g. missed delivery, network failure, replay gap).
//
// Flow:
//   1. Query club_subscriptions WHERE status = 'canceling' AND current_period_end < NOW()
//   2. For each: mark status = 'canceled', update clubs.subscription_tier = 'free',
//      call derive_club_entitlements to lock paid features
//   3. Return a summary of clubs processed
//
// Schedule (pg_cron — run once after deploying):
//   SELECT cron.schedule(
//     'expire-subscriptions',
//     '0 * * * *',   -- every hour
//     $$ SELECT net.http_post(
//          url    := 'https://<ref>.supabase.co/functions/v1/expire-subscriptions',
//          headers := '{"Authorization":"Bearer <service-role-key>"}'::jsonb
//        ) $$
//   );
//
// Deploy: supabase functions deploy expire-subscriptions --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req: Request) => {
  // Only allow internal calls (service-role Authorization header).
  const authHeader = req.headers.get("Authorization") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!authHeader.includes(serviceRoleKey)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    serviceRoleKey
  );

  // Find all subscriptions in 'canceling' state whose period has already ended.
  const { data: expired, error: fetchError } = await supabase
    .from("club_subscriptions")
    .select("club_id, current_period_end")
    .eq("status", "canceling")
    .lt("current_period_end", new Date().toISOString());

  if (fetchError) {
    console.error("[expire-subscriptions] fetch error:", fetchError.message);
    return new Response(JSON.stringify({ error: fetchError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (!expired || expired.length === 0) {
    return new Response(JSON.stringify({ processed: 0, clubs: [] }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const results: { club_id: string; ok: boolean; error?: string }[] = [];

  for (const row of expired) {
    const clubID: string = row.club_id;
    try {
      // Mark subscription as canceled.
      const { error: updateError } = await supabase
        .from("club_subscriptions")
        .update({ status: "canceled", updated_at: new Date().toISOString() })
        .eq("club_id", clubID);

      if (updateError) throw new Error(updateError.message);

      // Revert subscription_tier on clubs table.
      const { error: tierError } = await supabase
        .from("clubs")
        .update({ subscription_tier: "free" })
        .eq("id", clubID);

      if (tierError) {
        // Non-fatal — derive_club_entitlements will still use the correct logic.
        console.warn("[expire-subscriptions] tier update failed for", clubID, tierError.message);
      }

      // Re-derive entitlements → locks paid features.
      const { error: entitlementError } = await supabase.rpc(
        "derive_club_entitlements",
        { p_club_id: clubID }
      );

      if (entitlementError) throw new Error(entitlementError.message);

      console.log("[expire-subscriptions] expired club:", clubID);
      results.push({ club_id: clubID, ok: true });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("[expire-subscriptions] failed for club", clubID, msg);
      results.push({ club_id: clubID, ok: false, error: msg });
    }
  }

  return new Response(
    JSON.stringify({ processed: results.length, clubs: results }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});
