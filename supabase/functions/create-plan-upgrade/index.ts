import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

const planOrder = ["starter", "business", "pro", "enterprise"] as const;
type PlanCode = typeof planOrder[number];
const upgradePortalPurpose = "linecrew_upgrade_only_v1";

class RequestError extends Error {
  status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
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

  const map = new Map<PlanCode, string>();
  for (const plan of planOrder) {
    const price = String((parsed as Record<string, unknown>)[plan] || "").trim();
    if (!/^price_[A-Za-z0-9]+$/.test(price)) {
      throw new Error(`Billing plan mapping is missing a valid ${plan} Price ID.`);
    }
    map.set(plan, price);
  }
  if (new Set(map.values()).size !== planOrder.length) {
    throw new Error("Each billing plan must use a different Stripe Price ID.");
  }
  return map;
}

function planForPrice(priceMap: Map<PlanCode, string>, priceId: string) {
  for (const [plan, configuredPrice] of priceMap.entries()) {
    if (configuredPrice === priceId) return plan;
  }
  return null;
}

async function stripeGet(path: string, stripeKey: string) {
  const response = await fetch(`https://api.stripe.com/v1${path}`, {
    headers: { Authorization: `Bearer ${stripeKey}` },
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || "Stripe request failed.");
  return data;
}

async function stripePost(path: string, body: URLSearchParams, stripeKey: string) {
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

function portalConfigurationSupportsSafeUpgrades(
  configuration: Record<string, unknown>,
) {
  const features = configuration.features as Record<string, unknown> | undefined;
  const update = features?.subscription_update as Record<string, unknown> | undefined;
  const allowedUpdates = Array.isArray(update?.default_allowed_updates)
    ? update.default_allowed_updates.map(String)
    : [];
  return (
    configuration.active === true &&
    update?.enabled === true &&
    allowedUpdates.length === 1 &&
    allowedUpdates[0] === "price" &&
    update?.proration_behavior === "always_invoice"
  );
}

async function resolveUpgradePortalConfiguration(
  configuredId: string | undefined,
  stripeKey: string,
) {
  if (configuredId && /^bpc_[A-Za-z0-9]+$/.test(configuredId)) {
    const configured = await stripeGet(
      `/billing_portal/configurations/${encodeURIComponent(configuredId)}`,
      stripeKey,
    );
    if (!portalConfigurationSupportsSafeUpgrades(configured)) {
      throw new Error("The configured Stripe upgrade Portal is not price-only with immediate proration.");
    }
    return configuredId;
  }

  const listed = await stripeGet("/billing_portal/configurations?active=true&limit=100", stripeKey);
  const matches = (Array.isArray(listed?.data) ? listed.data : []).filter((configuration: Record<string, unknown>) => {
    const metadata = configuration.metadata as Record<string, unknown> | undefined;
    return metadata?.linecrew_purpose === upgradePortalPurpose;
  });
  if (matches.length !== 1) {
    throw new Error("Exactly one active Stripe upgrade-only Portal configuration must be provisioned.");
  }
  const match = matches[0] as Record<string, unknown>;
  if (!portalConfigurationSupportsSafeUpgrades(match)) {
    throw new Error("The discovered Stripe upgrade Portal is not price-only with immediate proration.");
  }
  const id = String(match.id || "");
  if (!/^bpc_[A-Za-z0-9]+$/.test(id)) throw new Error("Stripe returned an invalid upgrade Portal configuration ID.");
  return id;
}

Deno.serve(async request => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "POST required." }, 405);

  try {
    const auth = request.headers.get("Authorization");
    if (!auth) throw new RequestError("Authentication required.", 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    const configuredPortalId = Deno.env.get("STRIPE_UPGRADE_PORTAL_CONFIGURATION_ID");
    const appUrl = (Deno.env.get("APP_URL") || "").replace(/\/$/, "");
    const priceMap = readPlanPriceMap(Deno.env.get("BILLING_PLAN_PRICE_MAP"));
    if (!supabaseUrl || !anonKey || !serviceKey || !stripeKey || !appUrl) {
      throw new Error("Plan upgrade service is not fully configured.");
    }
    const portalConfiguration = await resolveUpgradePortalConfiguration(configuredPortalId, stripeKey);

    let payload: unknown;
    try {
      payload = await request.json();
    } catch {
      throw new RequestError("A target plan is required.");
    }
    const targetPlan = String((payload as { target_plan?: unknown })?.target_plan || "").trim().toLowerCase();
    if (!planOrder.includes(targetPlan as PlanCode)) {
      throw new RequestError("Choose a valid LineCrew Pro plan.");
    }
    const targetPlanCode = targetPlan as PlanCode;
    const targetPrice = priceMap.get(targetPlanCode);
    if (!targetPrice) throw new Error("The selected plan is not enabled for Stripe upgrades.");

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    });
    const service = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) throw new RequestError("Authentication required.", 401);

    const { data: profile, error: profileError } = await userClient
      .from("profiles")
      .select("company_id,role,active")
      .eq("id", userData.user.id)
      .single();
    if (profileError || !profile || profile.active === false) {
      throw new RequestError("Active company profile required.", 403);
    }
    if (String(profile.role).toLowerCase() !== "admin") {
      throw new RequestError("Company Admin access required.", 403);
    }

    const { data: stored, error: storedError } = await service
      .from("company_subscriptions")
      .select("provider,status,cancel_at_period_end,stripe_customer_id,stripe_subscription_id")
      .eq("company_id", profile.company_id)
      .maybeSingle();
    if (storedError) throw storedError;
    if (
      stored?.provider !== "stripe" ||
      !/^cus_[A-Za-z0-9]+$/.test(String(stored?.stripe_customer_id || "")) ||
      !/^sub_[A-Za-z0-9]+$/.test(String(stored?.stripe_subscription_id || ""))
    ) {
      throw new RequestError("This company does not have an active Stripe subscription to upgrade.", 409);
    }
    if (stored.cancel_at_period_end) {
      throw new RequestError("Resume the scheduled cancellation in Manage Billing before upgrading.", 409);
    }

    const subscription = await stripeGet(
      `/subscriptions/${encodeURIComponent(stored.stripe_subscription_id)}`,
      stripeKey,
    );
    if (subscription.customer !== stored.stripe_customer_id) {
      throw new RequestError("Stripe subscription ownership did not match this company.", 409);
    }
    if (!["active", "trialing"].includes(String(subscription.status || ""))) {
      throw new RequestError("Only an active or trialing subscription can be upgraded here.", 409);
    }
    if (subscription.cancel_at_period_end) {
      throw new RequestError("Resume the scheduled cancellation in Manage Billing before upgrading.", 409);
    }

    const items = Array.isArray(subscription?.items?.data) ? subscription.items.data : [];
    if (items.length !== 1) {
      throw new RequestError("This subscription needs LineCrew Pro support before its plan can be changed.", 409);
    }
    const item = items[0];
    if (!/^si_[A-Za-z0-9]+$/.test(String(item?.id || ""))) {
      throw new RequestError("Stripe did not return a valid subscription item.", 409);
    }
    const currentPrice = String(item?.price?.id || "");
    const currentPlan = planForPrice(priceMap, currentPrice);
    if (!currentPlan) {
      throw new RequestError("The current Stripe price is not mapped to a LineCrew Pro plan.", 409);
    }
    if (planOrder.indexOf(targetPlanCode) <= planOrder.indexOf(currentPlan)) {
      throw new RequestError("Self-service billing can only move to a higher plan.", 409);
    }

    const returnUrl = `${appUrl}/billing.html?billing=portal-return`;
    const completedUrl = `${appUrl}/billing.html?billing=upgrade-return&target_plan=${encodeURIComponent(targetPlanCode)}`;
    const params = new URLSearchParams();
    params.set("customer", stored.stripe_customer_id);
    params.set("configuration", portalConfiguration);
    params.set("return_url", returnUrl);
    params.set("flow_data[type]", "subscription_update_confirm");
    params.set("flow_data[subscription_update_confirm][subscription]", stored.stripe_subscription_id);
    params.set("flow_data[subscription_update_confirm][items][0][id]", String(item.id));
    params.set("flow_data[subscription_update_confirm][items][0][price]", targetPrice);
    params.set("flow_data[subscription_update_confirm][items][0][quantity]", "1");
    params.set("flow_data[after_completion][type]", "redirect");
    params.set("flow_data[after_completion][redirect][return_url]", completedUrl);

    const session = await stripePost("/billing_portal/sessions", params, stripeKey);
    if (!session?.url) throw new Error("Stripe did not return an upgrade confirmation URL.");
    return json({ url: session.url, current_plan: currentPlan, target_plan: targetPlanCode });
  } catch (error) {
    console.error(error);
    const status = error instanceof RequestError ? error.status : 400;
    return json({ error: error instanceof Error ? error.message : "Unable to start plan upgrade." }, status);
  }
});
