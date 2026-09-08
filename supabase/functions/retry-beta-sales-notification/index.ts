import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getSecretKey } from "../_shared/api-keys.ts";
import { sendBetaSalesNotification } from "../_shared/beta-sales-notification.ts";

const ALLOWED_ORIGINS = new Set(["https://app.linecrewpro.com", "http://localhost:3000", "http://127.0.0.1:3000"]);
function headers(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return { "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "https://app.linecrewpro.com", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Content-Type": "application/json", "Vary": "Origin" };
}
function json(request: Request, body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: headers(request) });
}

Deno.serve(async request => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: headers(request) });
  if (request.method !== "POST") return json(request, { error: "Method not allowed." }, 405);
  const origin = request.headers.get("Origin");
  if (origin && !ALLOWED_ORIGINS.has(origin)) return json(request, { error: "Origin not allowed." }, 403);

  const bearer = (request.headers.get("Authorization") || "").match(/^Bearer\s+(.+)$/i);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secretKey = getSecretKey();
  if (!bearer || !supabaseUrl || !secretKey) return json(request, { error: "Authentication required." }, 401);
  const admin = createClient(supabaseUrl, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData } = await admin.auth.getUser(bearer[1]);
  if (!userData.user) return json(request, { error: "Authentication required." }, 401);
  const { data: owner } = await admin.from("platform_owners").select("user_id").eq("user_id", userData.user.id).maybeSingle();
  if (!owner) return json(request, { error: "Platform owner access required." }, 403);

  const body = await request.json().catch(() => ({}));
  const applicationId = String(body?.application_id || "").trim();
  if (!/^[0-9a-f-]{36}$/i.test(applicationId)) return json(request, { error: "Invalid application." }, 400);
  const { data: application, error: loadError } = await admin.from("beta_applications")
    .select("id,submitted_at,company_name,contact_name,email,phone,active_crew_count,testing_notes,sales_notification_attempts,sales_notification_last_attempt_at")
    .eq("id", applicationId).maybeSingle();
  if (loadError || !application) return json(request, { error: "Beta application not found." }, 404);
  if (application.sales_notification_last_attempt_at && Date.now() - new Date(application.sales_notification_last_attempt_at).getTime() < 60_000) {
    return json(request, { error: "Please wait one minute before retrying this email." }, 429);
  }

  const attemptNumber = Number(application.sales_notification_attempts || 0) + 1;
  const result = await sendBetaSalesNotification({
    id: application.id,
    submitted_at: application.submitted_at,
    companyName: application.company_name,
    contactName: application.contact_name,
    email: application.email,
    phone: application.phone || "",
    crews: application.active_crew_count,
    notes: application.testing_notes || "",
  }, attemptNumber);
  const attemptedAt = new Date().toISOString();
  const { error: updateError } = await admin.from("beta_applications").update({
    sales_notification_status: result.sent ? "sent" : "failed",
    sales_notification_attempts: attemptNumber,
    sales_notification_last_attempt_at: attemptedAt,
    sales_notification_sent_at: result.sent ? attemptedAt : null,
    sales_notification_provider_id: result.providerId,
    sales_notification_error: result.error,
  }).eq("id", applicationId);
  if (updateError) return json(request, { error: "Email result could not be recorded safely." }, 500);
  if (!result.sent) return json(request, { sent: false, error: result.error || "Resend rejected the email." }, 502);
  return json(request, { sent: true, provider_id: result.providerId });
});
