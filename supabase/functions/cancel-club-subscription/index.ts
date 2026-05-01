// cancel-club-subscription — Supabase Edge Function
// Cancels a club's Stripe subscription at the end of the current billing period.
//
// Flow:
//   1. Verify the caller is the club owner via their user JWT
//   2. Resolve club → club_subscriptions row
//   3. Call Stripe to cancel at period end (cancel_at_period_end: true)
//   4. Update club_subscriptions.status → "canceling" (still active until period end)
//   5. Re-derive entitlements (stays active until period end)
//
// Required secrets:
//   STRIPE_SECRET_KEY         — platform Stripe secret key
//   SUPABASE_SERVICE_ROLE_KEY — injected automatically by Supabase runtime
//
// Deploy: supabase functions deploy cancel-club-subscription --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID } from "../_shared/validate.ts";
import { isRateLimited } from "../_shared/rateLimit.ts";
import { getCallerID } from "../_shared/auth.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const STRIPE_API_VERSION = "2023-10-16";

function stripePost(path: string, params: URLSearchParams, stripeKey: string) {
  return fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
      "Stripe-Version": STRIPE_API_VERSION,
    },
    body: params.toString(),
  });
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) {
    return new Response(
      JSON.stringify({ error: "Payment service not configured" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  let club_id: string;
  try {
    const body = await req.json();
    club_id = body.club_id;
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!club_id || !isUUID(club_id)) {
    return new Response(
      JSON.stringify({ error: "club_id is required and must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );

  // Verify caller owns this club
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response(
      JSON.stringify({ error: "Authentication required" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
  const { data: clubRow } = await supabase
    .from("clubs").select("created_by").eq("id", club_id).single();
  if (!clubRow || clubRow.created_by !== callerID) {
    console.warn("[cancel-club-subscription] ownership check failed: user", callerID, "club", club_id);
    return new Response(
      JSON.stringify({ error: "Not authorized" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Rate limit: 3 cancellation attempts per club per 5 minutes
  if (await isRateLimited(supabase, `cancel-sub:${club_id}`, 300, 3)) {
    return new Response(
      JSON.stringify({ error: "Too many requests. Please try again shortly." }),
      { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 1: Resolve the subscription record for this club
  const { data: sub } = await supabase
    .from("club_subscriptions")
    .select("id, stripe_subscription_id, status")
    .eq("club_id", club_id)
    .single();

  // If there is no Stripe subscription on record (e.g. manually-granted tier),
  // just immediately downgrade to free in the DB — no Stripe call needed.
  if (!sub?.stripe_subscription_id) {
    console.log("[cancel-club-subscription] No Stripe sub found — downgrading club directly to free", club_id);

    await supabase
      .from("clubs")
      .update({ subscription_tier: "free" })
      .eq("id", club_id);

    if (sub) {
      await supabase
        .from("club_subscriptions")
        .update({ status: "canceled", updated_at: new Date().toISOString() })
        .eq("club_id", club_id);
    }

    await supabase.rpc("derive_club_entitlements", { p_club_id: club_id });

    return new Response(
      JSON.stringify({ status: "canceled", current_period_end: null }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 2: Tell Stripe to cancel at period end (not immediately)
  const cancelParams = new URLSearchParams({ cancel_at_period_end: "true" });
  const cancelRes = await stripePost(
    `subscriptions/${sub.stripe_subscription_id}`,
    cancelParams,
    stripeKey
  );
  const cancelData = await cancelRes.json();

  if (!cancelRes.ok) {
    console.error("[cancel-club-subscription] Stripe error:", cancelData?.error?.message);
    return new Response(
      JSON.stringify({ error: cancelData?.error?.message ?? "Failed to cancel subscription" }),
      { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 3: Update DB status to reflect the scheduled cancellation
  const periodEnd = cancelData.current_period_end
    ? new Date(cancelData.current_period_end * 1000).toISOString()
    : null;

  const { error: updateError } = await supabase
    .from("club_subscriptions")
    .update({
      status: "canceling",
      current_period_end: periodEnd,
      updated_at: new Date().toISOString(),
    })
    .eq("club_id", club_id);

  if (updateError) {
    console.error("[cancel-club-subscription] DB update error:", updateError.message);
    // Non-fatal — Stripe webhook will correct state on actual cancellation
  }

  // Step 4: Re-derive entitlements (still active until period end)
  const { error: entitlementError } = await supabase.rpc(
    "derive_club_entitlements",
    { p_club_id: club_id }
  );
  if (entitlementError) {
    console.warn("[cancel-club-subscription] derive_club_entitlements error:", entitlementError.message);
  }

  return new Response(
    JSON.stringify({ status: "canceling", current_period_end: periodEnd }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
