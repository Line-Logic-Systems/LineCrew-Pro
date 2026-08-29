import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getPublishableKey } from "../_shared/api-keys.ts";

const allowedOrigins = new Set([
  "https://app.linecrewpro.com",
]);

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://app.linecrewpro.com",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
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

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function bytesToHex(bytes: Uint8Array) {
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

function base64Url(bytes: Uint8Array) {
  let binary = "";
  bytes.forEach(byte => binary += String.fromCharCode(byte));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "Method not allowed." }, 405);
  }

  try {
    const origin = request.headers.get("Origin");
    if (origin && !allowedOrigins.has(origin)) {
      return jsonResponse(request, { error: "Origin not allowed." }, 403);
    }

    const authorization = request.headers.get("Authorization");
    if (!authorization) return jsonResponse(request, { error: "Authentication required." }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = getPublishableKey();
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!supabaseUrl || !anonKey || !resendApiKey) {
      console.error("Team invitation service is missing required server configuration.");
      return jsonResponse(request, { error: "Invitation service is unavailable." }, 503);
    }

    const client = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });

    const { data: userData, error: userError } = await client.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse(request, { error: "Authentication required." }, 401);
    }

    const { data: profile, error: profileError } = await client
      .from("profiles")
      .select("company_id, role, role_permissions, active")
      .eq("id", userData.user.id)
      .single();

    if (profileError || !profile || profile.active !== true) {
      return jsonResponse(request, { error: "Active company profile required." }, 403);
    }

    const role = String(profile.role || "").toLowerCase();
    const permissions = profile.role_permissions && typeof profile.role_permissions === "object"
      ? profile.role_permissions as Record<string, unknown>
      : {};
    const canManageTeam = ["owner", "admin"].includes(role) ||
      (role === "superintendent" && permissions.team_management !== false);
    if (!canManageTeam) {
      return jsonResponse(request, { error: "Your role cannot invite team members." }, 403);
    }

    const body = await request.json().catch(() => ({}));
    const recipient = String(body?.email || "").trim().toLowerCase();
    if (recipient.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
      return jsonResponse(request, { error: "Enter a valid email address." }, 400);
    }

    const { data: company, error: companyError } = await client
      .from("companies")
      .select("name")
      .eq("id", profile.company_id)
      .single();

    if (companyError || !company) {
      return jsonResponse(request, { error: "Company invitation information is unavailable." }, 400);
    }

    const companyName = String(company.name || "Your company").slice(0, 160);
    const safeCompanyName = escapeHtml(companyName);
    const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
    const rawToken = base64Url(tokenBytes);
    const tokenHash = bytesToHex(new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawToken)),
    ));
    const expiresAt = new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString();
    const { error: invitationError } = await client.rpc("create_team_invitation", {
      p_email: recipient,
      p_token_hash: tokenHash,
      p_expires_at: expiresAt,
    });
    if (invitationError) {
      console.error("Unable to create a team invitation.", invitationError.code || "RPC_ERROR");
      return jsonResponse(request, { error: "Unable to create the invitation." }, 400);
    }

    const appUrl = `https://app.linecrewpro.com/?invite=${encodeURIComponent(rawToken)}&email=${encodeURIComponent(recipient)}`;
    const subject = `You’re invited to join ${companyName} in LineCrew Pro`;
    const text = [
      `You have been invited to join ${companyName} in LineCrew Pro.`,
      "",
      `Open your private invitation: ${appUrl}`,
      "",
      "Create your account using the email address that received this invitation. LineCrew Pro will place you directly into the correct company.",
      "This one-time invitation expires in 72 hours.",
      "",
      "New members begin as Foreman. Your company Owner or Admin can update your role after you join.",
      "",
      "Do not forward this private invitation link.",
    ].join("\n");
    const html = `<!doctype html><html><body style="margin:0;background:#f4f7f5;font-family:Arial,sans-serif;color:#15231b"><div style="max-width:600px;margin:0 auto;padding:32px 20px"><div style="background:#ffffff;border:1px solid #dce6df;border-radius:12px;padding:32px"><h1 style="margin:0 0 16px;font-size:24px">You’re invited to LineCrew Pro</h1><p><strong>${safeCompanyName}</strong> invited you to join its team.</p><p><a href="${appUrl}" style="display:inline-block;background:#168a52;color:#fff;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:8px">Accept Team Invitation</a></p><p>Create your account using the email address that received this invitation. LineCrew Pro will place you directly into the correct company—no company code is needed.</p><p style="font-size:14px;color:#526158">This private, one-time invitation expires in 72 hours. New members begin as Foreman; your company Owner or Admin can update your role after you join.</p><p style="font-size:13px;color:#6a746e">Do not forward this private invitation link.</p></div></div></body></html>`;

    const resendResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "LineCrew Pro <invites@auth.linecrewpro.com>",
        to: [recipient],
        reply_to: "support@linecrewpro.com",
        subject,
        text,
        html,
      }),
    });

    if (!resendResponse.ok) {
      console.error("Resend rejected a team invitation request.", resendResponse.status);
      return jsonResponse(request, { error: "Unable to send the invitation." }, 502);
    }

    return jsonResponse(request, { sent: true });
  } catch (error) {
    console.error("Team invitation request failed.", error instanceof Error ? error.message : "Unknown error");
    return jsonResponse(request, { error: "Unable to send the invitation." }, 500);
  }
});
