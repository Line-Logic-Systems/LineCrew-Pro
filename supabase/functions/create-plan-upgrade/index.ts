import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";
import { INCLUDED_CREWS, normalizeCrewQuantity, readLinecrewPriceId } from "../_shared/billing-pricing.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const upgradePortalPurpose = "linecrew_crew_quantity_v1";

class RequestError extends Error {
  status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

async function stripeGet(path: string, stripeKey: string) {
  const response = await fetch(`https://api.stripe.com/v1${path}`, {
    headers: { Authorization: `Bearer ${stripeKey}` },
  });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data?.error?.message || "Stripe request failed.");
  }
  return data;
}

async function stripePost(
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
  if (!response.ok) {
    throw new Error(data?.error?.message || "Stripe request failed.");
  }
  return data;
}

function portalConfigurationSupportsSafeUpgrades(
  configuration: Record<string, unknown>,
) {
  const features = configuration.features as
    | Record<string, unknown>
    | undefined;
  const update = features?.subscription_update as
    | Record<string, unknown>
    | undefined;
  const allowedUpdates = Array.isArray(update?.default_allowed_updates)
    ? update.default_allowed_updates.map(String)
    : [];
  return (
    configuration.active === true &&
    update?.enabled === true &&
    allowedUpdates.length === 1 &&
    allowedUpdates[0] === "quantity" &&
    update?.proration_behavior === "always_invoice"
  );
}

