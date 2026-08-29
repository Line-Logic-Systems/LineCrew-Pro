const DEFAULT_PUBLISHABLE_KEY_NAME = "default";
const EDGE_FUNCTION_SECRET_KEY_NAME = "edge_functions_admin";

export function parseNamedApiKey(
  rawKeys: string | undefined,
  keyName: string,
): string {
  if (!rawKeys) return "";

  try {
    const keys = JSON.parse(rawKeys) as Record<string, unknown>;
    const key = keys[keyName];
    return typeof key === "string" ? key.trim() : "";
  } catch {
    return "";
  }
}

function readNamedApiKey(environmentName: string, keyName: string): string {
  return parseNamedApiKey(Deno.env.get(environmentName), keyName);
}

export function getPublishableKey(
  keyName = DEFAULT_PUBLISHABLE_KEY_NAME,
): string {
  return readNamedApiKey("SUPABASE_PUBLISHABLE_KEYS", keyName);
}

export function getSecretKey(
  keyName = EDGE_FUNCTION_SECRET_KEY_NAME,
): string {
  return readNamedApiKey("SUPABASE_SECRET_KEYS", keyName);
}
