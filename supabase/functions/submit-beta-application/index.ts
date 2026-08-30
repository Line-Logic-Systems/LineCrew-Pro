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

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
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

  const { error } = await admin.from("beta_applications").insert({
    company_name: companyName,
    contact_name: contactName,
    email,
    phone: phone || null,
    active_crew_count: crews,
    testing_notes: notes || null,
    request_fingerprint_hash: fingerprint,
    source: "website",
  });

  if (error) {
    if (error.code === "23505") {
      return jsonResponse(request, { received: true });
    }
    console.error("Beta application insert failed.", error.code || "INSERT_FAILED");
    return jsonResponse(request, { error: "Unable to submit the application right now." }, 500);
  }

  return jsonResponse(request, { received: true });
});
