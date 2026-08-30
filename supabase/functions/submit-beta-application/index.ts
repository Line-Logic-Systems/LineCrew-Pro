import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getSecretKey } from "../_shared/api-keys.ts";

const ALLOWED_ORIGINS = new Set([
  "https://linecrewpro.com",
  "https://www.linecrewpro.com",
  "http://localhost:3000",
  "http://127.0.0.1:3000",
]);

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "https://linecrewpro.com",
    "Access-Control-Allow-Headers": "content-type, apikey, x-client-info",
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

function cleanText(value: unknown, max: number) {
  return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max);
}

function validEmail(email: string) {
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
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
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function sendSalesNotification(application: {
  id: string;
  submitted_at: string;
  companyName: string;
  contactName: string;
  email: string;
  phone: string;
  crews: number;
  notes: string;
}) {
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!resendApiKey) {
    console.error("Beta sales notification is missing RESEND_API_KEY.");
    return false;
  }

  const subject = `[Beta Application] ${application.companyName} — ${application.crews} crew${application.crews === 1 ? "" : "s"}`;
  const text = [
    "New LineCrew Pro Beta/Pilot application",
    "",
    `Company: ${application.companyName}`,
    `Contact: ${application.contactName}`,
    `Email: ${application.email}`,
    `Phone: ${application.phone || "Not provided"}`,
    `Active crews: ${application.crews}`,
    `Submitted: ${application.submitted_at}`,
    `Application ID: ${application.id}`,
    "",
    "What they want to test:",
    application.notes || "Not provided",
    "",
    "Review this application in the LineCrew Pro Platform Owner console.",
    "https://app.linecrewpro.com/owner.html",
  ].join("\n");

  const html = `<!doctype html><html><body style="margin:0;background:#f4f7f5;font-family:Arial,sans-serif;color:#15231b"><div style="max-width:680px;margin:0 auto;padding:32px 20px"><div style="background:#fff;border:1px solid #dce6df;border-radius:12px;padding:28px"><h1 style="margin:0 0 18px;font-size:22px">New Beta/Pilot application</h1><table style="border-collapse:collapse;width:100%;font-size:14px"><tr><td style="padding:5px 12px 5px 0;color:#526158">Company</td><td><strong>${escapeHtml(application.companyName)}</strong></td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Contact</td><td>${escapeHtml(application.contactName)}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Email</td><td>${escapeHtml(application.email)}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Phone</td><td>${escapeHtml(application.phone || "Not provided")}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Active crews</td><td>${application.crews}</td></tr><tr><td style="padding:5px 12px 5px 0;color:#526158">Submitted</td><td>${escapeHtml(application.submitted_at)}</td></tr></table><div style="margin-top:20px;padding:16px;background:#f4f7f5;border-radius:8px;white-space:pre-wrap;line-height:1.45"><strong>What they want to test</strong><br>${escapeHtml(application.notes || "Not provided")}</div><p style="margin:22px 0 0"><a href="https://app.linecrewpro.com/owner.html" style="display:inline-block;padding:10px 16px;background:#15231b;color:#fff;text-decoration:none;border-radius:7px">Review application</a></p><p style="font-size:12px;color:#6a746e;margin:18px 0 0">Application ID: ${escapeHtml(application.id)}</p></div></div></body></html>`;

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `beta-application-${application.id}`,
    },
    body: JSON.stringify({
      from: "LineCrew Pro <invites@auth.linecrewpro.com>",
      to: ["sales@linecrewpro.com"],
      reply_to: application.email,
      subject,
      text,
      html,
    }),
  });

  if (!response.ok) {
    console.error("Resend rejected a Beta application notification.", response.status);
    return false;
  }
  return true;
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
  const length = Number(request.headers.get("content-length") || 0);
  if (length > 20000) {
    return jsonResponse(request, { error: "Request too large." }, 413);
  }

  const body = await request.json().catch(() => null);
  if (!body || typeof body !== "object") {
    return jsonResponse(request, { error: "Invalid application." }, 400);
  }
  const record = body as Record<string, unknown>;

  if (cleanText(record.website, 200)) {
    return jsonResponse(request, { received: true });
  }

  const companyName = cleanText(record.company_name, 120);
  const contactName = cleanText(record.contact_name, 120);
  const email = cleanText(record.email, 254).toLowerCase();
  const phone = cleanText(record.phone, 30);
  const notes = cleanText(record.testing_notes, 2000);
  const crews = Number(record.active_crew_count);

  if (
    companyName.length < 2 ||
    contactName.length < 2 ||
    !validEmail(email) ||
    !Number.isInteger(crews) ||
    crews < 1 ||
    crews > 500
  ) {
    return jsonResponse(request, { error: "Please complete all required fields correctly." }, 400);
  }
  if (phone && phone.length < 7) {
    return jsonResponse(request, { error: "Enter a valid phone number or leave it blank." }, 400);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secretKey = getSecretKey();
  if (!supabaseUrl || !secretKey) {
    console.error("Beta application service is missing server configuration.");
    return jsonResponse(request, { error: "Application service is unavailable." }, 503);
  }

  const forwarded = (request.headers.get("x-forwarded-for") || "unknown").split(",")[0].trim();
  const userAgent = request.headers.get("user-agent") || "unknown";
  const fingerprint = await sha256Hex(`${forwarded}|${userAgent}`);
  const admin = createClient(supabaseUrl, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count, error: countError } = await admin
    .from("beta_applications")
    .select("id", { count: "exact", head: true })
    .eq("request_fingerprint_hash", fingerprint)
    .gte("submitted_at", oneHourAgo);
  if (countError) {
    console.error("Beta application rate check failed.", countError.code || "RATE_CHECK_FAILED");
    return jsonResponse(request, { error: "Application service is unavailable." }, 503);
  }
  if ((count || 0) >= 5) {
    return jsonResponse(request, { error: "Too many applications from this connection. Please try again later." }, 429);
  }

  const { data: existing, error: existingError } = await admin
    .from("beta_applications")
    .select("id")
    .eq("status", "pending")
    .ilike("email", email)
    .maybeSingle();
  if (existingError) {
    console.error("Beta duplicate check failed.", existingError.code || "DUPLICATE_CHECK_FAILED");
    return jsonResponse(request, { error: "Application service is unavailable." }, 503);
  }
  if (existing) {
    return jsonResponse(request, { received: true });
  }

  const { data: inserted, error } = await admin.from("beta_applications").insert({
    company_name: companyName,
    contact_name: contactName,
    email,
    phone: phone || null,
    active_crew_count: crews,
    testing_notes: notes || null,
    request_fingerprint_hash: fingerprint,
    source: "website",
  }).select("id,submitted_at").single();

  if (error || !inserted) {
    if (error?.code === "23505") {
      return jsonResponse(request, { received: true });
    }
    console.error("Beta application insert failed.", error?.code || "INSERT_FAILED");
    return jsonResponse(request, { error: "Unable to submit the application right now." }, 500);
  }

  try {
    await sendSalesNotification({
      id: String(inserted.id),
      submitted_at: String(inserted.submitted_at),
      companyName,
      contactName,
      email,
      phone,
      crews,
      notes,
    });
  } catch (notificationError) {
    console.error("Beta sales notification failed.", notificationError instanceof Error ? notificationError.message : "Unknown error");
  }

  return jsonResponse(request, { received: true });
});
