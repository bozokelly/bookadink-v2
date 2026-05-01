// stripe-account-status — Supabase Edge Function
// Called by the iOS app after the owner returns from Stripe onboarding.
// Fetches the live account state directly from the Stripe API, updates
// club_stripe_accounts, and returns the current readiness status.
//
// This is needed because the account.updated webhook may be delayed — the
// app needs immediate feedback when the owner taps "Check Status" or returns.
//
// Required secrets:
//   STRIPE_SECRET_KEY        — Stripe secret key
//   SUPABASE_SERVICE_ROLE_KEY — injected automatically by Supabase runtime
//
// Request body: { club_id: string }
// Response:     { stripe_account_id: string, onboarding_complete: boolean, payouts_enabled: boolean }
//
// Deploy: supabase functions deploy stripe-account-status --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID } from "../_shared/validate.ts";
import { getCallerID } from "../_shared/auth.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface RequestBody {
  club_id: string;
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

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const { club_id } = body;
  if (!club_id || !isUUID(club_id)) {
    return new Response(
      JSON.stringify({ error: "club_id is required and must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) {
    return new Response(
      JSON.stringify({ error: "Payment service not configured" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );

  // Verify caller is the club owner or an admin
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response(
      JSON.stringify({ error: "Authentication required" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Caller must be the club owner or an active admin
  const { data: ownerRow } = await supabase
    .from("clubs")
    .select("created_by")
    .eq("id", club_id)
    .single();

  if (!ownerRow) {
    return new Response(
      JSON.stringify({ error: "Club not found" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const isOwner = ownerRow.created_by === callerID;
  if (!isOwner) {
    const { data: memberRow } = await supabase
      .from("club_members")
      .select("role, status")
      .eq("club_id", club_id)
      .eq("user_id", callerID)
      .maybeSingle();

    const isAdmin = memberRow?.role === "admin" && memberRow?.status === "approved";
    if (!isAdmin) {
      return new Response(
        JSON.stringify({ error: "Not authorized" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  }

  // Look up the club's Stripe account ID
  const { data: accountRow } = await supabase
    .from("club_stripe_accounts")
    .select("stripe_account_id, onboarding_complete, payouts_enabled")
    .eq("club_id", club_id)
    .maybeSingle();

  if (!accountRow?.stripe_account_id) {
    // No account yet — return zeroed status (not an error; onboarding not started)
    return new Response(
      JSON.stringify({ stripe_account_id: null, onboarding_complete: false, payouts_enabled: false }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Fetch live account state from Stripe
  const stripeResp = await fetch(
    `https://api.stripe.com/v1/accounts/${accountRow.stripe_account_id}`,
    {
      headers: { Authorization: `Bearer ${stripeKey}` },
    }
  );

  if (!stripeResp.ok) {
    const stripeErr = await stripeResp.json().catch(() => ({}));
    console.error("[stripe-account-status] Stripe fetch error:", JSON.stringify(stripeErr));
    // Return stale DB values rather than failing — better UX than an error on Check Status
    return new Response(
      JSON.stringify({
        stripe_account_id: accountRow.stripe_account_id,
        onboarding_complete: accountRow.onboarding_complete,
        payouts_enabled: accountRow.payouts_enabled,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const stripeAccount = await stripeResp.json();
  const onboardingComplete: boolean = stripeAccount.details_submitted ?? false;
  const payoutsEnabled: boolean = stripeAccount.payouts_enabled ?? false;

  // Persist refreshed status back to DB so the webhook catch-up is idempotent
  await supabase
    .from("club_stripe_accounts")
    .update({ onboarding_complete: onboardingComplete, payouts_enabled: payoutsEnabled })
    .eq("stripe_account_id", accountRow.stripe_account_id);

  console.log(
    "[stripe-account-status] refreshed club:", club_id,
    "details_submitted:", onboardingComplete,
    "payouts_enabled:", payoutsEnabled
  );

  return new Response(
    JSON.stringify({
      stripe_account_id: accountRow.stripe_account_id,
      onboarding_complete: onboardingComplete,
      payouts_enabled: payoutsEnabled,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
