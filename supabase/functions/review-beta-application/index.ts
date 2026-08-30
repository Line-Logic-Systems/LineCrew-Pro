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

function randomHex(bytes = 32) {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(data, byte => byte.toString(16).padStart(2, "0")).join("");
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
  if (!supabaseUrl || !secretKey || !publishableKey) {
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

  const tokenHash = randomHex(32);
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

  const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(
    String(row.applicant_email),
    {
      redirectTo: "https://app.linecrewpro.com/",
      data: {
        team_invitation_token_hash: tokenHash,
        beta_pilot: true,
        full_name: String(row.applicant_name || ""),
      },
    },
  );

  if (inviteError) {
    console.error("Beta admin invitation email failed.", inviteError.code || "INVITE_FAILED");
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
