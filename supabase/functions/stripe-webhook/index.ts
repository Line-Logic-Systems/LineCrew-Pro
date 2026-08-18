import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "Content-Type": "application/json" },
});

function bytesToHex(bytes: Uint8Array) {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

async function verifyStripeSignature(rawBody: string, signature: string, secret: string) {
  const parts = signature.split(",").map(v => v.trim());
  const timestamp = parts.find(v => v.startsWith("t="))?.slice(2);
  const signatures = parts.filter(v => v.startsWith("v1=")).map(v => v.slice(3));
  if (!timestamp || !signatures.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${rawBody}`)));
  const expected = bytesToHex(digest);
  return signatures.some(v => timingSafeEqual(v, expected));
}

function mapStatus(status: string) {
  if (["active", "trialing", "past_due", "paused", "canceled", "incomplete"].includes(status)) return status;
  if (status === "unpaid") return "past_due";
  if (status === "incomplete_expired") return "canceled";
  return "incomplete";
}

function accessForStatus(status: string) {
  return ["active", "trialing", "past_due"].includes(status);
}

Deno.serve(async request => {
  if (request.method !== "POST") return json({ error: "POST required." }, 405);
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    if (!supabaseUrl || !serviceKey || !webhookSecret) throw new Error("Webhook service is not fully configured.");

    const rawBody = await request.text();
    const signature = request.headers.get("stripe-signature") || "";
    if (!await verifyStripeSignature(rawBody, signature, webhookSecret)) return json({ error: "Invalid Stripe signature." }, 400);

    const event = JSON.parse(rawBody);
    const service = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

    const { error: eventInsertError } = await service.from("billing_events").insert({
      provider: "stripe",
      provider_event_id: event.id,
      event_type: event.type,
      payload: event,
    });
    if (eventInsertError && !String(eventInsertError.message).toLowerCase().includes("duplicate")) throw eventInsertError;
    if (eventInsertError) return json({ received: true, duplicate: true });

    const object = event.data?.object || {};
    let companyId = object.metadata?.company_id || null;
    const customerId = typeof object.customer === "string" ? object.customer : object.customer?.id || null;

    if (!companyId && customerId) {
      const { data: existing } = await service.from("company_subscriptions").select("company_id").eq("stripe_customer_id", customerId).maybeSingle();
      companyId = existing?.company_id || null;
    }

    if (event.type === "checkout.session.completed") {
      companyId = object.metadata?.company_id || object.client_reference_id || companyId;
      if (companyId) {
        await service.from("company_subscriptions").upsert({
          company_id: companyId,
          provider: "stripe",
          stripe_customer_id: customerId,
          stripe_subscription_id: typeof object.subscription === "string" ? object.subscription : null,
          status: "active",
          access_enabled: true,
          updated_at: new Date().toISOString(),
        }, { onConflict: "company_id" });
      }
    }

    if (["customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"].includes(event.type)) {
      companyId = object.metadata?.company_id || companyId;
      if (companyId) {
        const stripeStatus = String(object.status || (event.type.endsWith("deleted") ? "canceled" : "incomplete"));
        const status = mapStatus(stripeStatus);
        const item = object.items?.data?.[0];
        await service.from("company_subscriptions").upsert({
          company_id: companyId,
          provider: "stripe",
          stripe_customer_id: customerId,
          stripe_subscription_id: object.id,
          stripe_price_id: item?.price?.id || null,
          monthly_price_cents: Number(item?.price?.unit_amount || 0),
          currency: String(item?.price?.currency || "usd"),
          status,
          access_enabled: accessForStatus(status),
          current_period_start: object.current_period_start ? new Date(object.current_period_start * 1000).toISOString() : null,
          current_period_end: object.current_period_end ? new Date(object.current_period_end * 1000).toISOString() : null,
          trial_ends_at: object.trial_end ? new Date(object.trial_end * 1000).toISOString() : null,
          cancel_at_period_end: object.cancel_at_period_end === true,
          updated_at: new Date().toISOString(),
        }, { onConflict: "company_id" });
      }
    }

    if (["invoice.payment_failed", "invoice.paid"].includes(event.type) && companyId) {
      const changes = event.type === "invoice.payment_failed"
        ? { status: "past_due", access_enabled: true, updated_at: new Date().toISOString() }
        : { status: "active", access_enabled: true, updated_at: new Date().toISOString() };
      await service.from("company_subscriptions").update(changes).eq("company_id", companyId);
    }

    await service.from("billing_events").update({ company_id: companyId, processed_at: new Date().toISOString() }).eq("provider_event_id", event.id);
    return json({ received: true });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Webhook processing failed." }, 400);
  }
});
