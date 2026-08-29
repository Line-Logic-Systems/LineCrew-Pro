import { parseNamedApiKey } from "./api-keys.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`Expected ${String(expected)}, received ${String(actual)}`);
  }
}

Deno.test("named API keys resolve without exposing neighboring keys", () => {
  const keys = JSON.stringify({
    default: "publishable-test-value",
    edge_functions_admin: "secret-test-value",
  });

  assertEquals(
    parseNamedApiKey(keys, "edge_functions_admin"),
    "secret-test-value",
  );
});

Deno.test("missing, malformed, and non-string keys fail closed", () => {
  assertEquals(parseNamedApiKey(undefined, "default"), "");
  assertEquals(parseNamedApiKey("not-json", "default"), "");
  assertEquals(parseNamedApiKey('{"default":42}', "default"), "");
  assertEquals(parseNamedApiKey('{"other":"value"}', "default"), "");
});
