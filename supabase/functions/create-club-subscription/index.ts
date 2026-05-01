// create-club-subscription — Supabase Edge Function
// Creates a Stripe Subscription on the PLATFORM account for a club owner.
//
// Phase 4 Part 1: Subscription Foundation
//
// Flow:
//   1. Resolve club → owner profile
//   2. Get or create a Stripe Customer for the owner (stored on profiles.stripe_customer_id)
//   3. Create a Stripe Subscription using the supplied price_id
//   4. Upsert the subscription record into club_subscriptions
//   5. Return subscription_id + client_secret (if payment collection required)
//
// Required secrets (set via `supabase secrets set`):
//   STRIPE_SECRET_KEY         — platform Stripe secret key (sk_test_... / sk_live_...)
//   SUPABASE_SERVICE_ROLE_KEY — injected automatically by Supabase runtime
//
// Stripe Price metadata required:
//   plan_type: "starter" | "pro"   — set on each Price in the Stripe Dashboard
//
// Deploy: supabase functions deploy create-club-subscription --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID } from "../_shared/validate.ts";
import { isRateLimited } from "../_shared/rateLimit.ts";
import { getCallerID } from "../_shared/auth.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Pin to a stable API version that includes payment_intent on Invoice objects.
// Stripe 2025+ moved it; 2023-10-16 is the last broadly-supported version before that change.
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

