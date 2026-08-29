import { createClient } from "https://esm.sh/@supabase/supabase-js@2.112.4";
import { getSecretKey } from "../_shared/api-keys.ts";

const jsonHeaders = { "content-type": "application/json" };

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: jsonHeaders });
  }

  const cronSecret = Deno.env.get("CREW_USAGE_CRON_SECRET") ?? "";
  const suppliedCronSecret = req.headers.get("x-linecrew-cron-secret") ?? "";
  const serviceKey = getSecretKey();
  const suppliedApiKey = req.headers.get("apikey") ?? "";
  if (
    !cronSecret || suppliedCronSecret !== cronSecret ||
    !serviceKey || suppliedApiKey !== serviceKey
  ) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: jsonHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  if (!supabaseUrl) {
    return new Response(JSON.stringify({ error: "Server billing configuration is incomplete" }), { status: 500, headers: jsonHeaders });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await admin.rpc("capture_all_company_crew_usage", {});
  if (error) {
    console.error("capture_all_company_crew_usage failed", error);
    return new Response(JSON.stringify({ error: "Crew usage capture failed" }), { status: 500, headers: jsonHeaders });
  }

  return new Response(JSON.stringify({ ok: true, companies_processed: Number(data) || 0 }), {
    status: 200,
    headers: jsonHeaders,
  });
});
