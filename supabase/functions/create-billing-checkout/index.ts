import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

async function stripeRequest(path: string, body: URLSearchParams, stripeKey: string) {
  const response = await fetch(`https://api.stripe.com/v1${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || "Stripe request failed.");
  return data;
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
    const allowedPrices = new Set((Deno.env.get("BILLING_ALLOWED_PRICE_IDS") || "").split(",").map(v => v.trim()).filter(Boolean));
    if (!supabaseUrl || !anonKey || !serviceKey || !stripeKey || !appUrl) throw new Error("Billing service is not fully configured.");

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
    if (String(profile.role).toLowerCase() !== "admin") return json({ error: "Company Admin access required." }, 403);

    const body = await request.json();
    const priceId = String(body?.price_id || "").trim();
    if (!priceId || (allowedPrices.size && !allowedPrices.has(priceId))) throw new Error("Selected billing price is not enabled.");

    const { data: company, error: companyError } = await userClient
      .from("companies")
      .select("id,name,contact_email")
      .eq("id", profile.company_id)
      .single();
    if (companyError || !company) throw new Error("Company not found.");

    const { data: existing } = await serviceClient
      .from("company_subscriptions")
      .select("stripe_customer_id")
      .eq("company_id", company.id)
      .maybeSingle();

    let customerId = existing?.stripe_customer_id || null;
    if (!customerId) {
      const params = new URLSearchParams();
      params.set("name", company.name || "LineCrew Pro Company");
      if (company.contact_email) params.set("email", company.contact_email);
      params.set("metadata[company_id]", company.id);
      const customer = await stripeRequest("/customers", params, stripeKey);
      customerId = customer.id;
      await serviceClient.from("company_subscriptions").upsert({
        company_id: company.id,
        provider: "stripe",
        stripe_customer_id: customerId,
        status: "incomplete",
        access_enabled: true,
        updated_at: new Date().toISOString(),
      }, { onConflict: "company_id" });
    }

    const params = new URLSearchParams();
    params.set("mode", "subscription");
    params.set("customer", customerId);
    params.set("line_items[0][price]", priceId);
    params.set("line_items[0][quantity]", "1");
    params.set("success_url", `${appUrl}/?billing=success&session_id={CHECKOUT_SESSION_ID}`);
    params.set("cancel_url", `${appUrl}/?billing=canceled`);
    params.set("client_reference_id", company.id);
    params.set("metadata[company_id]", company.id);
    params.set("subscription_data[metadata][company_id]", company.id);
    params.set("allow_promotion_codes", "true");

    const session = await stripeRequest("/checkout/sessions", params, stripeKey);
    return json({ url: session.url });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Unable to start billing checkout." }, 400);
  }
});
