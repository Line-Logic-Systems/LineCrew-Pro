import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";
import { getSecretKey } from "../_shared/api-keys.ts";
import { clampCrewQuantity, linecrewMonthlyCents, withLinecrewPrice } from "../_shared/billing-pricing.ts";
import {
  accessForStatus,
  assertEventEnvironment,
  eventCreatedSeconds,
  expectedLivemode,
  isStaleEvent,
  mapStatus,
  normalizedMonthlyAmount,
  planForSubscriptionEvent,
  resolveCompanyId,
} from "./logic.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function bytesToHex(bytes: Uint8Array) {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

async function verifyStripeSignature(
  rawBody: string,
  signature: string,
  secret: string,
) {
  const parts = signature.split(",").map((v) => v.trim());
  const timestamp = parts.find((v) => v.startsWith("t="))?.slice(2);
  const signatures = parts.filter((v) => v.startsWith("v1=")).map((v) =>
    v.slice(3)
  );
  if (!timestamp || !signatures.length) return false;
  const numericTimestamp = Number(timestamp);
  if (
    !Number.isFinite(numericTimestamp) ||
    Math.abs(Date.now() / 1000 - numericTimestamp) > 300
  ) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(`${timestamp}.${rawBody}`),
    ),
  );
  const expected = bytesToHex(digest);
  return signatures.some((value) => timingSafeEqual(value, expected));
}

