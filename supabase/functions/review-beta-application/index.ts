import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";

const ALLOWED_ORIGINS = new Set([
  "https://app.linecrewpro.com",
  "http://localhost:3000",
  "http://127.0.0.1:3000",
]);

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "https://app.linecrewpro.com",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function jsonResponse(request: Request, body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), "Content-Type": "application/json" },
  });
}

function base64Url(bytes: Uint8Array) {
  let binary = "";
  bytes.forEach(byte => binary += String.fromCharCode(byte));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function bytesToHex(bytes: Uint8Array) {
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(digest));
}

Deno.serve(async request => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "Method not allowed." }, 405);
  }

  const origin = request.headers.get("Origin");
  if (origin && !ALLOWED_ORIGINS.has(origin)) {
    return jsonResponse(request, { error: "Origin not allowed." }, 403);
  }

  const authHeader = request.headers.get("Authorization") || "";
  const bearer = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!bearer) {
    return jsonResponse(request, { error: "Authentication required." }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secretKey = getSecretKey();
  const publishableKey = getPublishableKey();
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!supabaseUrl || !secretKey || !publishableKey || !resendApiKey) {
    console.error("Beta review service is missing server configuration.");
    return jsonResponse(request, { error: "Review service is unavailable." }, 503);
  }

  const admin = createClient(supabaseUrl, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await admin.auth.getUser(bearer[1]);
  if (userError || !userData.user) {
    return jsonResponse(request, { error: "Authentication required." }, 401);
  }

  const { data: ownerRow, error: ownerError } = await admin
    .from("platform_owners")
    .select("user_id")
    .eq("user_id", userData.user.id)
    .maybeSingle();
  if (ownerError || !ownerRow) {
    return jsonResponse(request, { error: "Platform owner access required." }, 403);
  }

  const body = await request.json().catch(() => ({}));
  const applicationId = String(body?.application_id || "").trim();
  const action = String(body?.action || "").trim().toLowerCase();
  if (!/^[0-9a-f-]{36}$/i.test(applicationId) || !["approve", "decline"].includes(action)) {
    return jsonResponse(request, { error: "Invalid review request." }, 400);
  }

  const ownerClient = createClient(supabaseUrl, publishableKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authHeader } },
  });

  if (action === "decline") {
    const { error } = await ownerClient.rpc("platform_owner_decline_beta_application", {
      p_application_id: applicationId,
    });
    if (error) {
      console.error("Beta decline failed.", error.code || "DECLINE_FAILED");
      return jsonResponse(request, { error: "Unable to decline this application." }, 400);
    }
    return jsonResponse(request, { declined: true });
  }

  const rawToken = base64Url(crypto.getRandomValues(new Uint8Array(32)));
  const tokenHash = await sha256Hex(rawToken);
  const inviteExpiresAt = new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString();
  const pilotEndsAt = new Date(Date.now() + 60 * 24 * 60 * 60 * 1000).toISOString();
  const { data: prepared, error: prepareError } = await ownerClient.rpc(
    "platform_owner_prepare_beta_company",
    {
      p_application_id: applicationId,
      p_token_hash: tokenHash,
      p_invite_expires_at: inviteExpiresAt,
      p_pilot_ends_at: pilotEndsAt,
    },
  );
  const row = Array.isArray(prepared) ? prepared[0] : prepared;
  if (prepareError || !row?.company_id || !row?.applicant_email) {
    console.error("Beta company preparation failed.", prepareError?.code || "PREPARE_FAILED");
    return jsonResponse(request, { error: "Unable to approve this application." }, 400);
  }

  const applicantEmail = String(row.applicant_email).trim().toLowerCase();
  const applicantName = String(row.applicant_name || "").trim();
  const appUrl = `https://app.linecrewpro.com/beta-accept.html?invite=${encodeURIComponent(rawToken)}&email=${encodeURIComponent(applicantEmail)}`;
  const subject = "Your LineCrew Pro Beta access is approved";
  const text = [
    "Your LineCrew Pro Beta/Pilot application has been approved.",
    "",
    `Set up your Admin account: ${appUrl}`,
    "",
    "Create your password on that page. After it succeeds, your account is ready immediately—there is no second email to wait for.",
    "Your private setup link expires in 48 hours.",
    "",
    "Do not forward this private setup link.",
  ].join("\n");
  const html = `<!doctype html><html><body style="margin:0;background:#f4f7f5;font-family:Arial,sans-serif;color:#15231b"><div style="max-width:620px;margin:0 auto;padding:32px 20px"><div style="background:#fff;border:1px solid #dce6df;border-radius:12px;padding:30px"><h1 style="margin:0 0 16px;font-size:24px">Your Beta access is approved</h1><p>${applicantName ? `Hi ${escapeHtml(applicantName)},` : "Welcome,"}</p><p>Your LineCrew Pro Beta/Pilot company is ready for its first Admin account.</p><p><a href="${appUrl}" style="display:inline-block;background:#168a52;color:#fff;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:8px">Set Up My Admin Account</a></p><p>Create your password on that page. <strong>Once setup succeeds, your account is ready immediately—there is no second email to wait for.</strong></p><p style="font-size:14px;color:#526158">This private one-time link expires in 48 hours. Do not forward it.</p></div></div></body></html>`;

  const resendResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `beta-admin-invite-${applicationId}`,
    },
    body: JSON.stringify({
      from: "LineCrew Pro <invites@auth.linecrewpro.com>",
      to: [applicantEmail],
      reply_to: "support@linecrewpro.com",
      subject,
      text,
      html,
    }),
  });

  if (!resendResponse.ok) {
    console.error("Resend rejected the Beta admin invitation.", resendResponse.status);
    return jsonResponse(
      request,
      {
        approved: true,
        invite_sent: false,
        company_id: row.company_id,
        warning: "The company was approved, but the account invitation email could not be sent.",
      },
      202,
    );
  }

  const { error: markError } = await ownerClient.rpc("platform_owner_mark_beta_invite_sent", {
    p_application_id: applicationId,
  });
  if (markError) {
    console.error("Beta invitation sent marker failed.", markError.code || "MARK_FAILED");
  }

  return jsonResponse(request, {
    approved: true,
    invite_sent: true,
    company_id: row.company_id,
    pilot_ends_at: pilotEndsAt,
  });
});
