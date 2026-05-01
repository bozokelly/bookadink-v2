// connect-onboarding — Supabase Edge Function
// Creates or retrieves a Stripe Connect Express account for a club and returns
// an onboarding URL that the iOS app opens in a Safari sheet.
//
// On return from Stripe onboarding, Stripe sends an `account.updated` webhook.
// Until that webhook fires, `onboarding_complete` and `payouts_enabled` remain false.
// The iOS app re-checks the status when the Settings sheet re-appears after Safari dismissal.
//
// Required secrets:
//   STRIPE_SECRET_KEY        — Stripe secret key
//   SUPABASE_SERVICE_ROLE_KEY — injected automatically by Supabase runtime
//
// Request body: { club_id: string, return_url: string }
// Response:     { onboarding_url: string }
//
// Deploy: supabase functions deploy connect-onboarding --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID } from "../_shared/validate.ts";
import { isRateLimited } from "../_shared/rateLimit.ts";
import { getCallerID } from "../_shared/auth.ts";

// Only allow the app's custom URL scheme as a return destination.
const ALLOWED_RETURN_URL_SCHEME = "bookadink://";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface RequestBody {
  club_id: string;
  return_url: string;
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

  const { club_id, return_url } = body;
  if (!club_id || !isUUID(club_id)) {
    return new Response(
      JSON.stringify({ error: "club_id is required and must be a valid UUID" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
  if (!return_url || !return_url.startsWith(ALLOWED_RETURN_URL_SCHEME)) {
    return new Response(
      JSON.stringify({ error: "return_url must use the bookadink:// scheme" }),
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

  // Verify caller owns this club
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    return new Response(
      JSON.stringify({ error: "Authentication required" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
  const { data: clubOwnerRow } = await supabase
    .from("clubs").select("created_by").eq("id", club_id).single();
  if (!clubOwnerRow || clubOwnerRow.created_by !== callerID) {
    console.warn("[connect-onboarding] ownership check failed: user", callerID, "club", club_id);
    return new Response(
      JSON.stringify({ error: "Not authorized" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Rate limit: 10 onboarding attempts per club per minute
  if (await isRateLimited(supabase, `connect-onboard:${club_id}`, 60, 10)) {
    return new Response(
      JSON.stringify({ error: "Too many requests. Please try again shortly." }),
      { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Gate: check can_accept_payments entitlement before proceeding.
  // Deny by default — if no row exists, block the request.
  const { data: entitlement } = await supabase
    .from("club_entitlements")
    .select("can_accept_payments")
    .eq("club_id", club_id)
    .maybeSingle();

  if (!entitlement || !entitlement.can_accept_payments) {
    return new Response(
      JSON.stringify({ error: "Accepting payments requires a Starter or Pro plan." }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Check if this club already has a Connect account
  const { data: existingRow } = await supabase
    .from("club_stripe_accounts")
    .select("stripe_account_id")
    .eq("club_id", club_id)
    .maybeSingle();

  let stripeAccountID: string;

  if (existingRow?.stripe_account_id) {
    stripeAccountID = existingRow.stripe_account_id;
  } else {
    // Create a new Stripe Express account
    const createBody = new URLSearchParams({
      type: "express",
      "capabilities[transfers][requested]": "true",
      "capabilities[card_payments][requested]": "true",
      "metadata[club_id]": club_id,
    });

    const createResp = await fetch("https://api.stripe.com/v1/accounts", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: createBody.toString(),
    });

    const createData = await createResp.json();
    if (!createResp.ok) {
      console.error("[connect-onboarding] Stripe create account error — status:", createResp.status, "body:", JSON.stringify(createData));
      return new Response(
        JSON.stringify({ error: `Stripe error (${createResp.status}): ${JSON.stringify(createData?.error ?? createData)}` }),
        { status: createResp.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    stripeAccountID = createData.id;

    // Persist to club_stripe_accounts
    await supabase.from("club_stripe_accounts").insert({
      club_id,
      stripe_account_id: stripeAccountID,
      onboarding_complete: false,
      payouts_enabled: false,
    });

    // Denormalise onto the clubs row for fast lookup at payment-intent creation
    await supabase
      .from("clubs")
      .update({ stripe_connect_id: stripeAccountID })
      .eq("id", club_id);
  }

  // Generate an Account Link (onboarding URL) for the Express account.
  // Stripe distinguishes two redirect paths:
  //   return_url  — user completed all required steps
  //   refresh_url — the link expired mid-flow
  //
  // Stripe Account Links API requires HTTPS URLs — custom URL schemes (bookadink://) are
  // rejected with url_invalid. We route through the stripe-connect-redirect edge function
  // which returns an HTML page with a meta-refresh to the bookadink:// deep link.
  const supabaseURL = Deno.env.get("SUPABASE_URL") ?? "";
  const clubIDLower = club_id.toLowerCase();
  const linkBody = new URLSearchParams({
    account: stripeAccountID,
    return_url: `${supabaseURL}/functions/v1/stripe-connect-redirect?status=complete&club_id=${clubIDLower}`,
    refresh_url: `${supabaseURL}/functions/v1/stripe-connect-redirect?status=refresh&club_id=${clubIDLower}`,
    type: "account_onboarding",
  });

  const linkResp = await fetch("https://api.stripe.com/v1/account_links", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: linkBody.toString(),
  });

  const linkData = await linkResp.json();
  if (!linkResp.ok) {
    console.error("[connect-onboarding] Stripe account_links error — status:", linkResp.status, "body:", JSON.stringify(linkData));
    console.error("[connect-onboarding] URLs sent to Stripe — return_url:", `bookadink://stripe-return/${club_id.toLowerCase()}`, "refresh_url:", `bookadink://stripe-refresh/${club_id.toLowerCase()}`);
    return new Response(
      JSON.stringify({ error: `Stripe error (${linkResp.status}): ${JSON.stringify(linkData?.error ?? linkData)}` }),
      { status: linkResp.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  return new Response(
    JSON.stringify({ onboarding_url: linkData.url }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
