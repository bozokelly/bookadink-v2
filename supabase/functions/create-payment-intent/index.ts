// create-payment-intent — Supabase Edge Function
// Creates a Stripe PaymentIntent for a paid game booking via Stripe Connect destination charge.
//
// All club-scoped paid bookings REQUIRE a valid club_id with:
//   - club_entitlements.can_accept_payments = true (plan check)
//   - club_stripe_accounts row with payouts_enabled = true (Connect readiness)
// There is NO fallback plain-charge path. If either check fails, the request is rejected.
//
// Required secrets (set via `supabase secrets set`):
//   STRIPE_SECRET_KEY        — Stripe secret key (sk_test_... for test mode)
//   SUPABASE_SERVICE_ROLE_KEY — injected automatically by Supabase runtime
//
// Deploy: supabase functions deploy create-payment-intent

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isUUID, clampStr } from "../_shared/validate.ts";
import { isRateLimited } from "../_shared/rateLimit.ts";
import { getCallerID } from "../_shared/auth.ts";

const DEFAULT_PLATFORM_FEE_BPS = 1000; // 10%

const REQUIRED_CURRENCY = "aud";

// Maximum charge: A$10,000 (protects against runaway charges; no real game costs this)
const MAX_AMOUNT_CENTS = 1_000_000;

// Maximum metadata entries / value length
const MAX_METADATA_ENTRIES = 10;
const MAX_METADATA_VALUE_LEN = 200;

