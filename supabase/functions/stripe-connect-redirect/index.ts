// stripe-connect-redirect — Supabase Edge Function
// Stripe Account Links API requires HTTPS return_url/refresh_url; custom URL schemes are rejected.
// This function acts as an HTTPS intermediary: Stripe redirects here, then we 302 the browser
// to the bookadink:// deep link so the iOS app can handle the return.
//
// GET /stripe-connect-redirect?status=complete&club_id={uuid}
//   → 302 bookadink://stripe-return/{uuid}
//
// GET /stripe-connect-redirect?status=refresh&club_id={uuid}
//   → 302 bookadink://stripe-refresh/{uuid}
//
// Deploy: supabase functions deploy stripe-connect-redirect --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { isUUID } from "../_shared/validate.ts";

serve((req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: { "Access-Control-Allow-Origin": "*" },
    });
  }

  const url = new URL(req.url);
  const status = url.searchParams.get("status") ?? "";
  const clubID = url.searchParams.get("club_id") ?? "";

  if (!clubID || !isUUID(clubID)) {
    return new Response("Missing or invalid club_id", { status: 400 });
  }

  const clubIDLower = clubID.toLowerCase();
  const deepLink = status === "complete"
    ? `bookadink://stripe-return/${clubIDLower}`
    : `bookadink://stripe-refresh/${clubIDLower}`;

  // ASWebAuthenticationSession follows the 302 redirect chain and intercepts
  // the bookadink:// URL before the browser ever navigates to it.
  return new Response(null, {
    status: 302,
    headers: {
      Location: deepLink,
      "Cache-Control": "no-store",
    },
  });
});
