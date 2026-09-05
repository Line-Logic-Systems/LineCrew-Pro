export const LINECREW_PLAN_CODE = "linecrew";
export const INCLUDED_CREWS = 5;
export const BASE_MONTHLY_CENTS = 59_900;
export const ADDITIONAL_CREW_MONTHLY_CENTS = 8_500;
export const LINECREW_TEST_PRICE_ID = "price_1UC8SPRTTF4i3BoKTZbciysW";
export const LINECREW_LIVE_PRICE_ID = "price_1UC8UmIjgPYpBqtY7XbXw47q";

export function normalizeCrewQuantity(value: unknown, fallback = INCLUDED_CREWS) {
  const quantity = Number(value ?? fallback);
  if (!Number.isSafeInteger(quantity) || quantity < INCLUDED_CREWS || quantity > 10_000) {
    throw new Error(`Licensed crew quantity must be a whole number of at least ${INCLUDED_CREWS}.`);
  }
  return quantity;
}

// Checkout and the crew-capacity change both reject an out-of-range quantity
// before Stripe ever sees it. The webhook is different: it reports what Stripe
// already believes, so a quantity edited by hand in the Stripe Dashboard must
// still be recordable. Clamping keeps status and access syncing for that
// company instead of wedging every later event behind a throw.
export function clampCrewQuantity(value: unknown, fallback = INCLUDED_CREWS) {
  const quantity = Math.trunc(Number(value));
  if (!Number.isFinite(quantity)) return fallback;
  return Math.min(10_000, Math.max(INCLUDED_CREWS, quantity));
}

export function linecrewMonthlyCents(quantity: unknown) {
  const crews = normalizeCrewQuantity(quantity);
  return BASE_MONTHLY_CENTS + Math.max(0, crews - INCLUDED_CREWS) * ADDITIONAL_CREW_MONTHLY_CENTS;
}

export function readLinecrewPriceId(rawMap: string | undefined, environment?: string) {
  let parsed: unknown;
  if (rawMap) {
    try {
      parsed = JSON.parse(rawMap);
    } catch {
      throw new Error("Billing plan mapping is invalid JSON.");
    }
  }
  const price = String((parsed as Record<string, unknown> | null)?.[LINECREW_PLAN_CODE] || "").trim();
  if (/^price_[A-Za-z0-9]+$/.test(price)) return price;
  const mode = String(environment || "").trim().toLowerCase();
  if (mode === "test") return LINECREW_TEST_PRICE_ID;
  if (mode === "live") return LINECREW_LIVE_PRICE_ID;
  throw new Error("Billing environment must be test or live to select the LineCrew Pro Price ID.");
}

export function withLinecrewPrice(rawMap: string | undefined, environment?: string) {
  let parsed: Record<string, unknown> = {};
  if (rawMap) {
    const value = JSON.parse(rawMap);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Billing plan mapping must be an object.");
    parsed = value as Record<string, unknown>;
  }
  return JSON.stringify({ ...parsed, [LINECREW_PLAN_CODE]: readLinecrewPriceId(rawMap, environment) });
}
