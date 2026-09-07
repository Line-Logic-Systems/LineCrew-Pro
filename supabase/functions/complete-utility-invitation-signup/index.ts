import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";

const testProjectRef = "yvuxrqrdprquxypiffpa";
const isTestProject = (Deno.env.get("SUPABASE_URL") || "").includes(testProjectRef);
const allowedOrigins = new Set(["https://app.linecrewpro.com"]);
if (isTestProject) {
  ["http://localhost:3000", "http://localhost:4173", "http://localhost:8000",
   "http://127.0.0.1:3000", "http://127.0.0.1:4173", "http://127.0.0.1:8000"]
    .forEach((origin) => allowedOrigins.add(origin));
}
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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(request) });
  if (request.method !== "POST") return respond(request, { error: "Method not allowed." }, 405);
  const origin = request.headers.get("Origin");
  if (origin && !allowedOrigins.has(origin)) return respond(request, { error: "Origin not allowed." }, 403);

  let createdUserId = "";
  try {
    const body = await request.json().catch(() => ({}));
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.password || "");
    const fullName = String(body?.fullName || "").trim().slice(0, 120);
    const rawToken = String(body?.token || "");
    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
        || password.length < 8 || password.length > 128 || fullName.length < 2
        || !/^[A-Za-z0-9_-]{43}$/.test(rawToken)) {
      return respond(request, { error: "Invalid invitation signup." }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey = getPublishableKey();
    const secretKey = getSecretKey();
    if (!supabaseUrl || !publishableKey || !secretKey) {
      console.error("Utility signup service configuration is incomplete.");
      return respond(request, { error: "Invitation signup is unavailable." }, 503);
    }
    const tokenHash = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawToken))));
    const admin = createClient(supabaseUrl, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: invitation, error: invitationError } = await admin.from("utility_users")
      .select("email, status, invite_expires_at")
      .eq("invite_token_hash", tokenHash).maybeSingle();
    const expiresAt = Date.parse(String(invitation?.invite_expires_at || ""));
    if (invitationError || !invitation || invitation.status !== "invited"
        || String(invitation.email).toLowerCase() !== email
        || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      return respond(request, { error: "Invalid invitation signup." }, 400);
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { utility_portal_invitation: true },
    });
    if (createError || !created.user) {
      console.error("Utility Auth account creation failed.", createError?.code || "CREATE_USER_FAILED");
      return respond(request, { error: "Unable to create the invited account." }, 400);
    }
    createdUserId = created.user.id;

    const userClient = createClient(supabaseUrl, publishableKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: session, error: signInError } = await userClient.auth.signInWithPassword({ email, password });
    if (signInError || !session.session) throw new Error("UTILITY_SIGN_IN_FAILED");
    const authenticated = createClient(supabaseUrl, publishableKey, {
      global: { headers: { Authorization: `Bearer ${session.session.access_token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error: acceptError } = await authenticated.rpc("utility_accept_invitation", {
      p_token_hash: tokenHash, p_full_name: fullName,
    });
    if (acceptError) throw new Error(`UTILITY_ACCEPT_FAILED:${acceptError.code || "RPC_ERROR"}`);
    return respond(request, { created: true });
  } catch (error) {
    console.error("Utility invitation signup failed.", error instanceof Error ? error.message : "Unknown error");
    if (createdUserId) {
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const secretKey = getSecretKey();
      if (supabaseUrl && secretKey) {
        const admin = createClient(supabaseUrl, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
        const { error: cleanupError } = await admin.auth.admin.deleteUser(createdUserId);
        if (cleanupError) console.error("Failed to clean up incomplete utility Auth user.", cleanupError.code || "DELETE_USER_FAILED");
      }
    }
    return respond(request, { error: "Unable to create the invited account." }, 400);
  }
});