function stripeId(value: unknown, prefix: string) {
  const id = typeof value === "string"
    ? value
    : (value as { id?: unknown } | null)?.id;
  const clean = String(id || "").trim();
  return clean.startsWith(prefix) ? clean : null;
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
  if (!response.ok) {
    throw new Error(data?.error?.message || "Stripe request failed.");
  }
  return data;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "POST required." }, 405);
  let service: any = null;
  let eventId: string | null = null;
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = getSecretKey();
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!supabaseUrl || !serviceKey || !webhookSecret || !stripeKey) {
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
    const eventCreated = eventCreatedSeconds(event.created);
    assertEventEnvironment(
      event.livemode,
      expectedLivemode(
        Deno.env.get("STRIPE_ENVIRONMENT"),
        stripeKey,
      ),
    );

    service = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });
    const { error: eventInsertError } = await service.from("billing_events")
      .insert({
        provider: "stripe",
        provider_event_id: eventId,
        event_type: String(event.type || "unknown"),
        payload: event,
      });
    if (eventInsertError) {
      if (eventInsertError.code !== "23505") throw eventInsertError;
      const { data: priorEvent, error: priorEventError } = await service.from(
        "billing_events",
      ).select("processed_at").eq("provider_event_id", eventId).single();
      if (priorEventError) throw priorEventError;
      if (priorEvent?.processed_at) {
        return json({ received: true, duplicate: true });
      }
    }

    const object = event.data?.object || {};
    const customerId = stripeId(object.customer, "cus_");
    let customerOwnerCompanyId: string | null = null;
    if (customerId) {
      const { data: owner, error: ownerError } = await service.from(
        "company_subscriptions",
      ).select("company_id").eq("stripe_customer_id", customerId).maybeSingle();
      if (ownerError) throw ownerError;
      customerOwnerCompanyId = owner?.company_id || null;
    }
    let companyId = resolveCompanyId({
      metadataCompanyId: object.metadata?.company_id,
      clientReferenceId: event.type === "checkout.session.completed"
        ? object.client_reference_id
        : null,
      customerOwnerCompanyId,
    });

    if (event.type === "checkout.session.completed") {
      if (!companyId) {
        throw new Error("Checkout completion is missing a company identity.");
      }
      const { data: company, error: companyError } = await service.from(
        "companies",
      ).select("id").eq("id", companyId).maybeSingle();
      if (companyError) throw companyError;
      if (!company) throw new Error("Checkout company does not exist.");
      const subscriptionId = stripeId(object.subscription, "sub_");
      if (!customerId || !subscriptionId) {
        throw new Error("Checkout Stripe identity is invalid.");
      }
      const { data: prior, error: priorError } = await service.from(
        "company_subscriptions",
      ).select("id,stripe_customer_id,stripe_subscription_id").eq(
        "company_id",
        companyId,
      ).maybeSingle();
      if (priorError) throw priorError;
      if (
        prior?.stripe_customer_id && prior.stripe_customer_id !== customerId
      ) {
        throw new Error(
          "Checkout customer does not own this company subscription.",
        );
      }
      // Checkout completion only links Stripe identities when it cannot replace a
      // different subscription. A delayed completion for an older Checkout
      // must never roll the company back from a newer Stripe subscription.
      const link = {
        provider: "stripe",
        stripe_customer_id: customerId,
        stripe_subscription_id: subscriptionId,
        updated_at: new Date().toISOString(),
      };
      if (
        prior?.stripe_subscription_id &&
        prior.stripe_subscription_id !== subscriptionId
      ) {
        console.warn(
          "Ignoring superseded Checkout subscription link",
          prior.stripe_subscription_id,
          subscriptionId,
        );
      } else if (prior) {
        const { error } = await service.from("company_subscriptions").update(
          link,
        ).eq("company_id", companyId);
        if (error) throw error;
      } else {
        const { error } = await service.from("company_subscriptions").insert({
          company_id: companyId,
          ...link,
          status: "incomplete",
          access_enabled: false,
        });
        if (error) throw error;
      }
    }

    const subscriptionEvent = [
      "customer.subscription.created",
      "customer.subscription.updated",
      "customer.subscription.deleted",
    ].includes(event.type);
    if (subscriptionEvent) {
      const subscriptionId = stripeId(object.id, "sub_");
      if (!subscriptionId) {
        throw new Error("Stripe subscription identity is invalid.");
      }

      // Stripe does not guarantee webhook delivery order, and Event.created has
      // only one-second precision. Read the current canonical Subscription so
      // two events created in the same second cannot roll plan/status backward.
      let subscription = await stripeGet(
        `/subscriptions/${encodeURIComponent(subscriptionId)}`,
        stripeKey,
      );
      if (
        String(subscription.status || "") !== "canceled" &&
        subscription.payment_settings?.save_default_payment_method !== "on_subscription"
      ) {
        // Promoting the settling card to the subscription default is a
        // convenience. Syncing status and access is the money path, so a
        // Stripe failure here must never abort the write below and leave a
        // paying company stranded at incomplete/no-access.
        try {
          const paymentSettings = new URLSearchParams();
          paymentSettings.set("payment_settings[save_default_payment_method]", "on_subscription");
          subscription = await stripePost(
            `/subscriptions/${encodeURIComponent(subscriptionId)}`,
            paymentSettings,
            stripeKey,
          );
        } catch (paymentSettingsError) {
          console.warn(
            "Could not set save_default_payment_method on",
            subscriptionId,
            paymentSettingsError instanceof Error
              ? paymentSettingsError.message
              : paymentSettingsError,
          );
        }
      }
      const canonicalCustomerId = stripeId(subscription.customer, "cus_");
      if (!canonicalCustomerId) {
        throw new Error("Stripe subscription customer identity is invalid.");
      }
      if (customerId && canonicalCustomerId !== customerId) {
        throw new Error(
          "Webhook subscription customer changed between event and retrieval.",
        );
      }
      const canonicalCompanyId = resolveCompanyId({
        metadataCompanyId: subscription.metadata?.company_id,
        customerOwnerCompanyId,
      });
      if (companyId && canonicalCompanyId && companyId !== canonicalCompanyId) {
        throw new Error(
          "Canonical Stripe subscription company does not match the event.",
        );
      }
      companyId = canonicalCompanyId || companyId;
      if (!companyId) {
        throw new Error(
          "Stripe subscription is not linked to a LineCrew Pro company.",
        );
      }

      const { data: prior, error: priorError } = await service.from(
        "company_subscriptions",
      )
        .select(
          "company_id,plan_code,status,past_due_since,stripe_customer_id,stripe_subscription_id,last_stripe_event_created,included_crew_limit",
        )
        .eq("company_id", companyId).maybeSingle();
      if (priorError) throw priorError;
      if (
        prior?.stripe_customer_id &&
        prior.stripe_customer_id !== canonicalCustomerId
      ) throw new Error("Stripe customer ownership changed unexpectedly.");

      const differentStoredSubscription = Boolean(
        prior?.stripe_subscription_id &&
          prior.stripe_subscription_id !== subscriptionId,
      );
      const canReplaceCanceledSubscription = differentStoredSubscription &&
        String(prior?.status || "").toLowerCase() === "canceled";

      if (differentStoredSubscription && !canReplaceCanceledSubscription) {
        // This signed event belongs to an older or duplicate subscription for
        // the same customer. Keep it in the audit ledger without replacing the
        // company's current subscription link or billing state.
        console.warn(
          "Ignoring superseded Stripe subscription event",
          prior?.stripe_subscription_id,
          subscriptionId,
        );
      } else if (
        !isStaleEvent(eventCreated, prior?.last_stripe_event_created)
      ) {
        const deleted = String(subscription.status || "") === "canceled";
        const items = Array.isArray(subscription.items?.data) ? subscription.items.data : [];
        if (!deleted && items.length !== 1) {
          throw new Error("LineCrew Pro subscriptions must contain exactly one billing item.");
        }
        const item = subscription.items?.data?.[0];
        const priceId = stripeId(item?.price, "price_");
        const planCode = planForSubscriptionEvent(
          deleted
            ? "customer.subscription.deleted"
            : "customer.subscription.updated",
          priceId,
          withLinecrewPrice(
            Deno.env.get("BILLING_PLAN_PRICE_MAP"),
            Deno.env.get("STRIPE_ENVIRONMENT"),
          ),
          prior?.plan_code,
        );
        const status = mapStatus(
          String(subscription.status || (deleted ? "canceled" : "incomplete")),
        );
        const licensedCrews = deleted
          ? clampCrewQuantity(prior?.included_crew_limit)
          : clampCrewQuantity(item?.quantity);
        if (!deleted && Number(item?.quantity) !== licensedCrews) {
          console.warn(
            "Stripe subscription quantity is outside the licensed crew range",
            subscriptionId,
            item?.quantity,
          );
        }
        const currentPeriodEndUnix = Number(
          subscription.current_period_end || item?.current_period_end || 0,
        );
        const scheduledCancelUnix = Number(subscription.cancel_at || 0);
        const cancelsAtPeriodEnd = !deleted &&
          (subscription.cancel_at_period_end === true ||
            (scheduledCancelUnix > 0 && currentPeriodEndUnix > 0 &&
              scheduledCancelUnix === currentPeriodEndUnix));
        const common = {
          company_id: companyId,
          provider: "stripe",
          plan_code: planCode,
          stripe_customer_id: canonicalCustomerId,
          stripe_subscription_id: subscriptionId,
          status,
          access_enabled: accessForStatus(status),
          past_due_since: status === "past_due"
            ? (prior?.past_due_since || new Date().toISOString())
            : null,
          current_period_start: subscription.current_period_start
            ? new Date(subscription.current_period_start * 1000).toISOString()
            : item?.current_period_start
            ? new Date(item.current_period_start * 1000).toISOString()
            : null,
          current_period_end: currentPeriodEndUnix
            ? new Date(currentPeriodEndUnix * 1000).toISOString()
            : null,
          trial_ends_at: subscription.trial_end
            ? new Date(subscription.trial_end * 1000).toISOString()
            : null,
          cancel_at_period_end: cancelsAtPeriodEnd,
          last_stripe_event_created: eventCreated,
          updated_at: new Date().toISOString(),
          ...(!deleted
            ? {
              stripe_price_id: priceId,
              monthly_price_cents: planCode === "linecrew"
                ? linecrewMonthlyCents(licensedCrews)
                : normalizedMonthlyAmount(
                  Number(item?.price?.unit_amount || 0),
                  item?.price?.recurring?.interval || null,
                  Number(item?.price?.recurring?.interval_count || 1),
                ),
              included_crew_limit: planCode === "linecrew"
                ? licensedCrews
                : prior?.included_crew_limit,
              currency: String(item?.price?.currency || "usd").toLowerCase(),
              billing_interval: item?.price?.recurring?.interval || null,
              billing_interval_count: item?.price?.recurring?.interval
                ? Number(item?.price?.recurring?.interval_count || 1)
                : null,
            }
            : {}),
        };
        let applied = false;
        if (prior) {
          const { data: updated, error } = await service.from(
            "company_subscriptions",
          ).update(common)
            .eq("company_id", companyId).lte(
              "last_stripe_event_created",
              eventCreated,
            ).select("company_id").maybeSingle();
          if (error) throw error;
          applied = Boolean(updated);
        } else {
          const { error } = await service.from("company_subscriptions").insert(
            common,
          );
          if (error) throw error;
          applied = true;
        }
        if (applied) {
          // companies.subscription_status is retained for UI/backward
          // compatibility only. company_subscriptions is the access source of
          // truth enforced by the database pre-request hook.
          const projectedCompanyStatus = status === "active"
            ? "active"
            : status === "trialing"
            ? "trial"
            : status === "past_due"
            ? "active"
            : "suspended";
          const { error: projectionError } = await service.from("companies")
            .update({
              subscription_status: projectedCompanyStatus,
              subscription_expires_at: status === "trialing"
                ? common.trial_ends_at
                : null,
            })
            .eq("id", companyId);
          if (projectionError) throw projectionError;

          const { error: crewLimitError } = await service.rpc(
            "recalculate_company_crew_overage",
            { p_company_id: companyId },
          );
          if (crewLimitError) throw crewLimitError;
        }
      }
    }

    // Invoice events are audit-only. The latest canonical Subscription fetched
    // for customer.subscription events is the only source of plan/status/access
    // truth, so an out-of-order invoice cannot reactivate or mark an account due.

    // invoice.paid is intentionally audit-only. Subscription events remain the
    // source of truth so a final invoice cannot reactivate a canceled account.
    const { error: completeError } = await service.from("billing_events")
      .update({
        company_id: companyId,
        processed_at: new Date().toISOString(),
        error_text: null,
      }).eq("provider_event_id", eventId);
    if (completeError) throw completeError;
    return json({ received: true });
  } catch (error) {
    console.error(error);
    if (service && eventId) {
      try {
        await service.from("billing_events").update({
          error_text: (error instanceof Error
            ? error.message
            : "Webhook processing failed.").slice(0, 2000),
        }).eq("provider_event_id", eventId);
      } catch { /* preserve the original processing error */ }
    }
    return json({
      error: error instanceof Error
        ? error.message
        : "Webhook processing failed.",
    }, 500);
  }
});
