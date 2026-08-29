import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getSecretKey } from "../_shared/api-keys.ts";

const allowedOrigins = new Set(["https://app.linecrewpro.com"]);

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

function bytesToHex(bytes: Uint8Array) {
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "Method not allowed." }, 405);
  }

  const origin = request.headers.get("Origin");
  if (origin && !allowedOrigins.has(origin)) {
    return jsonResponse(request, { error: "Origin not allowed." }, 403);
  }

  if (!request.headers.get("Authorization")) {
    return jsonResponse(request, { error: "Authorization is required." }, 401);
  }

  try {
    const body = await request.json().catch(() => ({}));
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.password || "");
    const rawToken = String(body?.token || "");

    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return jsonResponse(request, { error: "Invalid invitation signup." }, 400);
    }
    if (password.length < 8 || password.length > 128) {
      return jsonResponse(request, { error: "Invalid invitation signup." }, 400);
    }
    if (!/^[A-Za-z0-9_-]{43}$/.test(rawToken)) {
      return jsonResponse(request, { error: "Invalid invitation signup." }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = getSecretKey();
    if (!supabaseUrl || !serviceRoleKey) {
      console.error("Invitation signup service is missing required server configuration.");
      return jsonResponse(request, { error: "Invitation signup is unavailable." }, 503);
    }

    const tokenHash = bytesToHex(new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawToken)),
    ));

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: invitation, error: invitationError } = await admin
      .from("team_invitations")
      .select("email, expires_at, accepted_at")
      .eq("token_hash", tokenHash)
      .maybeSingle();

    const invitationEmail = String(invitation?.email || "").trim().toLowerCase();
    const invitationExpiry = Date.parse(String(invitation?.expires_at || ""));
    if (
      invitationError ||
      !invitation ||
      invitation.accepted_at !== null ||
      !Number.isFinite(invitationExpiry) ||
      invitationExpiry <= Date.now() ||
      invitationEmail !== email
    ) {
      return jsonResponse(request, { error: "Invalid invitation signup." }, 400);
    }

    const { data, error } = await admin.auth.admin.createUser({
      email: invitationEmail,
      password,
      email_confirm: true,
      user_metadata: { team_invitation_token_hash: tokenHash },
    });

    if (error || !data.user) {
      console.error("Invited account creation failed.", error?.code || "CREATE_USER_FAILED");
      return jsonResponse(request, { error: "Unable to create the invited account." }, 400);
    }

    return jsonResponse(request, { created: true });
  } catch (error) {
    console.error("Invitation signup request failed.", error instanceof Error ? error.message : "Unknown error");
    return jsonResponse(request, { error: "Unable to create the invited account." }, 500);
  }
});
