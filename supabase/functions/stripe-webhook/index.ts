// stripe-webhook — Supabase Edge Function
// Handles Stripe platform-account webhook events for club subscription lifecycle.
//
// Phase 4 Part 1: Subscription Foundation
//
// Handles:
//   customer.subscription.created  → upsert club_subscriptions, sync clubs.subscription_tier
//   customer.subscription.updated  → upsert club_subscriptions, sync clubs.subscription_tier
//   customer.subscription.deleted  → mark canceled, revert clubs.subscription_tier to 'free'
//   invoice.payment_failed         → mark past_due on club_subscriptions
//   invoice.payment_succeeded      → no-op (subscription.updated event handles this)
//
// Idempotency: all writes are upserts or conditional updates keyed on stripe_subscription_id.
// Replaying the same event twice produces the same result.
//
// Required secrets (set via `supabase secrets set`):
//   STRIPE_SECRET_KEY          — platform Stripe secret key
//   STRIPE_WEBHOOK_SECRET      — signing secret from Stripe Dashboard webhook config
//   SUPABASE_SERVICE_ROLE_KEY  — injected automatically by Supabase runtime
//
// Deploy: supabase functions deploy stripe-webhook --no-verify-jwt
// Register endpoint in Stripe Dashboard → Developers → Webhooks → Add endpoint
//   URL: https://<ref>.supabase.co/functions/v1/stripe-webhook
//   Events: customer.subscription.created, customer.subscription.updated,
//           customer.subscription.deleted, invoice.payment_failed, invoice.payment_succeeded,
//           account.updated  ← required for Connect Express onboarding completion

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// Stripe webhook signature verification
// Supabase Edge Functions don't bundle the Stripe SDK, so we verify manually.
// ---------------------------------------------------------------------------