interface RequestBody {
  amount: number;
  currency?: string;
  club_id?: string;
  metadata?: Record<string, string>;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error_code: "method_not_allowed", error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify({ error_code: "invalid_body", error: "Invalid JSON body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const { amount, currency, club_id: rawClubID, metadata = {} } = body;
  // Normalise to lowercase — Swift UUID.uuidString is uppercase, PostgREST returns lowercase.
  const club_id = typeof rawClubID === "string" ? rawClubID.toLowerCase() : rawClubID;

  // club_id is mandatory — there is no plain-charge fallback path.
  if (!club_id || !isUUID(club_id)) {
    console.error("[create-payment-intent] Rejected: club_id missing or invalid");
    return new Response(
      JSON.stringify({ error_code: "club_id_required", error: "club_id is required and must be a valid UUID." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Enforce AUD — reject any non-AUD currency to prevent silent fallback to USD.
  const resolvedCurrency = (currency ?? REQUIRED_CURRENCY).toLowerCase();
  if (resolvedCurrency !== REQUIRED_CURRENCY) {
    console.error(`[create-payment-intent] Rejected non-AUD currency: ${resolvedCurrency} club=${club_id}`);
    return new Response(
      JSON.stringify({ error_code: "invalid_currency", error: "Only AUD payments are supported." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  if (!amount || typeof amount !== "number" || !Number.isInteger(amount) || amount < 50 || amount > MAX_AMOUNT_CENTS) {
    return new Response(
      JSON.stringify({ error_code: "invalid_amount", error: `Amount must be a whole number in cents between 50 and ${MAX_AMOUNT_CENTS}.` }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Validate and sanitize metadata
  const metadataEntries = Object.entries(metadata ?? {});
  if (metadataEntries.length > MAX_METADATA_ENTRIES) {
    return new Response(
      JSON.stringify({ error_code: "invalid_metadata", error: "Too many metadata fields" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
  const safeMetadata: Record<string, string> = {};
  for (const [k, v] of metadataEntries) {
    if (typeof k !== "string" || typeof v !== "string") continue;
    safeMetadata[k.slice(0, 40)] = clampStr(v, MAX_METADATA_VALUE_LEN);
  }

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) {
    console.error("[create-payment-intent] STRIPE_SECRET_KEY secret is not set");
    return new Response(
      JSON.stringify({ error_code: "service_misconfigured", error: "Payment service is not configured." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Require an authenticated user — payment intents must be tied to a real account.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );
  const callerID = await getCallerID(supabase, req);
  if (!callerID) {
    console.warn(`[create-payment-intent] Rejected: unauthenticated request for club=${club_id}`);
    return new Response(
      JSON.stringify({ error_code: "authentication_required", error: "Authentication required" }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Rate limit primarily on auth.uid() (10 per minute per user).
  // Secondary key on game_id guards against the same game being charged twice
  // from different sessions (e.g. double-tap on two devices).
  const userRLKey = `create-pi:user:${callerID}`;
  const gameRLKey = safeMetadata.game_id && isUUID(safeMetadata.game_id)
    ? `create-pi:game:${safeMetadata.game_id}`
    : null;

  const [userLimited, gameLimited] = await Promise.all([
    isRateLimited(supabase, userRLKey, 60, 10),
    gameRLKey ? isRateLimited(supabase, gameRLKey, 60, 5) : Promise.resolve(false),
  ]);
  if (userLimited || gameLimited) {
    console.warn(`[create-payment-intent] Rate limited: user=${callerID} club=${club_id} game=${safeMetadata.game_id ?? "none"}`);
    return new Response(
      JSON.stringify({ error_code: "rate_limited", error: "Too many requests. Please try again shortly." }),
      { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Gate 0.5 — Waitlist hold validation (server-authoritative, no client reliance).
  //
  // When a game_id is provided and the caller already holds a `pending_payment` booking
  // for that game, the hold MUST still be active before any Stripe call is made.
  // Without this gate a player with an expired hold could create a real PaymentIntent,
  // pay Stripe, and then be blocked at confirmPendingBooking — leaving them charged
  // with no booking and requiring a manual refund.
  //
  // Side-effect: if a valid hold is found we record its `booking_id` to use as the
  // Stripe idempotency key.  The original `pi-{game_id}-{amount}` key is shared across
  // all players for the same game at the same price.  Two successive promoted players
  // (A expires, B promoted) at the same amount would receive the same Stripe PI —
  // player A could still complete payment with it.  Using `pi-{booking_id}-{amount}`
  // scopes the key to exactly one player's booking.

  const gameIDForCheck = safeMetadata.game_id && isUUID(safeMetadata.game_id)
    ? safeMetadata.game_id
    : null;

  let waitlistBookingID: string | null = null;

  if (gameIDForCheck) {
    const { data: holdRow, error: holdErr } = await supabase
      .from("bookings")
      .select("id, hold_expires_at")
      .eq("user_id", callerID)
      .eq("game_id", gameIDForCheck)
      .eq("status", "pending_payment")
      .maybeSingle();

    if (holdErr) {
      // DB lookup failed — fail closed. Creating a PI without verifying the hold
      // generates Stripe state that may never be used (expired hold blocks confirm),
      // producing charge noise and reconciliation work. Return a retryable error.
      console.error(`[create-payment-intent] Hold check DB error: user=${callerID} game=${gameIDForCheck}:`, holdErr.message);
      return new Response(
        JSON.stringify({
          error_code: "hold_check_unavailable",
          error: "Unable to verify your booking hold. Please try again.",
        }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    } else if (holdRow) {
      // Caller has a pending_payment booking for this game — enforce the hold window.
      const holdExpires = holdRow.hold_expires_at ? new Date(holdRow.hold_expires_at) : null;
      if (!holdExpires || holdExpires <= new Date()) {
        console.warn(
          `[create-payment-intent] Blocked [hold_expired]: user=${callerID} game=${gameIDForCheck} booking=${holdRow.id} hold_expires_at=${holdRow.hold_expires_at ?? "null"}`
        );
        return new Response(
          JSON.stringify({
            error_code: "hold_expired",
            error: "Your spot hold has expired. The next player in the queue has been offered this spot.",
          }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      // Hold is valid — record booking_id for scoped idempotency key below.
      waitlistBookingID = holdRow.id;
      console.log(
        `[create-payment-intent] Hold valid: user=${callerID} game=${gameIDForCheck} booking=${waitlistBookingID} expires=${holdExpires.toISOString()}`
      );
    }
    // No pending_payment row → caller is making a fresh booking; no hold check needed.
  }

  // Entitlement, Stripe Connect readiness, and game ownership all verified in parallel.
  const [
    { data: entRow, error: entErr },
    { data: stripeRow, error: stripeErr },
    { data: gameRow, error: gameErr },
  ] = await Promise.all([
    supabase
      .from("club_entitlements")
      .select("can_accept_payments")
      .eq("club_id", club_id)
      .maybeSingle(),
    supabase
      .from("club_stripe_accounts")
      .select("stripe_account_id, payouts_enabled")
      .eq("club_id", club_id)
      .maybeSingle(),
    gameIDForCheck
      ? supabase
          .from("games")
          .select("club_id, fee_amount")
          .eq("id", gameIDForCheck)
          .maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ]);

  if (entErr) {
    console.error(`[create-payment-intent] Entitlement fetch error: user=${callerID} club=${club_id}:`, entErr.message);
  }
  if (stripeErr) {
    console.error(`[create-payment-intent] Stripe account fetch error: user=${callerID} club=${club_id}:`, stripeErr.message);
  }

  // Gate 0 (when game_id provided): game must belong to the club and must be a paid game.
  if (gameIDForCheck) {
    if (gameErr) {
      console.error(`[create-payment-intent] Game lookup error: user=${callerID} game=${gameIDForCheck}:`, gameErr.message);
    }
    if (!gameRow) {
      console.warn(`[create-payment-intent] Blocked [game_not_found]: user=${callerID} game=${gameIDForCheck}`);
      return new Response(
        JSON.stringify({ error_code: "game_not_found", error: "Game not found." }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (gameRow.club_id !== club_id) {
      console.warn(`[create-payment-intent] Blocked [club_mismatch]: user=${callerID} game=${gameIDForCheck} game_club=${gameRow.club_id} request_club=${club_id}`);
      return new Response(
        JSON.stringify({ error_code: "club_mismatch", error: "Game does not belong to this club." }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (!gameRow.fee_amount || gameRow.fee_amount <= 0) {
      console.warn(`[create-payment-intent] Blocked [game_is_free]: user=${callerID} game=${gameIDForCheck} fee_amount=${gameRow.fee_amount}`);
      return new Response(
        JSON.stringify({ error_code: "game_is_free", error: "This game is free and does not require payment." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  }

  // Gate 1: plan entitlement
  if (!entRow?.can_accept_payments) {
    console.warn(`[create-payment-intent] Blocked [payment_plan_required]: user=${callerID} club=${club_id} can_accept_payments=${entRow?.can_accept_payments}`);
    return new Response(
      JSON.stringify({ error_code: "payment_plan_required", error: "This club is not set up to take payments yet. The club owner needs to upgrade their plan." }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Gate 2: Stripe Connect account must exist
  if (!stripeRow?.stripe_account_id) {
    console.warn(`[create-payment-intent] Blocked [payment_not_configured]: user=${callerID} club=${club_id} — no Stripe Connect account`);
    return new Response(
      JSON.stringify({ error_code: "payment_not_configured", error: "This club hasn't set up Stripe Connect yet. The club owner needs to complete payment setup in Club Settings → Payments." }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Gate 3: Stripe Connect account must have payouts enabled (onboarding complete)
  if (!stripeRow.payouts_enabled) {
    console.warn(`[create-payment-intent] Blocked [payment_not_ready]: user=${callerID} club=${club_id} stripe_account=${stripeRow.stripe_account_id} payouts_enabled=false`);
    return new Response(
      JSON.stringify({ error_code: "payment_not_ready", error: "This club's Stripe Connect setup is incomplete. The club owner needs to finish payment setup in Club Settings → Payments." }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const connectedAccountID = stripeRow.stripe_account_id;
  console.log(`[create-payment-intent] Eligibility OK: user=${callerID} club=${club_id} stripe_account=${connectedAccountID} game=${safeMetadata.game_id ?? "none"} amount=${amount} currency=${resolvedCurrency}`);

  // Fee split — connectedAccountID is always set here (eligibility gates above ensure it).
  const platformFeeCents = Math.floor(amount * DEFAULT_PLATFORM_FEE_BPS / 10000);
  const clubPayoutCents = amount - platformFeeCents;

  // Build Stripe PaymentIntent params — always a destination charge via Connect.
  const stripeBody = new URLSearchParams({
    amount: String(amount),
    currency: resolvedCurrency,
    "automatic_payment_methods[enabled]": "true",
    application_fee_amount: String(platformFeeCents),
    "transfer_data[destination]": connectedAccountID,
  });

  for (const [key, value] of Object.entries(safeMetadata)) {
    stripeBody.append(`metadata[${key}]`, value);
  }

  // Idempotency key strategy:
  //
  // Waitlist-promotion path (pending_payment booking exists):
  //   Use `pi-{booking_id}-{amount}` — scoped to exactly one player's hold.
  //   Prevents two successive promoted players at the same price from sharing a PI,
  //   which would let an expired player complete payment with a still-valid secret.
  //
  // Fresh-booking path (no pending_payment booking):
  //   No idempotency key is sent. The per-user (10/min) and per-game (5/min) rate
  //   limiters above already prevent duplicate charges. Any game-scoped or user+game
  //   scoped key causes paymentIntentInTerminalState when the same user books the same
  //   game more than once (e.g. cancel + rebook), because Stripe returns the original
  //   succeeded PI via idempotency instead of creating a fresh one.
  const stripeHeaders: Record<string, string> = {
    Authorization: `Bearer ${stripeKey}`,
    "Content-Type": "application/x-www-form-urlencoded",
  };
  if (waitlistBookingID) {
    stripeHeaders["Idempotency-Key"] = `pi-${waitlistBookingID}-${amount}`;
  }

  console.log(`[create-payment-intent] Creating intent: user=${callerID} club=${club_id} game=${safeMetadata.game_id ?? "none"} amount=${amount} platform_fee=${platformFeeCents}`);

  let stripeResponse: Response;
  try {
    stripeResponse = await fetch("https://api.stripe.com/v1/payment_intents", {
      method: "POST",
      headers: stripeHeaders,
      body: stripeBody.toString(),
    });
  } catch (err) {
    console.error("[create-payment-intent] Stripe network error:", err);
    return new Response(
      JSON.stringify({ error_code: "stripe_unavailable", error: "Payment service is temporarily unavailable. Please try again." }),
      { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const stripeData = await stripeResponse.json();

  if (!stripeResponse.ok) {
    console.error(`[create-payment-intent] Stripe error: user=${callerID} club=${club_id} game=${safeMetadata.game_id ?? "none"} status=${stripeResponse.status}`, JSON.stringify(stripeData));
    return new Response(
      JSON.stringify({ error_code: "stripe_error", error: stripeData?.error?.message ?? "Payment could not be started. Please try again." }),
      { status: stripeResponse.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log(`[create-payment-intent] Success: user=${callerID} club=${club_id} game=${safeMetadata.game_id ?? "none"} amount=${amount} platform_fee=${platformFeeCents}`);

  return new Response(
    JSON.stringify({
      client_secret: stripeData.client_secret,
      platform_fee_cents: platformFeeCents,
      club_payout_cents: clubPayoutCents,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
