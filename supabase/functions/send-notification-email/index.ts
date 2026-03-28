// send-notification-email — Supabase Edge Function
// Triggered automatically after INSERT on notifications table via DB trigger.
// Sends a transactional email via Resend for notification types that warrant email delivery.
//
// Required secrets:
//   RESEND_API_KEY — from resend.com
//   EMAIL_FROM — sender address, e.g. "Bookadink <no-reply@bookadink.com>"
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-injected
//
// Deploy: supabase functions deploy send-notification-email --no-verify-jwt

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Notification types that should trigger an email
const EMAIL_ENABLED_TYPES = new Set([
  "booking_confirmed",
  "waitlist_promoted",
  "membership_approved",
  "membership_rejected",
  "membership_removed",
  "club_announcement",
  "game_cancelled",
  "game_updated",
  "game_review_request",
]);

// Types that relate to a game (reference_id = game UUID)
const GAME_TYPES = new Set([
  "booking_confirmed",
  "waitlist_promoted",
  "game_cancelled",
  "game_updated",
  "game_review_request",
]);

// Types that relate to a club (reference_id = club UUID)
const CLUB_TYPES = new Set([
  "membership_approved",
  "membership_rejected",
  "membership_removed",
  "club_announcement",
]);

interface TriggerPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: {
    id: string;
    user_id: string;
    title: string;
    body: string;
    type: string;
    reference_id: string | null;
    read: boolean;
    created_at: string;
    email_sent: boolean;
  };
  old_record: null | Record<string, unknown>;
}

interface GameRow {
  title: string;
  date_time: string;
  duration_minutes: number;
  venue_name: string | null;
  location: string | null;
  latitude: number | null;
  longitude: number | null;
  club_id: string;
}