function stripeGet(path: string, stripeKey: string) {
  return fetch(`https://api.stripe.com/v1/${path}`, {
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Stripe-Version": STRIPE_API_VERSION,
    },
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

  let club_id: string, price_id: string;
  try {
    const body = await req.json();
    club_id = body.club_id;
    price_id = body.price_id;
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
  // Stripe price IDs start with "price_"
  if (!price_id || typeof price_id !== "string" || !price_id.startsWith("price_") || price_id.length > 64) {
    return new Response(
      JSON.stringify({ error: "price_id is invalid" }),
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
  const { data: clubOwnerRow } = await supabase
    .from("clubs").select("created_by").eq("id", club_id).single();
  if (!clubOwnerRow || clubOwnerRow.created_by !== callerID) {
    console.warn("[create-club-subscription] ownership check failed: user", callerID, "club", club_id);
    return new Response(
      JSON.stringify({ error: "Not authorized" }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Rate limit: 5 subscription attempts per user per minute
  if (await isRateLimited(supabase, `create-sub:${callerID}`, 60, 5)) {
    return new Response(
      JSON.stringify({ error: "Too many requests. Please try again shortly." }),
      { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 1: Resolve club → owner
  const { data: club, error: clubError } = await supabase
    .from("clubs")
    .select("id, created_by")
    .eq("id", club_id)
    .single();

  if (clubError || !club) {
    return new Response(
      JSON.stringify({ error: "Club not found" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 2: Get owner profile
  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("id, full_name, stripe_customer_id")
    .eq("id", club.created_by)
    .single();

  if (profileError || !profile) {
    return new Response(
      JSON.stringify({ error: "Owner profile not found" }),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 3: Get or create Stripe Customer (idempotent — one customer per owner)
  let stripeCustomerID: string = profile.stripe_customer_id ?? "";

  if (!stripeCustomerID) {
    const customerParams = new URLSearchParams({
      "metadata[supabase_user_id]": profile.id,
    });
    if (profile.full_name) {
      customerParams.append("name", profile.full_name);
    }

    const customerRes = await stripePost("customers", customerParams, stripeKey);
    const customerData = await customerRes.json();

    if (!customerRes.ok) {
      console.error("[create-club-subscription] Stripe customer create error:", customerData);
      return new Response(
        JSON.stringify({ error: customerData?.error?.message ?? "Failed to create billing customer" }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    stripeCustomerID = customerData.id;

    // Persist customer ID so subsequent subscriptions for this owner reuse the same customer
    await supabase
      .from("profiles")
      .update({ stripe_customer_id: stripeCustomerID })
      .eq("id", profile.id);
  }

  // Step 4: Resolve plan_type from Price metadata
  const priceRes = await stripeGet(`prices/${price_id}`, stripeKey);
  const priceData = await priceRes.json();
  if (!priceRes.ok) {
    console.error("[create-club-subscription] Stripe price fetch error:", priceData);
    return new Response(
      JSON.stringify({ error: priceData?.error?.message ?? "Invalid price_id" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
  // Reject non-AUD prices to prevent USD subscriptions being created accidentally.
  if (priceData.currency && priceData.currency !== "aud") {
    console.error("[create-club-subscription] Rejected non-AUD price currency:", priceData.currency, "price:", price_id);
    return new Response(
      JSON.stringify({ error: "Only AUD subscription prices are supported." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const planType: string = priceData.metadata?.plan_type ?? "starter";

  // Step 4b: Check for an existing subscription — upgrade if already active.
  // Creating a second subscription would leave two active subs in Stripe and the
  // new one starts as 'incomplete', so the webhook never sees the upgrade until
  // payment completes. Instead, update the existing subscription's price in-place.
  {
    const { data: existingSubRow } = await supabase
      .from("club_subscriptions")
      .select("stripe_subscription_id, status, plan_type")
      .eq("club_id", club_id)
      .maybeSingle();

    if (existingSubRow && (existingSubRow.status === "active" || existingSubRow.status === "past_due")) {
      // Already on this exact plan — return success immediately, no charge.
      if (existingSubRow.plan_type === planType) {
        console.log("[create-club-subscription] already on plan:", planType, "— returning active");
        return new Response(
          JSON.stringify({
            subscription_id: existingSubRow.stripe_subscription_id,
            status: "active",
            client_secret: null,
          }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Different plan → upgrade by updating the existing Stripe subscription.
      const existingStripeSubID: string = existingSubRow.stripe_subscription_id;
      console.log(
        "[create-club-subscription] upgrade:",
        existingSubRow.plan_type, "→", planType,
        "sub:", existingStripeSubID
      );

      // Fetch existing subscription to get the item ID.
      const currentSubRes = await stripeGet(`subscriptions/${existingStripeSubID}`, stripeKey);
      const currentSubData = await currentSubRes.json();
      if (!currentSubRes.ok) {
        console.error("[create-club-subscription] fetch existing sub error:", currentSubData?.error?.message);
        return new Response(
          JSON.stringify({ error: currentSubData?.error?.message ?? "Failed to retrieve current subscription" }),
          { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const itemID: string | null = currentSubData.items?.data?.[0]?.id ?? null;
      if (!itemID) {
        console.error("[create-club-subscription] no item on existing sub:", existingStripeSubID);
        return new Response(
          JSON.stringify({ error: "Could not resolve subscription item for upgrade" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Update the Stripe subscription: swap price, always invoice for the prorated
      // difference so the charge occurs immediately using the stored payment method.
      const upgradeParams = new URLSearchParams({
        [`items[0][id]`]: itemID,
        [`items[0][price]`]: price_id,
        proration_behavior: "always_invoice",
        payment_behavior: "allow_incomplete",
        "metadata[plan_type]": planType,
        "metadata[club_id]": club_id,
      });

      const upgradeRes = await stripePost(`subscriptions/${existingStripeSubID}`, upgradeParams, stripeKey);
      const upgradeData = await upgradeRes.json();
      if (!upgradeRes.ok) {
        console.error("[create-club-subscription] Stripe upgrade error:", upgradeData?.error?.message);
        return new Response(
          JSON.stringify({ error: upgradeData?.error?.message ?? "Failed to upgrade subscription" }),
          { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      console.log("[create-club-subscription] upgrade status:", upgradeData.status, "| plan_type:", planType);

      const upgradePeriodEnd: string | null = upgradeData.current_period_end
        ? new Date(upgradeData.current_period_end * 1000).toISOString()
        : null;

      // Upsert DB with new plan_type immediately (same stripe_subscription_id).
      const { error: upgradeUpsertError } = await supabase
        .from("club_subscriptions")
        .upsert({
          club_id,
          stripe_subscription_id: upgradeData.id,
          plan_type: planType,
          status: upgradeData.status,
          current_period_end: upgradePeriodEnd,
          updated_at: new Date().toISOString(),
          subscription_source: 'stripe',
        }, { onConflict: "club_id" });
      if (upgradeUpsertError) {
        console.error("[create-club-subscription] upgrade upsert error:", upgradeUpsertError.message);
      }

      // Denormalise tier to clubs table.
      const upgradeTier = upgradeData.status === "active" ? planType : existingSubRow.plan_type;
      await supabase.from("clubs").update({ subscription_tier: upgradeTier }).eq("id", club_id);

      // Derive entitlements — webhook will fire too, but this ensures instant unlock.
      const { error: upgradeEntitlementError } = await supabase.rpc(
        "derive_club_entitlements",
        { p_club_id: club_id }
      );
      if (upgradeEntitlementError) {
        console.warn("[create-club-subscription] derive_club_entitlements upgrade error:", upgradeEntitlementError.message);
      }

      return new Response(
        JSON.stringify({
          subscription_id: upgradeData.id,
          status: upgradeData.status,
          client_secret: null,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  }

  // Step 5: Create Stripe Subscription (no nested expand — fetch invoice separately).
  const subParams = new URLSearchParams({
    customer: stripeCustomerID,
    "items[0][price]": price_id,
    payment_behavior: "default_incomplete",
    "payment_settings[save_default_payment_method]": "on_subscription",
    "metadata[club_id]": club_id,
    "metadata[plan_type]": planType,
  });

  const subRes = await stripePost("subscriptions", subParams, stripeKey);
  const subData = await subRes.json();

  console.log("[create-club-subscription] sub status:", subData.status, "| invoice:", subData.latest_invoice);

  if (!subRes.ok) {
    console.error("[create-club-subscription] Stripe error:", subData?.error?.message);
    return new Response(
      JSON.stringify({ error: subData?.error?.message ?? "Failed to create subscription" }),
      { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Step 6: Resolve client_secret from the subscription's latest invoice.
  // Draft invoices have no payment_intent — finalize first if needed, then fetch the PI.
  let clientSecret: string | null = null;
  const invoiceID: string | null =
    typeof subData.latest_invoice === "string"
      ? subData.latest_invoice
      : subData.latest_invoice?.id ?? null;

  console.log("[create-club-subscription] invoice ID:", invoiceID);

  if (invoiceID) {
    // Fetch the raw invoice to check its status.
    const invRes = await stripeGet(`invoices/${invoiceID}`, stripeKey);
    const invData = await invRes.json();

    if (!invRes.ok) {
      console.error("[create-club-subscription] invoice fetch error:", invData?.error?.message);
    } else {
      console.log("[create-club-subscription] invoice status:", invData.status, "| pi:", invData.payment_intent);

      // With API version 2023-10-16, payment_intent is a string ID on the invoice.
      const piID: string | null =
        typeof invData.payment_intent === "string" ? invData.payment_intent
        : invData.payment_intent?.id ?? null;

      if (piID) {
        const piRes = await stripeGet(`payment_intents/${piID}`, stripeKey);
        const piData = await piRes.json();
        if (piRes.ok) {
          clientSecret = piData.client_secret ?? null;
          console.log("[create-club-subscription] client_secret:", clientSecret ? "ok" : "null");
        } else {
          console.error("[create-club-subscription] PI fetch error:", piData?.error?.message);
        }
      } else {
        console.warn("[create-club-subscription] no PI on invoice:", invoiceID);
      }
    }
  } else {
    console.warn("[create-club-subscription] no invoice ID on subscription");
  }

  // Step 7: Upsert club_subscriptions (idempotent on club_id)
  const periodEnd = subData.current_period_end
    ? new Date(subData.current_period_end * 1000).toISOString()
    : null;

  const { error: upsertError } = await supabase
    .from("club_subscriptions")
    .upsert({
      club_id,
      stripe_subscription_id: subData.id,
      plan_type: planType,
      status: subData.status,
      current_period_end: periodEnd,
      updated_at: new Date().toISOString(),
      subscription_source: 'stripe',
    }, { onConflict: "club_id" });

  if (upsertError) {
    console.error("[create-club-subscription] upsert error:", upsertError.message);
  }

  // Step 8: Derive entitlements — triggers the SQL resolver, no logic here.
  // At this point status is 'incomplete', so entitlements will be free-tier until
  // the webhook fires after successful payment and calls this again with 'active'.
  const { error: entitlementError } = await supabase.rpc(
    "derive_club_entitlements",
    { p_club_id: club_id }
  );
  if (entitlementError) {
    // Non-fatal: subscription was created. Webhook will correct entitlements on payment.
    console.warn("[create-club-subscription] derive_club_entitlements error:", entitlementError.message);
  }

  return new Response(
    JSON.stringify({
      subscription_id: subData.id,
      status: subData.status,
      client_secret: clientSecret,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
