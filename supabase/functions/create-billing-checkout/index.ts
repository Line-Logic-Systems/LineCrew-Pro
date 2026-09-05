import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";
import {
  INCLUDED_CREWS,
  LINECREW_PLAN_CODE,
  normalizeCrewQuantity,
  readLinecrewPriceId,
} from "../_shared/billing-pricing.ts";

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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "POST required." }, 405);

  try {
    const payload = await request.json().catch(() => ({})) as Record<string, unknown>;
    const requestedPlan = String(payload.requested_plan || LINECREW_PLAN_CODE).trim().toLowerCase();
    if (requestedPlan !== LINECREW_PLAN_CODE) {
      return json({ error: "LineCrew Pro now has one crew-based subscription." }, 400);
    }

    const auth = request.headers.get("Authorization");
    if (!auth) throw new Error("Authentication required.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = getPublishableKey();
    const serviceKey = getSecretKey();
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    const appUrl = (Deno.env.get("APP_URL") || "").replace(/\/$/, "");
    const priceId = readLinecrewPriceId(
      Deno.env.get("BILLING_PLAN_PRICE_MAP"),
      Deno.env.get("STRIPE_ENVIRONMENT"),
    );
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

    const accessToken = auth.replace(/^Bearer\s+/i, "").trim();
    const { data: claimsData, error: claimsError } = await userClient.auth.getClaims(accessToken);
    if (claimsError || claimsData?.claims?.aal !== "aal2") {
      return json({ error: "Complete multi-factor authentication before managing billing." }, 403);
    }

    const { data: profile, error: profileError } = await serviceClient
      .from("profiles")
      .select("company_id,role,active")
      .eq("id", userData.user.id)
      .single();
    if (profileError || !profile || profile.active === false) throw new Error("Active company profile required.");
    if (!["owner", "admin"].includes(String(profile.role).toLowerCase())) {
      return json({ error: "Company Owner or Admin access required." }, 403);
    }

    const { data: company, error: companyError } = await serviceClient
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

    if (
      requestedPlan && existing?.stripe_subscription_id &&
      !["canceled"].includes(String(existing.status || "").toLowerCase())
    ) {
      return json({ error: "This company already has a Stripe subscription. Use Manage Billing instead." }, 409);
    }

    const { count: activeCrewCount, error: crewCountError } = await serviceClient
      .from("crews").select("id", { count: "exact", head: true })
      .eq("company_id", company.id).eq("active", true);
    if (crewCountError) throw crewCountError;
    const requestedCrewQuantity = payload.crew_quantity == null
      ? Math.max(INCLUDED_CREWS, Number(activeCrewCount || 0))
      : normalizeCrewQuantity(payload.crew_quantity);
    const crewQuantity = Math.max(requestedCrewQuantity, Number(activeCrewCount || 0));
    const planCode = LINECREW_PLAN_CODE;

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

      // Starting Checkout links a Stripe customer and nothing else. status,
      // access_enabled, plan_code and trial_ends_at belong to the signed
      // customer.subscription webhook alone, so a company that abandons or
      // fails Checkout keeps the access and trial window it already had. The
      // requested plan still reaches the webhook through Checkout metadata and
      // the subscription price below.
      if (existing) {
        const { error: linkCustomerError } = await serviceClient
          .from("company_subscriptions")
          .update({
            provider: "stripe",
            stripe_customer_id: customerId,
            updated_at: new Date().toISOString(),
          })
          .eq("company_id", company.id)
          .is("stripe_customer_id", null);
        if (linkCustomerError) throw linkCustomerError;
      } else {
        // A company with no subscription row is already inactive to
        // enforce_linecrew_company_access, so seeding the customer link cannot
        // remove access it does not currently have.
        const { error: seedCustomerError } = await serviceClient
          .from("company_subscriptions")
          .insert({
            company_id: company.id,
            provider: "stripe",
            stripe_customer_id: customerId,
            status: "incomplete",
            access_enabled: false,
            updated_at: new Date().toISOString(),
          });
        if (seedCustomerError) throw seedCustomerError;
      }
    }

    const params = new URLSearchParams();
    params.set("mode", "subscription");
    params.set("customer", customerId);
    params.set("line_items[0][price]", priceId);
    params.set("line_items[0][quantity]", String(crewQuantity));
    params.set("success_url", `${appUrl}/billing.html?billing=success&session_id={CHECKOUT_SESSION_ID}`);
    params.set("cancel_url", `${appUrl}/billing.html?billing=canceled`);
    params.set("client_reference_id", company.id);
    params.set("metadata[company_id]", company.id);
    params.set("metadata[plan_code]", planCode);
    params.set("metadata[licensed_crews]", String(crewQuantity));
    params.set("subscription_data[metadata][company_id]", company.id);
    params.set("subscription_data[metadata][plan_code]", planCode);
    params.set("subscription_data[metadata][licensed_crews]", String(crewQuantity));
    // Promote whichever card actually settles an invoice to the subscription
    // default. Without this a company that rescues a past-due invoice with a
    // new card on the hosted invoice page keeps the old failing card on file
    // and goes past due again on the next cycle.
    params.set(
      "subscription_data[payment_settings][save_default_payment_method]",
      "on_subscription",
    );
    params.set("allow_promotion_codes", "true");

    // Reuse the same Stripe response for retries or double-clicks so one
    // company/plan cannot accidentally open two simultaneous subscriptions.
    const session = await stripeRequest(
      "/checkout/sessions",
      params,
      stripeKey,
      `linecrew-checkout-${company.id}-${planCode}-${crewQuantity}`,
    );
    if (!session?.url) throw new Error("Stripe did not return a Checkout URL.");
    return json({ url: session.url, plan_code: planCode, licensed_crews: crewQuantity });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Unable to start billing checkout." }, 400);
  }
});
