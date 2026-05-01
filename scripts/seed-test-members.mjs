#!/usr/bin/env node
// Seed test members into a club. Each member gets:
//   - a stub auth.users row (random password they can't recover — they will not log in)
//   - a profiles row (full_name + dupr_rating, NUMERIC(5,3) → rounded to 3dp)
//   - a club_members row (status='approved')
// Idempotent: re-running with the same email is a no-op.
//
// Usage:
//   SUPABASE_URL=https://<ref>.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=<service_role_key> \
//   node BookadinkV2/scripts/seed-test-members.mjs
//
// Required: Node 18+ (built-in fetch). No npm install needed.

import { randomBytes } from "node:crypto";

const CLUB_ID = "f82430f3-1048-4cca-ad91-6f189a84ae55";

const PLAYERS = [
  { fullName: "Roszie Nelson",  duprRating: 2.022 },
  { fullName: "Richard Smith",  duprRating: 2.662 },
  { fullName: "David Strahle",  duprRating: 2.670 },
  { fullName: "Thanh Strahle",  duprRating: 2.513 },
  { fullName: "Mark Ollett",    duprRating: 2.507 },
  { fullName: "Julie Lowe",     duprRating: 3.3332 }, // → rounds to 3.333
];

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env var.");
  process.exit(1);
}

const authHeaders = {
  apikey: SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
};

// NUMERIC(5,3) — round half-away-from-zero to 3 decimal places
function round3(x) {
  return Math.round(x * 1000) / 1000;
}

// Synthetic email for the stub auth user. Domain chosen so it's obviously
// non-deliverable. Slug from full name keeps re-runs idempotent (lookup by email).
function syntheticEmail(fullName) {
  const slug = fullName
    .toLowerCase()
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
  return `bookadink+test-${slug}@example.invalid`;
}

async function findUserIdByEmail(email) {
  // Auth Admin list-users supports an email filter.
  const url = new URL("/auth/v1/admin/users", SUPABASE_URL);
  url.searchParams.set("email", email);
  const res = await fetch(url, { headers: authHeaders });
  if (!res.ok) throw new Error(`list users: ${res.status} ${await res.text()}`);
  const body = await res.json();
  const users = body.users ?? [];
  const match = users.find(u => (u.email ?? "").toLowerCase() === email.toLowerCase());
  return match?.id ?? null;
}

async function createAuthUser(email, fullName) {
  const password = randomBytes(24).toString("base64url"); // never returned to caller
  const res = await fetch(new URL("/auth/v1/admin/users", SUPABASE_URL), {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName, seed_source: "test-member-script" },
    }),
  });
  if (!res.ok) throw new Error(`create user ${email}: ${res.status} ${await res.text()}`);
  const body = await res.json();
  return body.id;
}

async function upsertProfile(userId, fullName, duprRating) {
  const url = new URL("/rest/v1/profiles", SUPABASE_URL);
  // on_conflict=id ensures a re-run patches name/rating instead of erroring
  url.searchParams.set("on_conflict", "id");
  const res = await fetch(url, {
    method: "POST",
    headers: { ...authHeaders, Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify([{ id: userId, full_name: fullName, dupr_rating: duprRating }]),
  });
  if (!res.ok) throw new Error(`upsert profile ${userId}: ${res.status} ${await res.text()}`);
}

async function ensureClubMembership(clubId, userId) {
  // Check first; club_members has UNIQUE(club_id, user_id) in most installs but
  // we don't depend on that — explicit check avoids a 409 noise.
  const checkUrl = new URL("/rest/v1/club_members", SUPABASE_URL);
  checkUrl.searchParams.set("select", "id,status");
  checkUrl.searchParams.set("club_id", `eq.${clubId}`);
  checkUrl.searchParams.set("user_id", `eq.${userId}`);
  const checkRes = await fetch(checkUrl, { headers: authHeaders });
  if (!checkRes.ok) throw new Error(`check membership: ${checkRes.status} ${await checkRes.text()}`);
  const existing = await checkRes.json();
  if (existing.length > 0) {
    // If they exist but aren't approved (e.g. pending), promote to approved.
    if (existing[0].status !== "approved") {
      const patchUrl = new URL("/rest/v1/club_members", SUPABASE_URL);
      patchUrl.searchParams.set("id", `eq.${existing[0].id}`);
      const patchRes = await fetch(patchUrl, {
        method: "PATCH",
        headers: { ...authHeaders, Prefer: "return=minimal" },
        body: JSON.stringify({ status: "approved" }),
      });
      if (!patchRes.ok) throw new Error(`approve membership: ${patchRes.status} ${await patchRes.text()}`);
      return "promoted";
    }
    return "already-member";
  }
  const now = new Date().toISOString();
  const insertRes = await fetch(new URL("/rest/v1/club_members", SUPABASE_URL), {
    method: "POST",
    headers: { ...authHeaders, Prefer: "return=minimal" },
    body: JSON.stringify([{
      club_id: clubId,
      user_id: userId,
      status: "approved",
      requested_at: now,
      conduct_accepted_at: now,
      cancellation_policy_accepted_at: now,
    }]),
  });
  if (!insertRes.ok) throw new Error(`insert membership: ${insertRes.status} ${await insertRes.text()}`);
  return "added";
}

async function main() {
  console.log(`Seeding ${PLAYERS.length} test members into club ${CLUB_ID}\n`);
  const results = [];
  for (const player of PLAYERS) {
    const email = syntheticEmail(player.fullName);
    const dupr = round3(player.duprRating);
    try {
      let userId = await findUserIdByEmail(email);
      let userStatus;
      if (userId) {
        userStatus = "exists";
      } else {
        userId = await createAuthUser(email, player.fullName);
        userStatus = "created";
      }
      await upsertProfile(userId, player.fullName, dupr);
      const memberStatus = await ensureClubMembership(CLUB_ID, userId);
      results.push({ name: player.fullName, dupr, userStatus, memberStatus, userId });
      console.log(`  ✓ ${player.fullName.padEnd(20)} dupr=${dupr.toFixed(3)}  user=${userStatus}  membership=${memberStatus}`);
    } catch (err) {
      results.push({ name: player.fullName, error: err.message });
      console.error(`  ✗ ${player.fullName}: ${err.message}`);
    }
  }
  const failures = results.filter(r => r.error);
  console.log(`\nDone. ${results.length - failures.length}/${results.length} succeeded.`);
  if (failures.length > 0) process.exit(2);
}

main().catch(err => {
  console.error("Fatal:", err);
  process.exit(1);
});
