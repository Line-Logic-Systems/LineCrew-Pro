import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

Deno.serve(async request => {
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
    if (!supabaseUrl || !anonKey || !serviceKey || !stripeKey || !appUrl) {
      throw new Error("Billing portal is not fully configured.");
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    });
    const service = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

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

    const { data: subscription, error: subscriptionError } = await service
      .from("company_subscriptions")
      .select("stripe_customer_id")
      .eq("company_id", profile.company_id)
      .maybeSingle();
    if (subscriptionError) throw subscriptionError;
    if (!subscription?.stripe_customer_id) {
      throw new Error("This company does not have a Stripe billing account yet.");
    }

    const params = new URLSearchParams();
    params.set("customer", subscription.stripe_customer_id);
    params.set("return_url", `${appUrl}/billing.html?billing=portal-return`);
    const response = await fetch("https://api.stripe.com/v1/billing_portal/sessions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data?.error?.message || "Unable to open billing portal.");
    if (!data?.url) throw new Error("Stripe did not return a Customer Portal URL.");
    return json({ url: data.url });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Unable to open billing portal." }, 400);
  }
});
