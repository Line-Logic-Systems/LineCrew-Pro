import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";

const allowedOrigins = new Set(["https://app.linecrewpro.com"]);
const feedbackIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

function titleCase(value: unknown) {
  const text = String(value || "Other").trim().toLowerCase();
  return text.charAt(0).toUpperCase() + text.slice(1);
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
    if (!authorization) {
      return jsonResponse(request, { error: "Authentication required." }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey = getPublishableKey();
    const secretKey = getSecretKey();
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!supabaseUrl || !publishableKey || !secretKey || !resendApiKey) {
      console.error("Pilot feedback notifier is missing required server configuration.");
      return jsonResponse(request, { error: "Feedback email service is unavailable." }, 503);
    }

    const body = await request.json().catch(() => ({}));
    const feedbackId = String(body?.feedback_id || "").trim();
    if (!feedbackIdPattern.test(feedbackId)) {
      return jsonResponse(request, { error: "A valid feedback record is required." }, 400);
    }

    const userClient = createClient(supabaseUrl, publishableKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse(request, { error: "Authentication required." }, 401);
    }

    const service = createClient(supabaseUrl, secretKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: feedback, error: feedbackError } = await service
      .from("pilot_feedback")
      .select("id,company_id,submitted_by,category,rating,message,page,contact_ok,created_at")
      .eq("id", feedbackId)
      .maybeSingle();
    if (feedbackError || !feedback || feedback.submitted_by !== userData.user.id) {
      return jsonResponse(request, { error: "Feedback record not found." }, 404);
    }

    const [{ data: profile, error: profileError }, { data: company, error: companyError }] = await Promise.all([
      service.from("profiles").select("company_id,full_name,active").eq("id", userData.user.id).maybeSingle(),
      service.from("companies").select("name,active").eq("id", feedback.company_id).maybeSingle(),
    ]);
    if (
      profileError || companyError || !profile || !company ||
      profile.active !== true || company.active !== true ||
      profile.company_id !== feedback.company_id
    ) {
      return jsonResponse(request, { error: "Active company profile required." }, 403);
    }

    const category = titleCase(feedback.category);
    const companyName = String(company.name || "Unknown company").slice(0, 160);
    const submitterName = String(profile.full_name || "Company user").slice(0, 160);
    const submitterEmail = String(userData.user.email || "").trim().toLowerCase();
    const rating = Number(feedback.rating);
    const message = String(feedback.message || "").slice(0, 2000);
    const page = String(feedback.page || "app").slice(0, 100);
    const createdAt = new Date(feedback.created_at).toISOString();
    const contactPermission = feedback.contact_ok === true ? "Yes" : "No";
    const subject = `[Pilot Feedback] ${category} — ${companyName} — ${rating}/5`;
    const text = [
      "New LineCrew Pro pilot feedback",
      "",
      `Company: ${companyName}`,
      `Submitted by: ${submitterName}${submitterEmail ? ` <${submitterEmail}>` : ""}`,
      `Category: ${category}`,
      `Rating: ${rating}/5`,
      `Page: ${page}`,
      `May contact: ${contactPermission}`,
      `Submitted: ${createdAt}`,
      `Feedback ID: ${feedback.id}`,
      "",
      message,
      "",
      "This feedback is also stored in the LineCrew Pro Platform Support Console.",
    ].join("\n");
    const html = `<!doctype html><html><body style="margin:0;background:#f4f7f5;font-family:Arial,sans-serif;color:#15231b"><div style="max-width:680px;margin:0 auto;padding:32px 20px"><div style="background:#fff;border:1px solid #dce6df;border-radius:12px;padding:28px"><h1 style="margin:0 0 18px;font-size:22px">New pilot feedback</h1><table style="border-collapse:collapse;width:100%;font-size:14px"><tr><td style="padding:5px 12px 5px 0;color:#526158">Company</td><td><strong>${escapeHtml(companyName)}</strong></td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Submitted by</td><td>${escapeHtml(submitterName)}${submitterEmail ? ` &lt;${escapeHtml(submitterEmail)}&gt;` : ""}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Category</td><td>${escapeHtml(category)}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Rating</td><td>${rating}/5</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Page</td><td>${escapeHtml(page)}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">May contact</td><td>${contactPermission}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Submitted</td><td>${escapeHtml(createdAt)}</td></tr></table><div style="margin-top:20px;padding:16px;background:#f4f7f5;border-radius:8px;white-space:pre-wrap;line-height:1.45">${escapeHtml(message)}</div><p style="font-size:12px;color:#6a746e;margin:18px 0 0">Feedback ID: ${escapeHtml(feedback.id)}. This record is also stored in the Platform Support Console.</p></div></div></body></html>`;

    const emailPayload: Record<string, unknown> = {
      from: "LineCrew Pro <invites@auth.linecrewpro.com>",
      to: ["support@linecrewpro.com"],
      subject,
      text,
      html,
    };
    if (feedback.contact_ok === true && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(submitterEmail)) {
      emailPayload.reply_to = submitterEmail;
    }

    const resendResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `pilot-feedback-${feedback.id}`,
      },
      body: JSON.stringify(emailPayload),
    });
    if (!resendResponse.ok) {
      console.error("Resend rejected a pilot feedback notification.", resendResponse.status);
      return jsonResponse(request, { error: "Feedback was saved, but its email notification could not be sent." }, 502);
    }

    return jsonResponse(request, { sent: true });
  } catch (error) {
    console.error("Pilot feedback notification failed.", error instanceof Error ? error.message : "Unknown error");
    return jsonResponse(request, { error: "Feedback was saved, but its email notification could not be sent." }, 500);
  }
});
