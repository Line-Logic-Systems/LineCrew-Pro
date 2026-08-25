import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

async function stripeRequest(
  path: string,
  body: URLSearchParams,
  stripeKey: string,
  idempotencyKey?: string,
) {
  const response = await fetch(`https://api.stripe.com/v1${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
    },
    body,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || "Stripe request failed.");
  return data;
}

function readPlanPriceMap(raw: string | undefined) {
  if (!raw) throw new Error("Billing plan mapping is not configured.");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Billing plan mapping is invalid JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Billing plan mapping must be an object.");
  }
  const map = new Map<string, string>();
  for (const [plan, price] of Object.entries(parsed as Record<string, unknown>)) {
    const cleanPlan = String(plan || "").trim().toLowerCase();
    const cleanPrice = String(price || "").trim();
    if (cleanPlan && /^price_[A-Za-z0-9]+$/.test(cleanPrice)) map.set(cleanPlan, cleanPrice);
  }
  if (!map.size) throw new Error("Billing plan mapping contains no enabled plans.");
  return map;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "POST required." }, 405);

  try {
    const auth = request.headers.get("Authorization");
    if (!auth) throw new Error("Authentication required.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    const appUrl = (Deno.env.get("APP_URL") || "").replace(/\/$/, "");
    const planPriceMap = readPlanPriceMap(Deno.env.get("BILLING_PLAN_PRICE_MAP"));
    if (!supabaseUrl || !anonKey || !serviceKey || !stripeKey || !appUrl) {
      throw new Error("Billing service is not fully configured.");
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    });
    const serviceClient = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) throw new Error("Authentication required.");

    const { data: profile, error: profileError } = await userClient
      .from("profiles")
      .select("company_id,role,active")
      .eq("id", userData.user.id)
      .single();
    if (profileError || !profile || profile.active === false) throw new Error("Active company profile required.");
    if (String(profile.role).toLowerCase() !== "admin") {
      return json({ error: "Company Admin access required." }, 403);
    }

    const { data: company, error: companyError } = await userClient
      .from("companies")
      .select("id,name,contact_email")
      .eq("id", profile.company_id)
      .single();
    if (companyError || !company) throw new Error("Company not found.");

    const { data: existing, error: existingError } = await serviceClient
      .from("company_subscriptions")
      .select("plan_code,status,provider,stripe_customer_id,stripe_subscription_id")
      .eq("company_id", company.id)
      .maybeSingle();
    if (existingError) throw existingError;

    const planCode = String(existing?.plan_code || "").trim().toLowerCase();
    const priceId = planPriceMap.get(planCode);
    if (!planCode || !priceId) {
      throw new Error("This company does not yet have a Stripe-enabled plan assigned by LineCrew Pro support.");
    }

    if (
      existing?.stripe_subscription_id &&
      !["canceled"].includes(String(existing.status || "").toLowerCase())
    ) {
      return json({
        error: "This company already has a Stripe subscription. Use Manage Billing instead of starting another subscription.",
      }, 409);
    }

    let customerId = existing?.stripe_customer_id || null;
    if (!customerId) {
      const customerParams = new URLSearchParams();
      customerParams.set("name", company.name || "LineCrew Pro Company");
      if (company.contact_email) customerParams.set("email", company.contact_email);
      customerParams.set("metadata[company_id]", company.id);
      const customer = await stripeRequest(
        "/customers",
        customerParams,
        stripeKey,
        `linecrew-customer-${company.id}`,
      );
      customerId = customer.id;

      const { error: saveCustomerError } = await serviceClient.from("company_subscriptions").upsert({
        company_id: company.id,
        plan_code: planCode,
        provider: "stripe",
        stripe_customer_id: customerId,
        status: "incomplete",
        access_enabled: true,
        updated_at: new Date().toISOString(),
      }, { onConflict: "company_id" });
      if (saveCustomerError) throw saveCustomerError;
    }

    const params = new URLSearchParams();
    params.set("mode", "subscription");
    params.set("customer", customerId);
    params.set("line_items[0][price]", priceId);
    params.set("line_items[0][quantity]", "1");
    params.set("success_url", `${appUrl}/billing.html?billing=success&session_id={CHECKOUT_SESSION_ID}`);
    params.set("cancel_url", `${appUrl}/billing.html?billing=canceled`);
    params.set("client_reference_id", company.id);
    params.set("metadata[company_id]", company.id);
    params.set("metadata[plan_code]", planCode);
    params.set("subscription_data[metadata][company_id]", company.id);
    params.set("subscription_data[metadata][plan_code]", planCode);
    params.set("allow_promotion_codes", "true");

    // Reuse the same Stripe response for retries or double-clicks so one
    // company/plan cannot accidentally open two simultaneous subscriptions.
    const session = await stripeRequest(
      "/checkout/sessions",
      params,
      stripeKey,
      `linecrew-checkout-${company.id}-${planCode}`,
    );
    if (!session?.url) throw new Error("Stripe did not return a Checkout URL.");
    return json({ url: session.url, plan_code: planCode });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Unable to start billing checkout." }, 400);
  }
});
