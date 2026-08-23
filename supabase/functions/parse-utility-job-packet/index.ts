import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_FILE_BYTES = 20 * 1024 * 1024;
const PROFILE_VERSION = "oncor-tivoli-cu-estimate-v1";

const packetSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "provider_key", "format_key", "profile_version", "work_order", "confidence", "warnings", "rows"],
  properties: {
    status: { type: "string", enum: ["supported", "unsupported", "uncertain"] },
    provider_key: { type: "string", enum: ["oncor", "unknown"] },
    format_key: { type: "string" },
    profile_version: { type: "string" },
    work_order: { type: "string" },
    confidence: { type: "number" },
    warnings: { type: "array", items: { type: "string" } },
    rows: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source_page", "work_point_code", "work_point_description", "work_type", "material_cu", "contractor_unit_code", "estimated_quantity", "description", "confidence", "include_in_import", "review_note"],
        properties: {
          source_page: { type: "integer" },
          work_point_code: { type: "string" },
          work_point_description: { type: "string" },
          work_type: { type: "string", enum: ["install", "remove"] },
          material_cu: { type: "string" },
          contractor_unit_code: { type: "string" },
          estimated_quantity: { type: "number" },
          description: { type: "string" },
          confidence: { type: "number" },
          include_in_import: { type: "boolean" },
          review_note: { type: "string" },
        },
      },
    },
  },
};

const instructions = `
You extract utility construction job packets for LineCrew Pro. Accuracy is more important than returning rows.

First identify the utility and packet format. This release supports only the Oncor Tivoli/IBM CU Estimate table format. Strong Oncor evidence includes Tivoli/IBM branding and tables headed Station, Task ID, As Built Qty, Est Qty, CU, Contractor CU, Description with Install or Remove sections. Do not interpret a differently formatted utility/co-op packet using Oncor rules. For another utility, return status=unsupported, provider_key=unknown, no rows, and a concise warning. If identification is ambiguous, return status=uncertain and no rows.

ONCOR PROFILE (${PROFILE_VERSION}):
- Read only CU Estimate construction table pages. Ignore covers, maps, drawings, planned materials/labor, related work orders, notes, and summaries.
- Station is the work_point_code. Preserve leading zeros exactly (0014 stays 0014).
- Est Qty is the designed/authorized quantity and applies to both CU and Contractor CU on that row.
- CU is storeroom/material ordering reference only. Put it in material_cu. Never use it as the production/pay unit.
- Contractor CU is the LineCrew Pro production/pay unit. Put it in contractor_unit_code.
- Rows with a blank Contractor CU are material-only: retain them for audit, set contractor_unit_code to an empty string, include_in_import=false, and review_note="Material-only row; no Contractor CU".
- Install and Remove are separate work types. A section label continues until the next Install/Remove label or Station.
- Extract every qualifying source row separately. Do not sum duplicates; deterministic database finalization will sum matching Station + work type + Contractor CU.
- Never invent a code, quantity, Station, description, or missing digit. Lower confidence and add a review note when a cell is hard to read.
- source_page is the one-based PDF page number, not a printed internal page label.
- profile_version must be exactly ${PROFILE_VERSION} for supported Oncor packets.
- Work order should be the packet WO/WR identifier without guessing.
`;

function outputText(result: Record<string, unknown>): string {
  if (typeof result.output_text === "string") return result.output_text;
  if (!Array.isArray(result.output)) return "";
  return result.output.flatMap((item: Record<string, unknown>) =>
    Array.isArray(item.content)
      ? item.content.flatMap((part: Record<string, unknown>) => part.type === "output_text" && typeof part.text === "string" ? [part.text] : [])
      : []
  ).join("\n");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    if (request.method !== "POST") throw new Error("POST required.");
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new Error("Authentication required.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const openAiKey = Deno.env.get("OPENAI_API_KEY");
    if (!supabaseUrl || !anonKey || !openAiKey) throw new Error("Packet parsing service is not configured.");

    const client = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });
    const { data: userData, error: userError } = await client.auth.getUser();
    if (userError || !userData.user) throw new Error("Authentication required.");
    const { data: allowed, error: permissionError } = await client.rpc("linecrew_can_manage_job_packages");
    if (permissionError || allowed !== true) {
      return new Response(JSON.stringify({ error: "You do not have permission to add job packets." }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await request.json();
    const filename = String(body?.filename || "").trim().slice(0, 255);
    const fileData = String(body?.file_data || "");
    const sourceSha256 = String(body?.source_sha256 || "").toLowerCase();
    if (!filename.toLowerCase().endsWith(".pdf")) throw new Error("This parser accepts PDF job packets only.");
    if (!/^data:application\/pdf;base64,[a-z0-9+/=\r\n]+$/i.test(fileData)) throw new Error("The PDF data is invalid.");
    const estimatedBytes = Math.floor((fileData.length - fileData.indexOf(",") - 1) * 0.75);
    if (estimatedBytes <= 0 || estimatedBytes > MAX_FILE_BYTES) throw new Error("The PDF must be 20 MB or smaller.");
    if (!/^[a-f0-9]{64}$/.test(sourceSha256)) throw new Error("The packet fingerprint is invalid.");

    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Authorization": `Bearer ${openAiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("OPENAI_DOCUMENT_MODEL") || "gpt-5.4",
        instructions,
        input: [{ role: "user", content: [
          { type: "input_file", filename, file_data: fileData, detail: "high" },
          { type: "input_text", text: "Identify this packet and extract all supported authorized-unit source rows. Return no rows unless the provider/format is supported with confidence." },
        ] }],
        reasoning: { effort: "high" },
        text: { format: { type: "json_schema", name: "utility_packet", strict: true, schema: packetSchema } },
        max_output_tokens: 30000,
        store: false,
      }),
      signal: AbortSignal.timeout(150000),
    });
    if (!response.ok) {
      console.error("OpenAI packet parse failed", response.status, (await response.text()).slice(0, 1000));
      throw new Error("The packet could not be analyzed. Nothing was saved.");
    }
    const result = await response.json();
    const parsed = JSON.parse(outputText(result));
    if (parsed.status === "supported" && parsed.provider_key === "oncor") {
      if (parsed.profile_version !== PROFILE_VERSION || !Array.isArray(parsed.rows) || parsed.rows.length === 0) {
        throw new Error("The Oncor packet was identified, but no construction rows could be read. Nothing was saved.");
      }
      if (parsed.rows.length > 4000 || !Number.isFinite(parsed.confidence) || parsed.confidence < 0 || parsed.confidence > 1) {
        throw new Error("The packet extraction failed validation. Nothing was saved.");
      }
      for (const row of parsed.rows) {
        if (!Number.isInteger(row.source_page) || row.source_page < 1 ||
            !["install", "remove"].includes(row.work_type) ||
            !Number.isFinite(row.estimated_quantity) || row.estimated_quantity <= 0 ||
            !Number.isFinite(row.confidence) || row.confidence < 0 || row.confidence > 1 ||
            !String(row.work_point_code || "").trim()) {
          throw new Error("The packet extraction contained an invalid source row. Nothing was saved.");
        }
      }
    } else {
      parsed.rows = [];
    }

    return new Response(JSON.stringify({ ...parsed, source_sha256: sourceSha256 }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Unable to analyze packet." }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
