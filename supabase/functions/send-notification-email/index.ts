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

  // Fetch user email
  const { data: profile } = await supabase
    .from("profiles")
    .select("email,full_name")
    .eq("id", notification.user_id)
    .single();

  if (!profile?.email) {
    return new Response(JSON.stringify({ skipped: true, reason: "no_email" }), { status: 200 });
  }

  const firstName = profile.full_name?.split(" ")[0] ?? "Player";
  const htmlBody = buildEmailHTML(firstName, notification.title, notification.body);

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

function buildEmailHTML(firstName: string, title: string, body: string): string {
  return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body style="margin:0;padding:0;background:#f4f7f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f7f9;padding:32px 16px;">
    <tr>
      <td align="center">
        <table width="520" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08);">
          <tr>
            <td style="background:linear-gradient(135deg,#1B3A4B,#2D6A4F);padding:28px 32px;">
              <p style="margin:0;font-size:22px;font-weight:700;color:#ffffff;letter-spacing:-0.3px;">Bookadink</p>
            </td>
          </tr>
          <tr>
            <td style="padding:32px;">
              <p style="margin:0 0 12px;font-size:15px;color:#6b7280;">Hey ${firstName},</p>
              <h2 style="margin:0 0 16px;font-size:20px;font-weight:700;color:#111827;">${title}</h2>
              <p style="margin:0 0 24px;font-size:15px;line-height:1.6;color:#374151;">${body}</p>
              <p style="margin:0;font-size:13px;color:#9ca3af;">— The Bookadink Team</p>
            </td>
          </tr>
          <tr>
            <td style="background:#f9fafb;padding:16px 32px;border-top:1px solid #e5e7eb;">
              <p style="margin:0;font-size:12px;color:#9ca3af;text-align:center;">
                You're receiving this because you have notifications enabled in Bookadink.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}