interface ClubRow {
  name: string;
  venue_name: string | null;
  street_address: string | null;
  suburb: string | null;
  state: string | null;
  postcode: string | null;
}

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let payload: TriggerPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const notification = payload.record;
  if (!notification) {
    return new Response(JSON.stringify({ skipped: true, reason: "no_record" }), { status: 200 });
  }

  // Skip if email already sent or type doesn't warrant email
  if (notification.email_sent || !EMAIL_ENABLED_TYPES.has(notification.type)) {
    return new Response(JSON.stringify({ skipped: true, reason: "not_email_type" }), { status: 200 });
  }

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const emailFrom = Deno.env.get("EMAIL_FROM") ?? "Bookadink <no-reply@bookadink.com>";

  if (!resendKey) {
    console.warn("RESEND_API_KEY not set — email skipped");
    return new Response(JSON.stringify({ skipped: true, reason: "no_resend_key" }), { status: 200 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Fetch user profile
  const { data: profile } = await supabase
    .from("profiles")
    .select("email,full_name")
    .eq("id", notification.user_id)
    .single();

  if (!profile?.email) {
    return new Response(JSON.stringify({ skipped: true, reason: "no_email" }), { status: 200 });
  }

  const firstName = profile.full_name?.split(" ")[0] ?? "Player";
  const refID = notification.reference_id;
  const notifType = notification.type;

  // ------------------------------------------------------------------
  // Fetch enrichment data and build type-specific HTML
  // ------------------------------------------------------------------
  let htmlBody: string;

  if (GAME_TYPES.has(notifType) && refID) {
    const { data: game } = await supabase
      .from("games")
      .select("title,date_time,duration_minutes,venue_name,location,latitude,longitude,club_id")
      .eq("id", refID)
      .single<GameRow>();

    let club: ClubRow | null = null;
    if (game?.club_id) {
      const { data: clubData } = await supabase
        .from("clubs")
        .select("name,venue_name,street_address,suburb,state,postcode")
        .eq("id", game.club_id)
        .single<ClubRow>();
      club = clubData;
    }

    htmlBody = buildGameEmail({
      firstName,
      title: notification.title,
      notifType,
      game: game ?? null,
      club,
    });
  } else if (CLUB_TYPES.has(notifType) && refID) {
    const { data: club } = await supabase
      .from("clubs")
      .select("name,venue_name,street_address,suburb,state,postcode")
      .eq("id", refID)
      .single<ClubRow>();

    htmlBody = buildClubEmail({
      firstName,
      title: notification.title,
      body: notification.body,
      club: club ?? null,
    });
  } else {
    htmlBody = buildGenericEmail({
      firstName,
      title: notification.title,
      body: notification.body,
    });
  }

  // Send via Resend
  const emailResp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: emailFrom,
      to: [profile.email],
      subject: notification.title,
      html: htmlBody,
    }),
  });

  if (!emailResp.ok) {
    const errText = await emailResp.text();
    console.error("Resend error:", errText);
    return new Response(JSON.stringify({ sent: false, error: errText }), { status: 200 });
  }

  // Mark email_sent = true
  await supabase
    .from("notifications")
    .update({ email_sent: true })
    .eq("id", notification.id);

  return new Response(JSON.stringify({ sent: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatDate(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleDateString("en-AU", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleTimeString("en-AU", { hour: "numeric", minute: "2-digit", hour12: true });
}

function formatDuration(minutes: number): string {
  if (minutes < 60) return `${minutes}m`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

function buildMapsURL(game: GameRow | null, club: ClubRow | null): string {
  // Prefer game-level coordinates, then club address
  if (game?.latitude != null && game?.longitude != null) {
    return `https://www.google.com/maps/search/?api=1&query=${game.latitude},${game.longitude}`;
  }
  const parts = [
    game?.venue_name ?? club?.venue_name,
    club?.street_address,
    club?.suburb,
    club?.state,
    club?.postcode,
  ].filter(Boolean);
  if (parts.length === 0) return "https://www.google.com/maps";
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(parts.join(", "))}`;
}

function buildClubMapsURL(club: ClubRow | null): string {
  if (!club) return "https://www.google.com/maps";
  const parts = [club.venue_name, club.street_address, club.suburb, club.state, club.postcode].filter(Boolean);
  if (parts.length === 0) return "https://www.google.com/maps";
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(parts.join(", "))}`;
}

function gameTagline(notifType: string): string {
  switch (notifType) {
    case "booking_confirmed":    return "You're booked in";
    case "waitlist_promoted":    return "You're off the waitlist";
    case "game_cancelled":       return "Game cancelled";
    case "game_updated":         return "Game updated";
    case "game_review_request":  return "How was your session?";
    default:                     return "Game update";
  }
}

function gameSupportingText(notifType: string): string {
  switch (notifType) {
    case "booking_confirmed":    return "Open the Bookadink app to manage your booking or add it to your calendar.";
    case "waitlist_promoted":    return "A spot opened up and you've been confirmed. Open the app to view your booking.";
    case "game_cancelled":       return "We're sorry for the inconvenience. Open the app to find another session.";
    case "game_updated":         return "Details for this game have changed. Open the app to see what's new.";
    case "game_review_request":  return "Open the Bookadink app to leave a quick star rating. Your feedback helps organisers improve future sessions.";
    default:                     return "Open the Bookadink app for more details.";
  }
}

// ---------------------------------------------------------------------------
// Email builders
// ---------------------------------------------------------------------------

function buildGameEmail(opts: {
  firstName: string;
  title: string;
  notifType: string;
  game: GameRow | null;
  club: ClubRow | null;
}): string {
  const { firstName, title, notifType, game, club } = opts;
  const tagline = gameTagline(notifType);
  const supportText = gameSupportingText(notifType);

  const gameName = game?.title ?? title;
  const clubName = club?.name ?? "";
  const dateStr  = game ? formatDate(game.date_time)    : "";
  const timeStr  = game ? formatTime(game.date_time)    : "";
  const durStr   = game ? formatDuration(game.duration_minutes) : "";
  const venueName   = game?.venue_name ?? club?.venue_name ?? "";
  const venueAddr   = [club?.street_address, club?.suburb, club?.state, club?.postcode].filter(Boolean).join(", ");
  const mapsURL     = buildMapsURL(game, club);

  const venueBlock = venueName
    ? `<p style="margin:0 0 2px;font-size:14px;font-weight:600;color:#111111;">${esc(venueName)}</p>
       ${venueAddr ? `<p style="margin:0 0 6px;font-size:13px;color:#6b7280;">${esc(venueAddr)}</p>` : ""}
       <a href="${mapsURL}" style="font-size:13px;color:#16a34a;text-decoration:none;font-weight:500;">View on Google Maps →</a>`
    : `<a href="${mapsURL}" style="font-size:13px;color:#16a34a;text-decoration:none;font-weight:500;">View on Google Maps →</a>`;

  return shell(`
    ${logoRow()}
    ${titleRow(tagline)}
    ${greetingRow(firstName)}

    <!-- Game card -->
    <tr>
      <td style="background:#f9fafb;border-radius:12px;padding:24px;margin-bottom:0;">
        <table width="100%" cellpadding="0" cellspacing="0">

          <!-- Game name -->
          <tr>
            <td style="padding-bottom:2px;">
              <p style="margin:0;font-size:17px;font-weight:700;color:#111111;line-height:1.3;">${esc(gameName)}</p>
            </td>
          </tr>

          <!-- Club name -->
          ${clubName ? `<tr>
            <td style="padding-bottom:18px;">
              <p style="margin:0;font-size:13px;font-weight:500;color:#16a34a;">${esc(clubName)}</p>
            </td>
          </tr>` : `<tr><td style="padding-bottom:18px;"></td></tr>`}

          <!-- Divider -->
          <tr><td style="padding-bottom:14px;"><hr style="border:none;border-top:1px solid #e5e7eb;margin:0;"></td></tr>

          <!-- Date -->
          ${dateStr ? infoRow("📅", esc(dateStr)) : ""}

          <!-- Time · Duration -->
          ${timeStr ? infoRow("🕐", `${esc(timeStr)}${durStr ? " &nbsp;·&nbsp; " + esc(durStr) : ""}`) : ""}

          <!-- Location -->
          ${venueName || venueAddr ? `
          <tr>
            <td style="padding-bottom:0;">
              <table cellpadding="0" cellspacing="0">
                <tr>
                  <td style="vertical-align:top;padding-top:1px;padding-right:10px;">
                    <p style="margin:0;font-size:15px;line-height:1;">📍</p>
                  </td>
                  <td>${venueBlock}</td>
                </tr>
              </table>
            </td>
          </tr>` : ""}

        </table>
      </td>
    </tr>

    ${supportRow(supportText)}
    ${footerRow()}
  `);
}

function buildClubEmail(opts: {
  firstName: string;
  title: string;
  body: string;
  club: ClubRow | null;
}): string {
  const { firstName, title, body, club } = opts;
  const clubName = club?.name ?? "";
  const venueAddr = [club?.venue_name, club?.street_address, club?.suburb, club?.state, club?.postcode].filter(Boolean).join(", ");
  const mapsURL = buildClubMapsURL(club);

  return shell(`
    ${logoRow()}
    ${titleRow(title)}
    ${greetingRow(firstName)}

    <!-- Club card -->
    <tr>
      <td style="background:#f9fafb;border-radius:12px;padding:24px;">
        <table width="100%" cellpadding="0" cellspacing="0">

          ${clubName ? `<tr>
            <td style="padding-bottom:${venueAddr ? "18px" : "0"};">
              <p style="margin:0;font-size:17px;font-weight:700;color:#111111;">${esc(clubName)}</p>
            </td>
          </tr>` : ""}

          ${venueAddr ? `
          <tr><td style="padding-bottom:14px;"><hr style="border:none;border-top:1px solid #e5e7eb;margin:0;"></td></tr>
          <tr>
            <td>
              <table cellpadding="0" cellspacing="0">
                <tr>
                  <td style="vertical-align:top;padding-top:1px;padding-right:10px;">
                    <p style="margin:0;font-size:15px;line-height:1;">📍</p>
                  </td>
                  <td>
                    <p style="margin:0 0 6px;font-size:14px;color:#374151;">${esc(venueAddr)}</p>
                    <a href="${mapsURL}" style="font-size:13px;color:#16a34a;text-decoration:none;font-weight:500;">View on Google Maps →</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>` : ""}

        </table>
      </td>
    </tr>

    <!-- Body text -->
    <tr>
      <td style="padding:20px 0 8px;">
        <p style="margin:0;font-size:14px;line-height:1.6;color:#374151;">${esc(body)}</p>
      </td>
    </tr>

    ${supportRow("Open the Bookadink app for more details.")}
    ${footerRow()}
  `);
}

function buildGenericEmail(opts: {
  firstName: string;
  title: string;
  body: string;
}): string {
  const { firstName, title, body } = opts;
  return shell(`
    ${logoRow()}
    ${titleRow(title)}
    ${greetingRow(firstName)}
    <tr>
      <td style="padding-bottom:28px;">
        <p style="margin:0;font-size:15px;line-height:1.6;color:#374151;">${esc(body)}</p>
      </td>
    </tr>
    ${footerRow()}
  `);
}

// ---------------------------------------------------------------------------
// Shared layout primitives
// ---------------------------------------------------------------------------

function shell(inner: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Bookadink</title>
</head>
<body style="margin:0;padding:0;background:#ffffff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="padding:40px 16px;">
    <tr>
      <td align="center">
        <table width="100%" cellpadding="0" cellspacing="0" style="max-width:540px;">
          ${inner}
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function logoRow(): string {
  return `<tr>
    <td style="padding-bottom:32px;">
      <p style="margin:0;font-size:17px;font-weight:700;color:#16a34a;letter-spacing:-0.2px;">Bookadink</p>
    </td>
  </tr>`;
}

function titleRow(text: string): string {
  return `<tr>
    <td style="padding-bottom:10px;">
      <h1 style="margin:0;font-size:26px;font-weight:700;color:#111111;letter-spacing:-0.4px;line-height:1.2;">${esc(text)}</h1>
    </td>
  </tr>`;
}

function greetingRow(firstName: string): string {
  return `<tr>
    <td style="padding-bottom:24px;">
      <p style="margin:0;font-size:14px;color:#6b7280;">Hey ${esc(firstName)}, here are the details.</p>
    </td>
  </tr>`;
}

function infoRow(emoji: string, content: string): string {
  return `<tr>
    <td style="padding-bottom:10px;">
      <table cellpadding="0" cellspacing="0">
        <tr>
          <td style="vertical-align:top;padding-top:1px;padding-right:10px;width:22px;">
            <p style="margin:0;font-size:15px;line-height:1;">${emoji}</p>
          </td>
          <td>
            <p style="margin:0;font-size:14px;color:#374151;">${content}</p>
          </td>
        </tr>
      </table>
    </td>
  </tr>`;
}

function supportRow(text: string): string {
  return `<tr>
    <td style="padding:22px 0 28px;">
      <p style="margin:0;font-size:13px;color:#6b7280;line-height:1.6;">${esc(text)}</p>
    </td>
  </tr>`;
}

function footerRow(): string {
  return `<tr>
    <td style="border-top:1px solid #e5e7eb;padding-top:20px;">
      <p style="margin:0;font-size:11px;color:#9ca3af;line-height:1.5;">
        You're receiving this because you have notifications enabled in Bookadink.<br>
        &copy; ${new Date().getFullYear()} Bookadink
      </p>
    </td>
  </tr>`;
}

function esc(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
