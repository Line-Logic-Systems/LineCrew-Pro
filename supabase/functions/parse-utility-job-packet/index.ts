import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { getPublishableKey } from "../_shared/api-keys.ts";
import {
  assessPacketExtraction,
  normalizePacketExtraction,
  parsePacketOutput,
  runPacketModelFallback,
} from "./packet-logic.mjs";

const allowedOrigins = new Set([
  "https://app.linecrewpro.com",
  ...(Deno.env.get("CORS_ALLOWED_ORIGINS") || "").split(",").map((value) => value.trim()).filter(Boolean),
]);

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://app.linecrewpro.com",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const MAX_FILE_BYTES = 20 * 1024 * 1024;
const PROFILE_VERSION = "adaptive-utility-packet-v2";
const REQUEST_TIME_BUDGET_MS = 138000;

class PacketParseError extends Error {
  code: string;
  status: number;
  retryOriginal: boolean;
  retrySmaller: boolean;

  constructor(
    message: string,
    code = "packet_parse_failed",
    status = 400,
    retryOriginal = false,
    retrySmaller = false,
  ) {
    super(message);
    this.name = "PacketParseError";
    this.code = code;
    this.status = status;
    this.retryOriginal = retryOriginal;
    this.retrySmaller = retrySmaller;
  }
}

const packetSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "batch_disposition", "provider_key", "format_key", "profile_version", "work_order", "confidence", "warnings", "rows"],
  properties: {
    status: { type: "string", enum: ["supported", "unsupported", "uncertain"] },
    batch_disposition: { type: "string", enum: ["supported_rows", "no_candidate_table", "needs_review", "unsupported_packet"] },
    provider_key: { type: "string" },
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
          work_type: { type: "string", enum: ["install", "transfer", "remove"] },
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
You extract utility construction job packets for LineCrew Pro. Every row you return is checked by a human reviewer before anything is imported, and unchecked rows import nothing. So accuracy means never inventing a value; it does not mean withholding a row you can see. A visible row described only in warnings is lost work — return it with include_in_import=false and a review_note instead.

Identify the utility/co-op and document layout from branding, headings, labels, and table structure. Extract construction authorization rows from any utility packet; do not require a known provider or a previously seen layout. Set provider_key to a short lowercase provider slug when identifiable, otherwise "unknown". Set format_key to a concise lowercase layout description. profile_version must be exactly ${PROFILE_VERSION} whenever rows are returned.

Set batch_disposition precisely:
- supported_rows: reliable construction authorization rows were extracted from this page batch, regardless of provider or layout.
- no_candidate_table: this batch contains a cover, map, drawing, note, summary, material list, completed/as-built report, or other pages with no construction authorization table. Return status=uncertain and no rows. This is not an error and does not need review.
- needs_review: a construction table is present, but scan quality or ambiguous column meaning leaves some rows unsettled. Return status=uncertain together with every row you can read, each unsettled row carrying include_in_import=false, lowered confidence, and a review_note naming the doubt. Explain the batch-level issue once in warnings. Return no rows only when nothing on the pages is legible enough to transcribe.
- unsupported_packet: use only when the document is not a utility construction job packet at all. Never use this merely because the utility or layout is unfamiliar.

ADAPTIVE EXTRACTION PROFILE (${PROFILE_VERSION}):
- Read construction authorization/design tables. Ignore covers, maps, drawings, planned material/labor summaries, invoices, as-built/completed quantities, notes, and unrelated work orders.
- Map the utility's location identifier (for example Work Point, Station, Pole, Structure, Location, Task, or Assembly location) to work_point_code. A valid identifier may be numeric, alphabetic, alphanumeric, or contain punctuation/spaces (examples: 1, R1, R3, A-002, WP 4B). Preserve the exact displayed identifier and leading zeros. Never interpret a letter inside the identifier as a work action; for example, R1 remains the location R1 and does not mean Retire 1. If a table has authorized units but no location column, use the most specific visible section/location identifier. Never invent one.
- Map only the designed, estimated, planned, or authorized quantity to estimated_quantity. Never substitute an as-built, completed, installed-to-date, cost, labor-hour, or material quantity.
- Map the contractor production/pay/billing unit to contractor_unit_code. Labels may include Contractor Unit, Contractor CU, Pay Unit, Billing Unit, Unit Code, Assembly, or a provider-specific equivalent.
- A material, stock, catalog, or storeroom code belongs in material_cu, not contractor_unit_code. If a row is clearly material-only, retain it for audit with contractor_unit_code empty, include_in_import=false, and an explanatory review_note.
- If the packet has one plausible unit-code column and no separate material-code column, preserve it as contractor_unit_code but lower confidence and add a review note so the reviewer confirms it against the contract Price Book.
- Doubt about whether a code matches the contract Price Book is never a reason to withhold a row. The reviewer holds the Price Book and you do not, and the app already blocks import of codes it cannot match. Return the row with the code exactly as displayed, lower confidence, and add a review_note. State price-book uncertainty once per batch in warnings rather than repeating it for each page or column.
- Normalize work_type to install, transfer, or remove from headings, action columns, quantity columns, or section labels. Keep actions separate.
- In columnar staking sheets, each column heading may define a separate work point. For example, "1 New OH 0 feet", "R1 Retire OH 129 feet", and "R3 Retire OH 372 feet" have work points 1, R1, and R3; New means install and Retire means remove. Within those columns, prefixes such as N (quantity) and R (quantity) mean install/new and remove/retire. EX generally describes existing/reference equipment and is not an authorized production row unless the packet explicitly identifies it as payable work.
- If the unit meaning, location, action, or authorized quantity is ambiguous, do not guess and do not discard. Return the row exactly as displayed with include_in_import=false, lowered confidence, and a review_note stating what is unresolved, so the reviewer can settle it against the contract. Withholding the whole batch is a last resort for pages where nothing is legible.
- Extract every qualifying source row separately. Do not sum duplicates; deterministic database finalization performs consolidation after human review.
- Never invent a code, quantity, location, description, or missing digit. Lower confidence and add a concise review note when a cell is hard to read.
- source_page is the one-based PDF page number, not a printed internal page label.
- Work order should be the packet WO/WR/job identifier without guessing.
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

function upstreamPacketError(response: Response, upstreamBody: string, requestId: string) {
  let upstreamCode = "unknown";
  let upstreamType = "unknown";
  try {
    const upstreamError = JSON.parse(upstreamBody)?.error;
    upstreamCode = String(upstreamError?.code || "unknown").slice(0, 100);
    upstreamType = String(upstreamError?.type || "unknown").slice(0, 100);
  } catch (_error) {
    // The upstream status and request id still make a non-JSON response traceable.
  }
  console.error(JSON.stringify({
    event: "packet_analyzer_rejected",
    request_id: requestId,
    upstream_status: response.status,
    upstream_code: upstreamCode,
    upstream_type: upstreamType,
  }));
  if (response.status === 429 && upstreamCode === "insufficient_quota") {
    return new PacketParseError(
      "The job-packet AI service is temporarily unavailable. Nothing was saved. Contact LineCrew Pro Support.",
      "packet_analyzer_quota",
      503,
    );
  }
  if (response.status === 429) {
    return new PacketParseError(
      "The job-packet AI service is busy right now. Nothing was saved. Wait a few minutes and try again.",
      "packet_analyzer_rate_limited",
      503,
    );
  }
  if ([401, 403].includes(response.status)) {
    return new PacketParseError(
      "The job-packet AI service is temporarily unavailable. Nothing was saved. Contact LineCrew Pro Support.",
      "packet_analyzer_configuration",
      503,
    );
  }
  if (response.status >= 500) {
    return new PacketParseError(
      "The job-packet AI service is temporarily unavailable. Nothing was saved. Try again shortly.",
      "packet_analyzer_unavailable",
      503,
    );
  }
  return new PacketParseError(
    "The packet analyzer could not read this PDF page group.",
    "packet_analyzer_rejected",
    422,
    true,
  );
}

Deno.serve(async (request) => {
  const requestId = crypto.randomUUID();
  const requestStartedAt = Date.now();
  let requestedPageCount = 0;
  const origin = request.headers.get("Origin") || "";
  if (origin && !allowedOrigins.has(origin)) {
    return new Response(JSON.stringify({ error: "Origin not allowed." }), {
      status: 403, headers: { ...corsHeaders(request), "Content-Type": "application/json" },
    });
  }
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(request) });
  try {
    if (request.method !== "POST") throw new Error("POST required.");
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new Error("Authentication required.");

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = getPublishableKey();
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
        status: 403, headers: { ...corsHeaders(request), "Content-Type": "application/json" },
      });
    }

    const body = await request.json();
    const filename = String(body?.filename || "").trim().slice(0, 255);
    const fileData = String(body?.file_data || "");
    const sourceSha256 = String(body?.source_sha256 || "").toLowerCase();
    const pageOffset = Number(body?.page_offset || 0);
    const totalPages = Number(body?.total_pages || 0);
    const suppliedPageCount = Number(body?.page_count || 0);
    // Version 17 and older browsers sent two-page groups without page_count.
    // Keep those sessions working while the five-page frontend rolls out.
    const pageCount = Number.isInteger(suppliedPageCount) && suppliedPageCount > 0
      ? suppliedPageCount
      : Math.min(2, totalPages - pageOffset);
    requestedPageCount = pageCount;
    if (!filename.toLowerCase().endsWith(".pdf")) throw new Error("This parser accepts PDF job packets only.");
    if (!/^data:application\/pdf;base64,[a-z0-9+/=\r\n]+$/i.test(fileData)) throw new Error("The PDF data is invalid.");
    const estimatedBytes = Math.floor((fileData.length - fileData.indexOf(",") - 1) * 0.75);
    if (estimatedBytes <= 0 || estimatedBytes > MAX_FILE_BYTES) throw new Error("The PDF must be 20 MB or smaller.");
    if (!/^[a-f0-9]{64}$/.test(sourceSha256)) throw new Error("The packet fingerprint is invalid.");
    if (!Number.isInteger(pageOffset) || pageOffset < 0 ||
        !Number.isInteger(pageCount) || pageCount < 1 || pageCount > totalPages ||
        pageOffset + pageCount > totalPages ||
        !Number.isInteger(totalPages) || totalPages < 1 || pageOffset >= totalPages) {
      throw new Error("The PDF page range is invalid.");
    }

    console.log(JSON.stringify({
      event: "packet_parse_started",
      request_id: requestId,
      page_offset: pageOffset,
      page_count: pageCount,
      total_pages: totalPages,
      estimated_bytes: estimatedBytes,
    }));

    const primaryModel = Deno.env.get("OPENAI_DOCUMENT_MODEL") || "gpt-5.4-mini";
    const fallbackModel = Deno.env.get("OPENAI_DOCUMENT_FALLBACK_MODEL") || "gpt-5.4";
    const usageTotal = { input:0, output:0, reasoning:0, total:0 };
    const analyzeWithModel = async (model: string, attempt: "primary" | "fallback", fallbackReasons: string[] = []) => {
      const elapsed = Date.now() - requestStartedAt;
      const remaining = REQUEST_TIME_BUDGET_MS - elapsed;
      if (remaining < 15000) {
        throw new PacketParseError(
          "The packet analyzer needs another attempt, but this page group took too long. Nothing was saved. Try again shortly.",
          "packet_analyzer_timeout",
          504,
        );
      }
      const response = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: { "Authorization": `Bearer ${openAiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model,
          instructions: `${instructions}\nThis request contains a page batch from the original PDF. ` +
            `The first page in this batch is original PDF page ${pageOffset + 1} of ${totalPages}. ` +
            `For every extracted row, source_page must be the original one-based PDF page number: ` +
            `batch page number + ${pageOffset}. If this batch contains no candidate construction authorization table, ` +
            `return status=uncertain, batch_disposition=no_candidate_table, and an empty rows array.` +
            (attempt === "fallback"
              ? ` This is the full-model verification pass. Re-check this page group carefully because the first pass was flagged for: ${fallbackReasons.join(", ")}.`
              : ""),
          input: [{ role: "user", content: [
            { type: "input_file", filename, file_data: fileData, detail: "high" },
            { type: "input_text", text: "Identify this utility packet and extract every reliable authorized construction-unit source row, adapting to the document's actual labels and layout. Unfamiliar providers and formats are valid and must not be rejected solely for being new." },
          ] }],
          reasoning: { effort: attempt === "primary" ? "low" : "medium" },
          text: { format: { type: "json_schema", name: "utility_packet", strict: true, schema: packetSchema } },
          max_output_tokens: 30000,
          store: false,
        }),
        signal: AbortSignal.timeout(Math.min(90000, remaining)),
      });
      if (!response.ok) {
        throw upstreamPacketError(response, (await response.text()).slice(0, 2000), requestId);
      }
      const result = await response.json();
      const usage = result?.usage || {};
      const attemptUsage = {
        input:Number(usage.input_tokens || 0),
        output:Number(usage.output_tokens || 0),
        reasoning:Number(usage.output_tokens_details?.reasoning_tokens || 0),
        total:Number(usage.total_tokens || 0),
      };
      usageTotal.input += attemptUsage.input;
      usageTotal.output += attemptUsage.output;
      usageTotal.reasoning += attemptUsage.reasoning;
      usageTotal.total += attemptUsage.total;
      console.log(JSON.stringify({
        event: "packet_ai_attempt_completed",
        request_id: requestId,
        attempt,
        model,
        page_offset: pageOffset,
        page_count: pageCount,
        input_tokens: attemptUsage.input,
        output_tokens: attemptUsage.output,
        reasoning_tokens: attemptUsage.reasoning,
        total_tokens: attemptUsage.total,
      }));
      const modelOutput = parsePacketOutput(outputText(result));
      if (modelOutput.parsed) {
        modelOutput.parsed = normalizePacketExtraction(modelOutput.parsed, {
          profileVersion: PROFILE_VERSION,
          pageOffset,
          pageCount,
        });
      }
      return modelOutput;
    };

    const fallbackRun = await runPacketModelFallback({
      primaryModel,
      fallbackModel,
      analyze:async (model: string, attempt: "primary" | "fallback", fallbackReasons: string[]) => {
        if (attempt === "fallback") {
          console.log(JSON.stringify({
            event: "packet_full_model_fallback_started",
            request_id: requestId,
            primary_model: primaryModel,
            fallback_model: fallbackModel,
            page_offset: pageOffset,
            page_count: pageCount,
            reasons: fallbackReasons,
          }));
        }
        return await analyzeWithModel(model, attempt, fallbackReasons);
      },
      assess:(candidate: Record<string, unknown>) =>
        assessPacketExtraction(candidate, { profileVersion:PROFILE_VERSION, pageOffset, pageCount }),
    });
    const { parsed, assessment, selectedModel, fallbackUsed, outputError } = fallbackRun;

    if (outputError && fallbackUsed) {
      throw new PacketParseError(
        "The packet analyzer could not verify this PDF page group. Nothing was saved.",
        "packet_full_model_invalid_response",
        422,
        true,
      );
    }
    if (!assessment.valid) {
      console.error(JSON.stringify({
        event: "packet_validation_failed",
        request_id: requestId,
        model: selectedModel,
        page_offset: pageOffset,
        page_count: pageCount,
        reasons: assessment.invalidReasons,
      }));
      throw new PacketParseError(
        "The packet extraction failed validation after review. Nothing was saved.",
        "packet_extraction_invalid",
        422,
        true,
      );
    }
    if (parsed.status !== "supported") parsed.rows = [];
    console.log(JSON.stringify({
      event: "packet_parse_completed",
      request_id: requestId,
      model: selectedModel,
      primary_model: primaryModel,
      fallback_model: fallbackModel,
      fallback_used: fallbackUsed,
      page_offset: pageOffset,
      page_count: pageCount,
      input_tokens: usageTotal.input,
      output_tokens: usageTotal.output,
      reasoning_tokens: usageTotal.reasoning,
      total_tokens: usageTotal.total,
    }));

    return new Response(JSON.stringify({ ...parsed, source_sha256: sourceSha256 }), {
      headers: { ...corsHeaders(request), "Content-Type": "application/json" },
    });
  } catch (error) {
    const packetError = error instanceof PacketParseError ? error : null;
    const message = error instanceof Error ? error.message : "Unable to analyze packet.";
    const timeout = error instanceof DOMException && error.name === "TimeoutError";
    const code = timeout ? "packet_analyzer_timeout" : packetError?.code || "packet_parse_failed";
    const status = timeout ? 504 : packetError?.status || 400;
    const retrySmaller = requestedPageCount > 1 && (timeout || packetError?.retryOriginal === true || packetError?.retrySmaller === true);
    console.error(JSON.stringify({
      event: "packet_parse_failed",
      request_id: requestId,
      code,
      message: message.slice(0, 300),
    }));
    return new Response(JSON.stringify({
      error: message,
      code,
      request_id: requestId,
      retry_original: packetError?.retryOriginal === true,
      retry_smaller: retrySmaller,
    }), {
      status, headers: { ...corsHeaders(request), "Content-Type": "application/json" },
    });
  }
});
