import {
  accessForStatus,
  assertEventEnvironment,
  eventCreatedSeconds,
  expectedLivemode,
  isStaleEvent,
  knownPlanCode,
  mapStatus,
  normalizedMonthlyAmount,
  planForStripePrice,
  planForSubscriptionEvent,
  resolveCompanyId,
} from "./logic.ts";

function equal(actual: unknown, expected: unknown, message = "values differ") {
  if (actual !== expected) {
    throw new Error(`${message}: ${String(actual)} !== ${String(expected)}`);
  }
}
function throws(fn: () => unknown, message: string) {
  let threw = false;
  try {
    fn();
  } catch {
    threw = true;
  }
  if (!threw) throw new Error(message);
}
const priceMap = JSON.stringify({
  starter: "price_s",
  business: "price_b",
  pro: "price_p",
  enterprise: "price_e",
});

Deno.test("known plan codes normalize", () =>
  equal(knownPlanCode(" Pro "), "pro"));
Deno.test("unknown plan codes fail closed", () =>
  equal(knownPlanCode("pilot"), null));
Deno.test("mapped price resolves", () =>
  equal(planForStripePrice("price_b", priceMap), "business"));
Deno.test("unmapped price rejects", () =>
  throws(
    () => planForStripePrice("price_x", priceMap),
    "unmapped price accepted",
  ));
Deno.test("missing map rejects", () =>
  throws(
    () => planForStripePrice("price_s", undefined),
    "missing map accepted",
  ));
Deno.test("invalid map rejects", () =>
  throws(() => planForStripePrice("price_s", "[]"), "array map accepted"));
Deno.test("deleted event keeps prior plan without map", () =>
  equal(
    planForSubscriptionEvent(
      "customer.subscription.deleted",
      null,
      undefined,
      "starter",
    ),
    "starter",
  ));
Deno.test("deleted event rejects unknown prior plan", () =>
  throws(
    () =>
      planForSubscriptionEvent(
        "customer.subscription.deleted",
        null,
        undefined,
        "pilot",
      ),
    "unknown canceled plan accepted",
  ));
Deno.test("updated event requires price map", () =>
  throws(
    () =>
      planForSubscriptionEvent(
        "customer.subscription.updated",
        "price_s",
        undefined,
        "starter",
      ),
    "update skipped price map",
  ));
Deno.test("company metadata and client reference agree", () =>
  equal(
    resolveCompanyId({ metadataCompanyId: "a", clientReferenceId: "a" }),
    "a",
  ));
Deno.test("customer owner is authoritative", () =>
  equal(
    resolveCompanyId({ metadataCompanyId: "a", customerOwnerCompanyId: "a" }),
    "a",
  ));
Deno.test("metadata-client mismatch rejects", () =>
  throws(
    () => resolveCompanyId({ metadataCompanyId: "a", clientReferenceId: "b" }),
    "mismatch accepted",
  ));
Deno.test("customer-metadata mismatch rejects", () =>
  throws(
    () =>
      resolveCompanyId({ metadataCompanyId: "a", customerOwnerCompanyId: "b" }),
    "ownership mismatch accepted",
  ));
Deno.test("missing company stays null", () =>
  equal(resolveCompanyId({}), null));
Deno.test("valid event creation time", () =>
  equal(eventCreatedSeconds(123), 123));
Deno.test("invalid event creation time rejects", () =>
  throws(() => eventCreatedSeconds(0), "zero timestamp accepted"));
Deno.test("older events are stale", () => equal(isStaleEvent(9, 10), true));
Deno.test("newer events are current", () => equal(isStaleEvent(11, 10), false));
Deno.test("same-second events are accepted", () =>
  equal(isStaleEvent(10, 10), false));
Deno.test("test environment is not livemode", () =>
  equal(expectedLivemode("test", undefined), false));
Deno.test("live environment is livemode", () =>
  equal(expectedLivemode("live", undefined), true));
Deno.test("test key derives environment", () =>
  equal(expectedLivemode(undefined, "sk_test_x"), false));
Deno.test("live key derives environment", () =>
  equal(expectedLivemode(undefined, "sk_live_x"), true));
Deno.test("unknown environment rejects", () =>
  throws(
    () => expectedLivemode("sandbox", undefined),
    "unknown environment accepted",
  ));
Deno.test("mismatched livemode rejects", () =>
  throws(
    () => assertEventEnvironment(true, false),
    "live event accepted in test",
  ));
Deno.test("unpaid maps to past_due", () =>
  equal(mapStatus("unpaid"), "past_due"));
Deno.test("canceled access is disabled", () =>
  equal(accessForStatus("canceled"), false));
Deno.test("yearly amount normalizes monthly", () =>
  equal(normalizedMonthlyAmount(120000, "year", 1), 10000));
