import {
  linecrewMonthlyCents,
  normalizeCrewQuantity,
  readLinecrewPriceId,
} from "./billing-pricing.ts";

function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) throw new Error(`${String(actual)} !== ${String(expected)}`);
}
function throws(fn: () => unknown) {
  let didThrow = false;
  try { fn(); } catch { didThrow = true; }
  if (!didThrow) throw new Error("Expected function to throw.");
}

Deno.test("five crews cost the base price", () => equal(linecrewMonthlyCents(5), 59_900));
Deno.test("ten crews cost base plus five additions", () => equal(linecrewMonthlyCents(10), 102_400));
Deno.test("forty-one crews have no tier jump", () => equal(linecrewMonthlyCents(41), 365_900));
Deno.test("crew quantity must be an integer at least five", () => {
  throws(() => normalizeCrewQuantity(4));
  throws(() => normalizeCrewQuantity(5.5));
});
Deno.test("single Stripe price is read from server mapping", () =>
  equal(readLinecrewPriceId('{"linecrew":"price_valid123"}'), "price_valid123"));
Deno.test("test environment selects the test price fallback", () =>
  equal(readLinecrewPriceId(undefined, "test"), "price_1UC8SPRTTF4i3BoKTZbciysW"));
Deno.test("live environment selects the live price fallback", () =>
  equal(readLinecrewPriceId(undefined, "live"), "price_1UC8UmIjgPYpBqtY7XbXw47q"));
