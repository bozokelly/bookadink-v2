// create-payment-intent — Supabase Edge Function
// Creates a Stripe PaymentIntent and returns the client_secret to the iOS app.
// The iOS app passes this to Stripe PaymentSheet to complete the payment.
//
// Required secrets (set via `supabase secrets set`):
//   STRIPE_SECRET_KEY  — Stripe secret key (sk_test_... for test mode)
//
// Deploy: supabase functions deploy create-payment-intent
//
// Test:
//   curl -X POST https://<project-ref>.supabase.co/functions/v1/create-payment-intent \
//     -H "Content-Type: application/json" \
//     -H "Authorization: Bearer <anon-key>" \
//     -d '{"amount": 1500, "currency": "aud"}'

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

interface RequestBody {
  amount: number;
  currency?: string;
  metadata?: Record<string, string>;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Parse body
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const { amount, currency = "aud", metadata = {} } = body;

  // Validate amount
  if (!amount || typeof amount !== "number" || !Number.isInteger(amount) || amount < 50) {
    return new Response(
      JSON.stringify({ error: "amount must be an integer in cents (minimum 50)" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) {
    console.error("STRIPE_SECRET_KEY secret is not set");
    return new Response(
      JSON.stringify({ error: "Payment service not configured" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Create PaymentIntent via Stripe REST API (no SDK needed in Deno)
  const stripeBody = new URLSearchParams({
    amount: String(amount),
    currency: currency.toLowerCase(),
    "automatic_payment_methods[enabled]": "true",
  });

  // Attach any metadata key/value pairs
  for (const [key, value] of Object.entries(metadata)) {
    stripeBody.append(`metadata[${key}]`, value);
  }

  let stripeResponse: Response;
  try {
    stripeResponse = await fetch("https://api.stripe.com/v1/payment_intents", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: stripeBody.toString(),
    });
  } catch (err) {
    console.error("Stripe network error:", err);
    return new Response(
      JSON.stringify({ error: "Failed to reach Stripe" }),
      { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const stripeData = await stripeResponse.json();

  if (!stripeResponse.ok) {
    console.error("Stripe error:", JSON.stringify(stripeData));
    return new Response(
      JSON.stringify({ error: stripeData?.error?.message ?? "Stripe error" }),
      { status: stripeResponse.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Return only the client_secret — never expose the full PaymentIntent to the client
  return new Response(
    JSON.stringify({ client_secret: stripeData.client_secret }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
