import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getPublishableKey } from "../_shared/api-keys.ts";

const allowedOrigins = new Set(["https://app.linecrewpro.com"]);
const corsHeaders = (request: Request) => ({
  "Access-Control-Allow-Origin": allowedOrigins.has(request.headers.get("Origin") || "")
    ? request.headers.get("Origin")! : "https://app.linecrewpro.com",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});
const respond = (request: Request, body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders(request), "Content-Type": "application/json" } });
const hex = (bytes: Uint8Array) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
const base64Url = (bytes: Uint8Array) => {
  let binary = "";
  bytes.forEach((byte) => binary += String.fromCharCode(byte));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
};
const escapeHtml = (value: unknown) => String(value ?? "")
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;").replaceAll("'", "&#039;");

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(request) });
  if (request.method !== "POST") return respond(request, { error: "Method not allowed." }, 405);
  const origin = request.headers.get("Origin");
  if (origin && !allowedOrigins.has(origin)) return respond(request, { error: "Origin not allowed." }, 403);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) return respond(request, { error: "Authentication required." }, 401);
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey = getPublishableKey();
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!supabaseUrl || !publishableKey || !resendKey) {
      console.error("Utility invitation service configuration is incomplete.");
      return respond(request, { error: "Invitation service is unavailable." }, 503);
    }

    const body = await request.json().catch(() => ({}));
    const organizationId = String(body?.organizationId || "");
    const email = String(body?.email || "").trim().toLowerCase();
    const fullName = String(body?.fullName || "").trim().slice(0, 120);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(organizationId)
        || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return respond(request, { error: "Invalid invitation request." }, 400);
    }

    const client = createClient(supabaseUrl, publishableKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });
    const { data: identity, error: identityError } = await client.auth.getUser();
    if (identityError || !identity.user) return respond(request, { error: "Authentication required." }, 401);

    const { data: organization, error: organizationError } = await client
      .from("utility_organizations").select("name").eq("id", organizationId).maybeSingle();
    if (organizationError || !organization) return respond(request, { error: "This action is not available." }, 403);

    const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
    const rawToken = base64Url(tokenBytes);
    const tokenHash = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawToken))));
    const expiresAt = new Date(Date.now() + 72 * 60 * 60 * 1000).toISOString();
    const { error: rpcError } = await client.rpc("utility_upsert_invitation", {
      p_organization_id: organizationId,
      p_email: email,
      p_full_name: fullName || null,
      p_token_hash: tokenHash,
      p_expires_at: expiresAt,
    });
    if (rpcError) {
      console.error("Utility invitation RPC failed.", rpcError.code || "RPC_ERROR");
      return respond(request, { error: "This action is not available." }, 403);
    }

    const organizationName = String(organization.name || "your utility organization")
      .replace(/[\r\n]+/g, " ").slice(0, 160);
    const invitationUrl = `https://app.linecrewpro.com/?utilityInvite=${encodeURIComponent(rawToken)}&email=${encodeURIComponent(email)}`;
    const text = `You have been invited to view shared LineCrew Pro contract progress for ${organizationName}.\n\nAccept your private invitation: ${invitationUrl}\n\nThis one-time invitation expires in 72 hours. Do not forward it.`;
    const html = `<!doctype html><html><body style="font-family:Arial,sans-serif;color:#15231b"><h1>LineCrew Pro Utility Portal invitation</h1><p>You have been invited to view shared contract progress for <strong>${escapeHtml(organizationName)}</strong>.</p><p><a href="${invitationUrl}">Accept Utility Portal Invitation</a></p><p>This private, one-time invitation expires in 72 hours. Do not forward it.</p></body></html>`;
    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: "LineCrew Pro <invites@auth.linecrewpro.com>", to: [email],
        reply_to: "support@linecrewpro.com",
        subject: `You’re invited to ${organizationName} in LineCrew Pro`, text, html,
      }),
    });
    if (!emailResponse.ok) {
      console.error("Resend rejected a utility invitation.", emailResponse.status);
      return respond(request, { error: "Unable to send the invitation." }, 502);
    }
    return respond(request, { sent: true });
  } catch (error) {
    console.error("Utility invitation failed.", error instanceof Error ? error.message : "Unknown error");
    return respond(request, { error: "Unable to send the invitation." }, 500);
  }
});