async function resolveUpgradePortalConfiguration(
  configuredId: string | undefined,
  stripeKey: string,
) {
  if (configuredId) {
    if (!/^bpc_[A-Za-z0-9]+$/.test(configuredId)) {
      throw new Error(
        "The configured Stripe upgrade Portal configuration ID is invalid.",
      );
    }
    const configured = await stripeGet(
      `/billing_portal/configurations/${encodeURIComponent(configuredId)}`,
      stripeKey,
    );
    if (portalConfigurationSupportsSafeUpgrades(configured)) return configuredId;
    console.warn("Ignoring legacy Stripe Portal configuration that is not quantity-only.");
  }

  const listed = await stripeGet(
    "/billing_portal/configurations?active=true&limit=100",
    stripeKey,
  );
  const matches = (Array.isArray(listed?.data) ? listed.data : []).filter(
    (configuration: Record<string, unknown>) => {
      const metadata = configuration.metadata as
        | Record<string, unknown>
        | undefined;
      return metadata?.linecrew_purpose === upgradePortalPurpose;
    },
  );
  if (matches.length > 1) {
    throw new Error(
      "More than one active LineCrew Pro quantity Portal configuration exists.",
    );
  }
  if (matches.length === 0) {
    const params = new URLSearchParams();
    params.set("features[subscription_update][enabled]", "true");
    params.set("features[subscription_update][default_allowed_updates][0]", "quantity");
    params.set("features[subscription_update][proration_behavior]", "always_invoice");
    params.set("features[payment_method_update][enabled]", "true");
    params.set("metadata[linecrew_purpose]", upgradePortalPurpose);
    const created = await stripePost(
      "/billing_portal/configurations",
      params,
      stripeKey,
      `linecrew-crew-quantity-portal-${upgradePortalPurpose}`,
    );
    if (!portalConfigurationSupportsSafeUpgrades(created)) {
      throw new Error("Stripe did not create a safe quantity-only Portal configuration.");
    }
    return String(created.id);
  }
  const match = matches[0] as Record<string, unknown>;
  if (!portalConfigurationSupportsSafeUpgrades(match)) {
    throw new Error(
      "The discovered Stripe billing Portal is not quantity-only with immediate proration.",
    );
  }
  const id = String(match.id || "");
  if (!/^bpc_[A-Za-z0-9]+$/.test(id)) {
    throw new Error(
      "Stripe returned an invalid upgrade Portal configuration ID.",
    );
  }
  return id;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") return json({ error: "POST required." }, 405);

  try {
    const auth = request.headers.get("Authorization");
    if (!auth) throw new RequestError("Authentication required.", 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = getPublishableKey();
    const serviceKey = getSecretKey();
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    const configuredPortalId = Deno.env.get(
      "STRIPE_UPGRADE_PORTAL_CONFIGURATION_ID",
    );
    const appUrl = (Deno.env.get("APP_URL") || "").replace(/\/$/, "");
    const linecrewPrice = readLinecrewPriceId(
      Deno.env.get("BILLING_PLAN_PRICE_MAP"),
      Deno.env.get("STRIPE_ENVIRONMENT"),
    );
    if (!supabaseUrl || !anonKey || !serviceKey || !stripeKey || !appUrl) {
      throw new Error("Plan upgrade service is not fully configured.");
    }
    let payload: unknown;
    try {
      payload = await request.json();
    } catch {
      throw new RequestError("A licensed crew quantity is required.");
    }
    let targetCrewLimit: number;
    try {
      targetCrewLimit = normalizeCrewQuantity((payload as { target_crew_limit?: unknown })?.target_crew_limit);
    } catch (error) {
      throw new RequestError(error instanceof Error ? error.message : `Choose at least ${INCLUDED_CREWS} crews.`);
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    });
    const service = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });

    const { data: userData, error: userError } = await userClient.auth
      .getUser();
    if (userError || !userData.user) {
      throw new RequestError("Authentication required.", 401);
    }

    const accessToken = auth.replace(/^Bearer\s+/i, "").trim();
    const { data: claimsData, error: claimsError } = await userClient.auth
      .getClaims(accessToken);
    if (claimsError || claimsData?.claims?.aal !== "aal2") {
      throw new RequestError(
        "Complete multi-factor authentication before managing billing.",
        403,
      );
    }

    const { data: profile, error: profileError } = await service
      .from("profiles")
      .select("company_id,role,active")
      .eq("id", userData.user.id)
      .single();
    if (profileError || !profile || profile.active === false) {
      throw new RequestError("Active company profile required.", 403);
    }
    if (!["owner", "admin"].includes(String(profile.role).toLowerCase())) {
      throw new RequestError("Company Owner or Admin access required.", 403);
    }

    const { data: stored, error: storedError } = await service
      .from("company_subscriptions")
      .select(
        "provider,status,cancel_at_period_end,stripe_customer_id,stripe_subscription_id",
      )
      .eq("company_id", profile.company_id)
      .maybeSingle();
    if (storedError) throw storedError;
    if (
      stored?.provider !== "stripe" ||
      !/^cus_[A-Za-z0-9]+$/.test(String(stored?.stripe_customer_id || "")) ||
      !/^sub_[A-Za-z0-9]+$/.test(String(stored?.stripe_subscription_id || ""))
    ) {
      throw new RequestError(
        "This company does not have an active Stripe subscription to change.",
        409,
      );
    }
    if (stored.cancel_at_period_end) {
      throw new RequestError(
        "Resume the scheduled cancellation in Manage Billing before upgrading.",
        409,
      );
    }

    const subscription = await stripeGet(
      `/subscriptions/${encodeURIComponent(stored.stripe_subscription_id)}`,
      stripeKey,
    );
    if (subscription.customer !== stored.stripe_customer_id) {
      throw new RequestError(
        "Stripe subscription ownership did not match this company.",
        409,
      );
    }
    if (!["active", "trialing"].includes(String(subscription.status || ""))) {
      throw new RequestError(
        "Only an active or trialing subscription can be upgraded here.",
        409,
      );
    }
    if (subscription.cancel_at_period_end) {
      throw new RequestError(
        "Resume the scheduled cancellation in Manage Billing before upgrading.",
        409,
      );
    }

    const items = Array.isArray(subscription?.items?.data)
      ? subscription.items.data
      : [];
    if (items.length !== 1) {
      throw new RequestError(
        "This subscription needs LineCrew Pro support before its plan can be changed.",
        409,
      );
    }
    const item = items[0];
    if (!/^si_[A-Za-z0-9]+$/.test(String(item?.id || ""))) {
      throw new RequestError(
        "Stripe did not return a valid subscription item.",
        409,
      );
    }
    const currentPrice = String(item?.price?.id || "");
    if (currentPrice !== linecrewPrice) {
      throw new RequestError(
        "This legacy subscription must be migrated by LineCrew Pro support before changing crew capacity.",
        409,
      );
    }
    const currentCrewLimit = normalizeCrewQuantity(item?.quantity);
    if (targetCrewLimit === currentCrewLimit) throw new RequestError("Crew capacity is already set to that amount.", 409);

    const { count: activeCrews, error: activeCrewsError } = await service
      .from("crews").select("id", { count: "exact", head: true })
      .eq("company_id", profile.company_id).eq("active", true);
    if (activeCrewsError) throw activeCrewsError;
    if (targetCrewLimit < Number(activeCrews || 0)) {
      throw new RequestError(`Deactivate crews first. This company currently has ${activeCrews || 0} active crews.`, 409);
    }

    if (targetCrewLimit < currentCrewLimit) {
      const params = new URLSearchParams();
      params.set("quantity", String(targetCrewLimit));
      params.set("proration_behavior", "none");
      await stripePost(`/subscription_items/${encodeURIComponent(String(item.id))}`, params, stripeKey);
      return json({ updated: true, current_crew_limit: currentCrewLimit, target_crew_limit: targetCrewLimit });
    }

    const portalConfiguration = await resolveUpgradePortalConfiguration(
      configuredPortalId,
      stripeKey,
    );

    const returnUrl = `${appUrl}/billing.html?billing=portal-return`;
    const completedUrl =
      `${appUrl}/billing.html?billing=capacity-return&target_crews=${
        encodeURIComponent(String(targetCrewLimit))
      }`;
    const params = new URLSearchParams();
    params.set("customer", stored.stripe_customer_id);
    params.set("configuration", portalConfiguration);
    params.set("return_url", returnUrl);
    params.set("flow_data[type]", "subscription_update_confirm");
    params.set(
      "flow_data[subscription_update_confirm][subscription]",
      stored.stripe_subscription_id,
    );
    params.set(
      "flow_data[subscription_update_confirm][items][0][id]",
      String(item.id),
    );
    params.set(
      "flow_data[subscription_update_confirm][items][0][price]",
      linecrewPrice,
    );
    params.set(
      "flow_data[subscription_update_confirm][items][0][quantity]",
      String(targetCrewLimit),
    );
    params.set("flow_data[after_completion][type]", "redirect");
    params.set(
      "flow_data[after_completion][redirect][return_url]",
      completedUrl,
    );

    const session = await stripePost(
      "/billing_portal/sessions",
      params,
      stripeKey,
    );
    if (!session?.url) {
      throw new Error("Stripe did not return an upgrade confirmation URL.");
    }
    return json({
      url: session.url,
      current_crew_limit: currentCrewLimit,
      target_crew_limit: targetCrewLimit,
    });
  } catch (error) {
    console.error(error);
    const status = error instanceof RequestError ? error.status : 400;
    return json({
      error: error instanceof Error
        ? error.message
        : "Unable to change crew capacity.",
    }, status);
  }
});
