import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";

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

  const numericTimestamp = Number(timestamp);
  if (!Number.isFinite(numericTimestamp)) return false;
  if (Math.abs(Date.now() / 1000 - numericTimestamp) > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${rawBody}`)),
  );
  const expected = bytesToHex(digest);
  return signatures.some(v => timingSafeEqual(v, expected));
}

function mapStatus(status: string) {
  if (["active", "trialing", "past_due", "paused", "canceled", "incomplete"].includes(status)) return status;
  if (status === "unpaid") return "past_due";
  if (status === "incomplete_expired") return "canceled";
  return "incomplete";
}

// Base billing access deliberately includes past_due and incomplete while the
// product is in pilot. A separate nullable owner override can always force
// allow/block and is never overwritten by Stripe webhooks.
function accessForStatus(status: string) {
  return ["active", "trialing", "past_due", "incomplete"].includes(status);
}

function normalizedMonthlyAmount(unitAmount: number, interval: string | null, intervalCount: number | null) {
  const amount = Number.isFinite(unitAmount) ? Math.max(0, unitAmount) : 0;
  const count = Math.max(1, Number(intervalCount) || 1);
  if (interval === "year") return Math.round(amount / (12 * count));
  if (interval === "month") return Math.round(amount / count);
  if (interval === "week") return Math.round((amount * 52) / (12 * count));
  if (interval === "day") return Math.round((amount * 365) / (12 * count));
  return amount;
}

function planForStripePrice(priceId: string | null, rawMap: string | undefined) {
  if (!priceId) throw new Error("Stripe subscription price is missing.");
  if (!rawMap) throw new Error("Billing plan mapping is not configured.");

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawMap);
  } catch {
    throw new Error("Billing plan mapping is invalid JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Billing plan mapping must be an object.");
  }

  for (const [plan, configuredPriceId] of Object.entries(parsed as Record<string, unknown>)) {
    if (String(configuredPriceId || "").trim() === priceId) {
      const cleanPlan = String(plan || "").trim().toLowerCase();
      if (["starter", "business", "pro", "enterprise"].includes(cleanPlan)) return cleanPlan;
    }
  }
  throw new Error(`Stripe price ${priceId} is not mapped to a LineCrew Pro plan.`);
}

Deno.serve(async request => {
  if (request.method !== "POST") return json({ error: "POST required." }, 405);

  // No generated Database type is checked into this repository yet. Keeping
  // this one catch-scope handle untyped avoids falsely narrowing every table
  // mutation to `never` while Deno still type-checks all surrounding logic.
  let service: any = null;
  let eventId: string | null = null;

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    if (!supabaseUrl || !serviceKey || !webhookSecret) {
      throw new Error("Webhook service is not fully configured.");
    }

    const rawBody = await request.text();
    const signature = request.headers.get("stripe-signature") || "";
    if (!await verifyStripeSignature(rawBody, signature, webhookSecret)) {
      return json({ error: "Invalid Stripe signature." }, 400);
    }

    const event = JSON.parse(rawBody);
    eventId = String(event?.id || "").trim() || null;
    if (!eventId) throw new Error("Stripe event ID is missing.");

    service = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

    const { error: eventInsertError } = await service.from("billing_events").insert({
      provider: "stripe",
      provider_event_id: eventId,
      event_type: String(event.type || "unknown"),
      payload: event,
    });

    if (eventInsertError) {
      if (eventInsertError.code !== "23505") throw eventInsertError;
      const { data: prior, error: priorError } = await service
        .from("billing_events")
        .select("processed_at")
        .eq("provider_event_id", eventId)
        .single();
      if (priorError) throw priorError;
      if (prior?.processed_at) return json({ received: true, duplicate: true });
      // A previous attempt inserted the event but failed before completing it.
      // Continue processing so Stripe retries can recover safely.
    }

    const object = event.data?.object || {};
    let companyId = object.metadata?.company_id || null;
    const customerId = typeof object.customer === "string"
      ? object.customer
      : object.customer?.id || null;

    if (!companyId && customerId) {
      const { data: existing, error: existingError } = await service
        .from("company_subscriptions")
        .select("company_id")
        .eq("stripe_customer_id", customerId)
        .maybeSingle();
      if (existingError) throw existingError;
      companyId = existing?.company_id || null;
    }

    if (event.type === "checkout.session.completed") {
      companyId = object.metadata?.company_id || object.client_reference_id || companyId;
      const planCode = String(object.metadata?.plan_code || "").trim() || null;
      if (companyId) {
        const { data: existing, error: lookupError } = await service
          .from("company_subscriptions")
          .select("id")
          .eq("company_id", companyId)
          .maybeSingle();
        if (lookupError) throw lookupError;

        const subscriptionId = typeof object.subscription === "string"
          ? object.subscription
          : object.subscription?.id || null;
        const link = {
          provider: "stripe",
          stripe_customer_id: customerId,
          stripe_subscription_id: subscriptionId,
          ...(planCode ? { plan_code: planCode } : {}),
          updated_at: new Date().toISOString(),
        };

        if (existing) {
          const { error } = await service
            .from("company_subscriptions")
            .update(link)
            .eq("company_id", companyId);
          if (error) throw error;
        } else {
          const { error } = await service.from("company_subscriptions").insert({
            company_id: companyId,
            ...link,
            status: "incomplete",
            access_enabled: true,
          });
          if (error) throw error;
        }
      }
    }

    if (["customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"].includes(event.type)) {
      companyId = object.metadata?.company_id || companyId;
      if (companyId) {
        const stripeStatus = String(
          object.status || (event.type.endsWith("deleted") ? "canceled" : "incomplete"),
        );
        const status = mapStatus(stripeStatus);
        const item = object.items?.data?.[0];
        const interval = item?.price?.recurring?.interval || null;
        const intervalCount = Number(item?.price?.recurring?.interval_count || 1);
        const unitAmount = Number(item?.price?.unit_amount || 0);
        const stripePriceId = String(item?.price?.id || "").trim() || null;
        // The Customer Portal changes the subscription price but does not
        // rewrite subscription metadata. Resolve the plan from the current
        // Stripe Price ID so an upgrade/downgrade cannot leave LineCrew Pro on
        // a stale crew limit.
        const planCode = planForStripePrice(
          stripePriceId,
          Deno.env.get("BILLING_PLAN_PRICE_MAP"),
        );
        const currentPeriodEndUnix = Number(object.current_period_end || item?.current_period_end || 0);
        const scheduledCancelUnix = Number(object.cancel_at || 0);
        // Stripe's newer Customer Portal can schedule an end-of-period
        // cancellation with cancel_at=<resolved period end> while leaving the
        // legacy cancel_at_period_end flag false. Treat both representations
        // as the same LineCrew Pro state.
        const cancelsAtPeriodEnd = object.cancel_at_period_end === true || (
          Number.isFinite(scheduledCancelUnix) &&
          scheduledCancelUnix > 0 &&
          Number.isFinite(currentPeriodEndUnix) &&
          currentPeriodEndUnix > 0 &&
          scheduledCancelUnix === currentPeriodEndUnix
        );

        const { data: prior, error: priorError } = await service
          .from("company_subscriptions")
          .select("past_due_since,plan_code")
          .eq("company_id", companyId)
          .maybeSingle();
        if (priorError) throw priorError;

        const pastDueSince = status === "past_due"
          ? (prior?.past_due_since || new Date().toISOString())
          : null;

        const update = {
          company_id: companyId,
          provider: "stripe",
          plan_code: planCode,
          stripe_customer_id: customerId,
          stripe_subscription_id: object.id,
          stripe_price_id: stripePriceId,
          monthly_price_cents: normalizedMonthlyAmount(unitAmount, interval, intervalCount),
          currency: String(item?.price?.currency || "usd").toLowerCase(),
          billing_interval: interval,
          billing_interval_count: interval ? intervalCount : null,
          status,
          access_enabled: accessForStatus(status),
          past_due_since: pastDueSince,
          current_period_start: object.current_period_start
            ? new Date(object.current_period_start * 1000).toISOString()
            : item?.current_period_start
              ? new Date(item.current_period_start * 1000).toISOString()
              : null,
          current_period_end: currentPeriodEndUnix
            ? new Date(currentPeriodEndUnix * 1000).toISOString()
            : null,
          trial_ends_at: object.trial_end ? new Date(object.trial_end * 1000).toISOString() : null,
          cancel_at_period_end: cancelsAtPeriodEnd,
          updated_at: new Date().toISOString(),
        };

        const { error } = await service
          .from("company_subscriptions")
          .upsert(update, { onConflict: "company_id" });
        if (error) throw error;

        const { error: crewLimitError } = await service.rpc("recalculate_company_crew_overage", {
          p_company_id: companyId,
        });
        if (crewLimitError) throw crewLimitError;
      }
    }

    if (event.type === "invoice.payment_failed" && companyId) {
      const { data: prior, error: priorError } = await service
        .from("company_subscriptions")
        .select("past_due_since")
        .eq("company_id", companyId)
        .maybeSingle();
      if (priorError) throw priorError;
      const { error } = await service
        .from("company_subscriptions")
        .update({
          status: "past_due",
          access_enabled: true,
          past_due_since: prior?.past_due_since || new Date().toISOString(),
          updated_at: new Date().toISOString(),
        })
        .eq("company_id", companyId);
      if (error) throw error;
    }

    // invoice.paid is intentionally audit-only. Subscription.updated remains
    // the source of truth so a final paid invoice cannot reactivate a canceled
    // subscription or overwrite a trial/paused state.

    const { error: completeError } = await service
      .from("billing_events")
      .update({
        company_id: companyId,
        processed_at: new Date().toISOString(),
        error_text: null,
      })
      .eq("provider_event_id", eventId);
    if (completeError) throw completeError;

    return json({ received: true });
  } catch (error) {
    console.error(error);
    if (service && eventId) {
      try {
        await service
          .from("billing_events")
          .update({
            error_text: (error instanceof Error ? error.message : "Webhook processing failed.").slice(0, 2000),
          })
          .eq("provider_event_id", eventId);
      } catch {
        // Preserve the original processing error for Stripe's retry response.
      }
    }
    return json({ error: error instanceof Error ? error.message : "Webhook processing failed." }, 500);
  }
});
