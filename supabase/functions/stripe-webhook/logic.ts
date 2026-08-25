export const planOrder = ["starter", "business", "pro", "enterprise"] as const;
export type PlanCode = typeof planOrder[number];

export function knownPlanCode(value: unknown): PlanCode | null {
  const clean = String(value || "").trim().toLowerCase();
  return planOrder.includes(clean as PlanCode) ? clean as PlanCode : null;
}

export function readPlanPriceMap(raw: string | undefined) {
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
  return parsed as Record<string, unknown>;
}

export function planForStripePrice(
  priceId: string | null,
  rawMap: string | undefined,
) {
  if (!priceId) throw new Error("Stripe subscription price is missing.");
  const parsed = readPlanPriceMap(rawMap);
  for (const [plan, configuredPriceId] of Object.entries(parsed)) {
    if (String(configuredPriceId || "").trim() === priceId) {
      const known = knownPlanCode(plan);
      if (known) return known;
    }
  }
  throw new Error(
    `Stripe price ${priceId} is not mapped to a LineCrew Pro plan.`,
  );
}

export function mapStatus(status: string) {
  if (
    ["active", "trialing", "past_due", "paused", "canceled", "incomplete"]
      .includes(status)
  ) return status;
  if (status === "unpaid") return "paused";
  if (status === "incomplete_expired") return "canceled";
  return "incomplete";
}

export function accessForStatus(status: string) {
  return ["active", "trialing", "past_due"].includes(status);
}

export function normalizedMonthlyAmount(
  unitAmount: number,
  interval: string | null,
  intervalCount: number | null,
) {
  const amount = Number.isFinite(unitAmount) ? Math.max(0, unitAmount) : 0;
  const count = Math.max(1, Number(intervalCount) || 1);
  if (interval === "year") return Math.round(amount / (12 * count));
  if (interval === "month") return Math.round(amount / count);
  if (interval === "week") return Math.round((amount * 52) / (12 * count));
  if (interval === "day") return Math.round((amount * 365) / (12 * count));
  return amount;
}

export function resolveCompanyId(input: {
  metadataCompanyId?: unknown;
  clientReferenceId?: unknown;
  customerOwnerCompanyId?: unknown;
}) {
  const metadata = String(input.metadataCompanyId || "").trim() || null;
  const clientReference = String(input.clientReferenceId || "").trim() || null;
  const customerOwner = String(input.customerOwnerCompanyId || "").trim() ||
    null;
  if (metadata && clientReference && metadata !== clientReference) {
    throw new Error(
      "Stripe company metadata does not match the Checkout client reference.",
    );
  }
  const declared = metadata || clientReference;
  if (customerOwner && declared && customerOwner !== declared) {
    throw new Error(
      "Stripe customer ownership does not match the declared company.",
    );
  }
  return customerOwner || declared;
}

export function eventCreatedSeconds(value: unknown) {
  const created = Number(value);
  if (!Number.isSafeInteger(created) || created <= 0) {
    throw new Error("Stripe event creation time is missing or invalid.");
  }
  return created;
}

export function isStaleEvent(created: number, lastCreated: unknown) {
  const prior = Number(lastCreated || 0);
  return Number.isFinite(prior) && created < prior;
}

export function expectedLivemode(
  environment: string | undefined,
  stripeSecretKey: string | undefined,
) {
  const configured = String(environment || "").trim().toLowerCase();
  if (configured === "live") return true;
  if (configured === "test") return false;
  if (configured) {
    throw new Error("STRIPE_ENVIRONMENT must be either test or live.");
  }
  if (stripeSecretKey?.startsWith("sk_live_")) return true;
  if (stripeSecretKey?.startsWith("sk_test_")) return false;
  throw new Error(
    "Set STRIPE_ENVIRONMENT or provide a recognizable Stripe secret key.",
  );
}

export function assertEventEnvironment(livemode: unknown, expected: boolean) {
  if (typeof livemode !== "boolean") {
    throw new Error("Stripe event livemode is missing.");
  }
  if (livemode !== expected) {
    throw new Error("Stripe event environment does not match this deployment.");
  }
}

export function planForSubscriptionEvent(
  eventType: string,
  priceId: string | null,
  rawMap: string | undefined,
  priorPlan: unknown,
) {
  if (eventType === "customer.subscription.deleted") {
    const prior = knownPlanCode(priorPlan);
    if (!prior) {
      throw new Error("Canceled subscription has no known LineCrew Pro plan.");
    }
    return prior;
  }
  return planForStripePrice(priceId, rawMap);
}
