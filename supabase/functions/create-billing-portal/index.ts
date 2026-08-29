import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";
import { getPublishableKey, getSecretKey } from "../_shared/api-keys.ts";

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

const managePortalPurpose = "linecrew_manage_only_v1";

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

function portalConfigurationIsManageOnly(
  configuration: Record<string, unknown>,
) {
  const features = configuration.features as
    | Record<string, unknown>
    | undefined;
  const update = features?.subscription_update as
    | Record<string, unknown>
    | undefined;
  return configuration.active === true && update?.enabled !== true;
}

async function resolveManagePortalConfiguration(
  configuredId: string | undefined,
  stripeKey: string,
) {
  if (configuredId) {
    if (!/^bpc_[A-Za-z0-9]+$/.test(configuredId)) {
      throw new Error(
        "The configured Stripe manage Portal configuration ID is invalid.",
      );
    }
    const configured = await stripeGet(
      `/billing_portal/configurations/${encodeURIComponent(configuredId)}`,
      stripeKey,
    );
    if (!portalConfigurationIsManageOnly(configured)) {
      throw new Error(
        "The configured Stripe manage Portal must disable subscription plan changes.",
      );
    }
    return configuredId;
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
      return metadata?.linecrew_purpose === managePortalPurpose;
    },
  );
  if (matches.length !== 1) {
    throw new Error(
      "Exactly one active Stripe manage-only Portal configuration must be provisioned.",
    );
  }
  const match = matches[0] as Record<string, unknown>;
  if (!portalConfigurationIsManageOnly(match)) {
    throw new Error(
      "The discovered Stripe manage Portal must disable subscription plan changes.",
    );
  }
  const id = String(match.id || "");
  if (!/^bpc_[A-Za-z0-9]+$/.test(id)) {
    throw new Error(
      "Stripe returned an invalid manage Portal configuration ID.",
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
    if (!auth) throw new Error("Authentication required.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = getPublishableKey();
    const serviceKey = getSecretKey();
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    const configuredPortalId = Deno.env.get(
      "STRIPE_MANAGE_PORTAL_CONFIGURATION_ID",
    );
    const appUrl = (Deno.env.get("APP_URL") || "").replace(/\/$/, "");
    if (!supabaseUrl || !anonKey || !serviceKey || !stripeKey || !appUrl) {
      throw new Error("Billing portal is not fully configured.");
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
      throw new Error("Authentication required.");
    }

    const accessToken = auth.replace(/^Bearer\s+/i, "").trim();
    const { data: claimsData, error: claimsError } = await userClient.auth
      .getClaims(accessToken);
    if (claimsError || claimsData?.claims?.aal !== "aal2") {
      return json({
        error: "Complete multi-factor authentication before managing billing.",
      }, 403);
    }

    const { data: profile, error: profileError } = await service
      .from("profiles")
      .select("company_id,role,active")
      .eq("id", userData.user.id)
      .single();
    if (profileError || !profile || profile.active === false) {
      throw new Error("Active company profile required.");
    }
    if (!["owner", "admin"].includes(String(profile.role).toLowerCase())) {
      return json({ error: "Company Owner or Admin access required." }, 403);
    }

    const { data: subscription, error: subscriptionError } = await service
      .from("company_subscriptions")
      .select("stripe_customer_id")
      .eq("company_id", profile.company_id)
      .maybeSingle();
    if (subscriptionError) throw subscriptionError;
    if (!subscription?.stripe_customer_id) {
      throw new Error(
        "This company does not have a Stripe billing account yet.",
      );
    }

    const portalConfiguration = await resolveManagePortalConfiguration(
      configuredPortalId,
      stripeKey,
    );

    const params = new URLSearchParams();
    params.set("customer", subscription.stripe_customer_id);
    params.set("configuration", portalConfiguration);
    params.set("return_url", `${appUrl}/billing.html?billing=portal-return`);
    const response = await fetch(
      "https://api.stripe.com/v1/billing_portal/sessions",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${stripeKey}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: params,
      },
    );
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data?.error?.message || "Unable to open billing portal.");
    }
    if (!data?.url) {
      throw new Error("Stripe did not return a Customer Portal URL.");
    }
    return json({ url: data.url });
  } catch (error) {
    console.error(error);
    return json({
      error: error instanceof Error
        ? error.message
        : "Unable to open billing portal.",
    }, 400);
  }
});