async function verifyStripeSignature(
  payload: string,
  sigHeader: string,
  secret: string
): Promise<boolean> {
  const parts = sigHeader.split(",").reduce<Record<string, string>>((acc, part) => {
    const [k, v] = part.split("=");
    acc[k.trim()] = v?.trim() ?? "";
    return acc;
  }, {});

  const timestamp = parts["t"];
  const signature = parts["v1"];
  if (!timestamp || !signature) return false;

  // Reject events older than 5 minutes to prevent replay attacks
  const ts = parseInt(timestamp, 10);
  if (Math.abs(Date.now() / 1000 - ts) > 300) return false;

  const signedPayload = `${timestamp}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedPayload));
  const computed = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  return computed === signature;
}

// ---------------------------------------------------------------------------
// Tier derivation: maps Stripe subscription status + plan_type → internal tier
// ---------------------------------------------------------------------------

function deriveTier(status: string, planType: string | null): string {
  // "canceling" = cancel_at_period_end=true, still within paid period.
  // Features must stay active until the period ends and Stripe fires
  // customer.subscription.deleted (which sets status = "canceled").
  if ((status === "active" || status === "canceling") && planType) return planType;
  return "free";
}

// ---------------------------------------------------------------------------
// Core sync: upsert club_subscriptions + denormalise to clubs.subscription_tier
// ---------------------------------------------------------------------------

async function syncSubscription(
  supabase: ReturnType<typeof createClient>,
  sub: {
    id: string;
    status: string;
    cancel_at_period_end?: boolean;
    current_period_end: number | null;
    metadata: Record<string, string>;
    items?: { data: Array<{ current_period_end?: number }> };
  }
) {
  // current_period_end moved to items in Stripe API 2026+; fall back to top-level.
  const periodEndRaw: number | null =
    sub.current_period_end ??
    sub.items?.data?.[0]?.current_period_end ??
    null;
  const periodEnd = periodEndRaw ? new Date(periodEndRaw * 1000).toISOString() : null;

  const planType: string | null = sub.metadata?.plan_type ?? null;
  // club_id is stored in metadata by create-club-subscription.
  const clubID: string | null = sub.metadata?.club_id ?? null;

  // Map Stripe status to our internal status.
  // cancel_at_period_end=true means the subscription is still active but scheduled
  // to cancel — store as "canceling" so the iOS app can show the correct message
  // and derive_club_entitlements keeps features unlocked until the period ends.
  const effectiveStatus = sub.cancel_at_period_end ? "canceling" : sub.status;

  console.log("[stripe-webhook] syncing sub:", sub.id, "status:", sub.status, "effective:", effectiveStatus, "club:", clubID);

  // Upsert on club_id (same key as create-club-subscription) so we always update the
  // canonical row for this club. Include club_id so an INSERT never violates NOT NULL.
  const upsertPayload: Record<string, unknown> = {
    stripe_subscription_id: sub.id,
    status: effectiveStatus,
    current_period_end: periodEnd,
    updated_at: new Date().toISOString(),
    subscription_source: 'stripe',
    ...(planType ? { plan_type: planType } : {}),
    ...(clubID ? { club_id: clubID } : {}),
  };

  const { error: upsertError } = await supabase
    .from("club_subscriptions")
    .upsert(upsertPayload, {
      onConflict: clubID ? "club_id" : "stripe_subscription_id",
    });

  if (upsertError) {
    console.error("[stripe-webhook] club_subscriptions upsert error:", upsertError.message, upsertError.details);
    throw upsertError;
  }

  // Fetch club_id + current plan_type for denormalisation
  const { data: row, error: fetchError } = await supabase
    .from("club_subscriptions")
    .select("club_id, plan_type")
    .eq("stripe_subscription_id", sub.id)
    .single();

  if (fetchError || !row?.club_id) {
    console.warn("[stripe-webhook] Could not resolve club_id for subscription", sub.id);
    return;
  }

  const tier = deriveTier(effectiveStatus, planType ?? row.plan_type);

  const { error: clubUpdateError } = await supabase
    .from("clubs")
    .update({ subscription_tier: tier })
    .eq("id", row.club_id);

  if (clubUpdateError) {
    console.error("[stripe-webhook] clubs.subscription_tier update error:", clubUpdateError);
    throw clubUpdateError;
  }

  // Derive entitlements — single source of truth lives in the SQL function.
  // No entitlement logic here; just trigger the resolver.
  const { error: entitlementError } = await supabase.rpc(
    "derive_club_entitlements",
    { p_club_id: row.club_id }
  );
  if (entitlementError) {
    console.error("[stripe-webhook] derive_club_entitlements error:", entitlementError.message);
    throw entitlementError;
  }
  console.log("[stripe-webhook] entitlements derived for club:", row.club_id);
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret) {
    console.error("[stripe-webhook] STRIPE_WEBHOOK_SECRET not set");
    return new Response("Webhook not configured", { status: 500 });
  }

  const payload = await req.text();
  const sigHeader = req.headers.get("stripe-signature") ?? "";

  const valid = await verifyStripeSignature(payload, sigHeader, webhookSecret);
  if (!valid) {
    console.warn("[stripe-webhook] Signature verification failed");
    return new Response("Signature verification failed", { status: 400 });
  }

  let event: { type: string; data: { object: Record<string, unknown> } };
  try {
    event = JSON.parse(payload);
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );

  try {
    switch (event.type) {
      // ------------------------------------------------------------------
      // Subscription created or updated — sync status + tier
      // ------------------------------------------------------------------
      case "customer.subscription.created":
      case "customer.subscription.updated": {
        const sub = event.data.object as {
          id: string;
          status: string;
          current_period_end: number | null;
          metadata: Record<string, string>;
        };
        await syncSubscription(supabase, sub);
        break;
      }

      // ------------------------------------------------------------------
      // Subscription deleted — mark canceled + revert tier to free
      // ------------------------------------------------------------------
      case "customer.subscription.deleted": {
        const sub = event.data.object as { id: string };

        // Fetch club_id before updating so we can revert the club tier
        const { data: row } = await supabase
          .from("club_subscriptions")
          .select("club_id")
          .eq("stripe_subscription_id", sub.id)
          .single();

        await supabase
          .from("club_subscriptions")
          .update({
            status: "canceled",
            updated_at: new Date().toISOString(),
          })
          .eq("stripe_subscription_id", sub.id);

        if (row?.club_id) {
          await supabase
            .from("clubs")
            .update({ subscription_tier: "free" })
            .eq("id", row.club_id);

          // Re-derive entitlements to revert features to free tier.
          const { error: entitlementError } = await supabase.rpc(
            "derive_club_entitlements",
            { p_club_id: row.club_id }
          );
          if (entitlementError) {
            console.error("[stripe-webhook] derive_club_entitlements error on delete:", entitlementError.message);
            throw entitlementError;
          }
        }
        break;
      }

      // ------------------------------------------------------------------
      // Payment failed — mark past_due (subscription.updated also fires,
      // but this ensures the status change is captured immediately)
      // ------------------------------------------------------------------
      case "invoice.payment_failed": {
        const invoice = event.data.object as { subscription?: string };
        const subID = invoice.subscription;
        if (subID) {
          await supabase
            .from("club_subscriptions")
            .update({
              status: "past_due",
              updated_at: new Date().toISOString(),
            })
            .eq("stripe_subscription_id", subID);
        }
        break;
      }

      // ------------------------------------------------------------------
      // Payment succeeded — handled by subscription.updated; no-op here
      // ------------------------------------------------------------------
      case "invoice.payment_succeeded":
        break;

      // ------------------------------------------------------------------
      // Connect Express account updated — flip onboarding/payout flags.
      // Stripe fires this after the owner submits their details and again
      // when Stripe's review completes and payouts are enabled.
      // ------------------------------------------------------------------
      case "account.updated": {
        const account = event.data.object as {
          id: string;
          details_submitted: boolean;
          payouts_enabled: boolean;
          charges_enabled: boolean;
        };

        const { error: accountUpdateError } = await supabase
          .from("club_stripe_accounts")
          .update({
            onboarding_complete: account.details_submitted,
            payouts_enabled: account.payouts_enabled,
          })
          .eq("stripe_account_id", account.id);

        if (accountUpdateError) {
          console.error("[stripe-webhook] account.updated DB error:", accountUpdateError.message);
          throw accountUpdateError;
        }

        console.log(
          "[stripe-webhook] account.updated processed:", account.id,
          "details_submitted:", account.details_submitted,
          "payouts_enabled:", account.payouts_enabled
        );
        break;
      }

      default:
        // Unhandled event type — acknowledge receipt, do nothing
        console.log("[stripe-webhook] Unhandled event:", event.type);
        break;
    }
  } catch (err) {
    console.error("[stripe-webhook] Handler error for event", event.type, err);
    // Return 500 so Stripe retries delivery
    return new Response("Internal error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
