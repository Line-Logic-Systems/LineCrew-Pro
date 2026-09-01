export const PACKET_CONFIDENCE_FALLBACK_THRESHOLD = 0.9;
export const ROW_CONFIDENCE_FALLBACK_THRESHOLD = 0.85;

const QUALITY_WARNING_PATTERN = /\b(?:ambiguous|blurred?|cropped|cut\s*off|hard\s*to\s*read|illegible|low[-\s]?quality|poor\s*scan|unreadable)\b/i;

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isConfidence(value) {
  return Number.isFinite(value) && value >= 0 && value <= 1;
}

function pushUnique(values, value) {
  if (!values.includes(value)) values.push(value);
}

function appendReviewNote(existing, note) {
  const current = String(existing || "").trim();
  return current ? `${current} ${note}` : note;
}

/**
 * Converts recoverable model omissions into explicit, unchecked review rows.
 * Source facts are never invented: an unidentified location gets a visible
 * REVIEW-PAGE-* placeholder and cannot be imported until a reviewer edits it.
 * Rows with impossible pages or nonpositive quantities are discarded with a
 * warning because they cannot satisfy the staging table's safety constraints.
 *
 * @param {unknown} parsed
 * @param {{profileVersion?: string, pageOffset?: number, pageCount?: number}} options
 */
export function normalizePacketExtraction(parsed, options = {}) {
  if (!isPlainObject(parsed)) return parsed;
  const {
    profileVersion = "",
    pageOffset = 0,
    pageCount = 1,
  } = options;
  const firstSourcePage = pageOffset + 1;
  const lastSourcePage = pageOffset + pageCount;
  const normalized = {
    ...parsed,
    confidence: isConfidence(parsed.confidence) ? parsed.confidence : 0.5,
    warnings: Array.isArray(parsed.warnings)
      ? parsed.warnings.map(value => String(value || "").trim()).filter(Boolean)
      : [],
  };

  if (normalized.status === "unsupported") {
    normalized.provider_key = "unknown";
    normalized.batch_disposition = "unsupported_packet";
    normalized.rows = [];
    return normalized;
  }
  if (normalized.status === "uncertain") {
    if (!["no_candidate_table", "needs_review"].includes(normalized.batch_disposition)) {
      normalized.batch_disposition = "needs_review";
    }
    normalized.rows = [];
    return normalized;
  }
  if (normalized.status !== "supported") return normalized;

  normalized.provider_key = String(normalized.provider_key || "").trim() || "unknown";
  normalized.profile_version = profileVersion;
  const safeRows = [];
  for (const originalRow of Array.isArray(normalized.rows) ? normalized.rows : []) {
    if (!isPlainObject(originalRow)) {
      pushUnique(normalized.warnings, "One malformed source row was omitted from review.");
      continue;
    }
    let sourcePage = Number(originalRow.source_page);
    if (
      Number.isInteger(sourcePage) &&
      (sourcePage < firstSourcePage || sourcePage > lastSourcePage) &&
      sourcePage >= 1 && sourcePage <= pageCount
    ) {
      sourcePage += pageOffset;
    }
    if (!Number.isInteger(sourcePage) || sourcePage < firstSourcePage || sourcePage > lastSourcePage) {
      pushUnique(normalized.warnings, "One row with an invalid source page was omitted from review.");
      continue;
    }
    const quantity = Number(originalRow.estimated_quantity);
    if (!Number.isFinite(quantity) || quantity <= 0) {
      pushUnique(normalized.warnings, "One row without a positive authorized quantity was omitted from review.");
      continue;
    }

    const row = {
      ...originalRow,
      source_page: sourcePage,
      estimated_quantity: quantity,
      confidence: isConfidence(originalRow.confidence) ? originalRow.confidence : 0.5,
      include_in_import: originalRow.include_in_import === true,
      work_point_code: String(originalRow.work_point_code || "").trim(),
      contractor_unit_code: String(originalRow.contractor_unit_code || "").trim(),
      review_note: String(originalRow.review_note || "").trim(),
    };
    if (!row.work_point_code) {
      row.work_point_code = `REVIEW-PAGE-${sourcePage}`;
      row.include_in_import = false;
      row.review_note = appendReviewNote(
        row.review_note,
        "Work point was not identified; assign it before import.",
      );
    }
    if (!row.contractor_unit_code) {
      row.include_in_import = false;
      row.review_note = appendReviewNote(
        row.review_note,
        "No production/pay unit was identified; confirm whether this is material-only.",
      );
    }
    safeRows.push(row);
  }

  normalized.rows = safeRows;
  if (safeRows.length) {
    normalized.batch_disposition = "supported_rows";
  } else {
    normalized.status = "uncertain";
    normalized.batch_disposition = "needs_review";
    pushUnique(normalized.warnings, "A possible construction table was found, but no safe review rows could be created.");
  }
  return normalized;
}

/**
 * Deterministically checks a structured packet result. The model's own
 * confidence is only one signal: malformed rows, impossible page numbers,
 * review notes, and scan-quality warnings also trigger the full-model pass.
 *
 * @param {unknown} parsed
 * @param {{profileVersion?: string, pageOffset?: number, pageCount?: number}} options
 */
export function assessPacketExtraction(parsed, options = {}) {
  const {
    profileVersion = "",
    pageOffset = 0,
    pageCount = 1,
  } = options;
  const invalidReasons = [];
  const fallbackReasons = [];

  if (!isPlainObject(parsed)) {
    return {
      valid: false,
      needsFallback: true,
      invalidReasons: ["response_not_object"],
      fallbackReasons: ["response_not_object"],
    };
  }

  const allowedStatuses = new Set(["supported", "unsupported", "uncertain"]);
  const allowedDispositions = new Set([
    "supported_rows",
    "no_candidate_table",
    "needs_review",
    "unsupported_packet",
  ]);
  if (!allowedStatuses.has(parsed.status)) invalidReasons.push("invalid_status");
  if (!allowedDispositions.has(parsed.batch_disposition)) invalidReasons.push("invalid_batch_disposition");
  if (!isConfidence(parsed.confidence)) invalidReasons.push("invalid_packet_confidence");
  if (!Array.isArray(parsed.warnings)) invalidReasons.push("invalid_warnings");
  if (!Array.isArray(parsed.rows)) invalidReasons.push("invalid_rows");

  const warnings = Array.isArray(parsed.warnings) ? parsed.warnings : [];
  if (warnings.some(warning => QUALITY_WARNING_PATTERN.test(String(warning || "")))) {
    fallbackReasons.push("quality_warning");
  }

  if (parsed.status === "supported") {
    if (!String(parsed.provider_key || "").trim()) invalidReasons.push("missing_provider_key");
    if (parsed.profile_version !== profileVersion) invalidReasons.push("profile_version_mismatch");
    if (parsed.batch_disposition !== "supported_rows") invalidReasons.push("supported_disposition_mismatch");
    if (!Array.isArray(parsed.rows) || parsed.rows.length === 0) invalidReasons.push("supported_without_rows");
    if (Number.isFinite(parsed.confidence) && parsed.confidence < PACKET_CONFIDENCE_FALLBACK_THRESHOLD) {
      fallbackReasons.push("low_packet_confidence");
    }
  } else if (parsed.status === "unsupported") {
    if (parsed.provider_key !== "unknown") invalidReasons.push("unsupported_provider_mismatch");
    if (parsed.batch_disposition !== "unsupported_packet") invalidReasons.push("unsupported_disposition_mismatch");
    if (Array.isArray(parsed.rows) && parsed.rows.length) invalidReasons.push("unsupported_with_rows");
  } else if (parsed.status === "uncertain") {
    if (!new Set(["no_candidate_table", "needs_review"]).has(parsed.batch_disposition)) {
      invalidReasons.push("uncertain_disposition_mismatch");
    }
    if (Array.isArray(parsed.rows) && parsed.rows.length) invalidReasons.push("uncertain_with_rows");
    if (parsed.batch_disposition === "needs_review") fallbackReasons.push("model_requested_review");
  }

  if (Array.isArray(parsed.rows) && parsed.rows.length > 4000) invalidReasons.push("too_many_rows");
  const firstSourcePage = pageOffset + 1;
  const lastSourcePage = pageOffset + pageCount;
  for (const row of Array.isArray(parsed.rows) ? parsed.rows : []) {
    if (!isPlainObject(row)) {
      pushUnique(invalidReasons, "invalid_source_row");
      continue;
    }
    if (!Number.isInteger(row.source_page) || row.source_page < firstSourcePage || row.source_page > lastSourcePage) {
      pushUnique(invalidReasons, "source_page_out_of_range");
    }
    if (!String(row.work_point_code || "").trim()) pushUnique(invalidReasons, "missing_work_point_code");
    if (!["install", "transfer", "remove"].includes(row.work_type)) pushUnique(invalidReasons, "invalid_work_type");
    if (!Number.isFinite(row.estimated_quantity) || row.estimated_quantity <= 0) {
      pushUnique(invalidReasons, "invalid_estimated_quantity");
    }
    if (!isConfidence(row.confidence)) pushUnique(invalidReasons, "invalid_row_confidence");
    if (typeof row.include_in_import !== "boolean") pushUnique(invalidReasons, "invalid_import_flag");
    if (row.include_in_import === true && !String(row.contractor_unit_code || "").trim()) {
      pushUnique(invalidReasons, "import_row_missing_contractor_unit");
    }
    if (isConfidence(row.confidence) && row.confidence < ROW_CONFIDENCE_FALLBACK_THRESHOLD) {
      pushUnique(fallbackReasons, "low_row_confidence");
    }
    if (row.include_in_import === true && String(row.review_note || "").trim()) {
      pushUnique(fallbackReasons, "included_row_needs_review");
    }
  }

  for (const reason of invalidReasons) pushUnique(fallbackReasons, reason);
  return {
    valid: invalidReasons.length === 0,
    needsFallback: fallbackReasons.length > 0,
    invalidReasons,
    fallbackReasons,
  };
}

export function parsePacketOutput(rawText) {
  try {
    return { parsed: JSON.parse(rawText), error: null };
  } catch (_error) {
    return { parsed: null, error: "invalid_json" };
  }
}

export async function runPacketModelFallback({
  primaryModel,
  fallbackModel,
  analyze,
  assess,
}) {
  const primaryOutput = await analyze(primaryModel, "primary", []);
  let parsed = primaryOutput.parsed;
  let outputError = primaryOutput.error;
  let assessment = outputError
    ? { valid:false, needsFallback:true, invalidReasons:[outputError], fallbackReasons:[outputError] }
    : assess(parsed);
  let selectedModel = primaryModel;
  let fallbackUsed = false;

  if (assessment.needsFallback && fallbackModel !== primaryModel) {
    fallbackUsed = true;
    const fallbackOutput = await analyze(fallbackModel, "fallback", assessment.fallbackReasons);
    parsed = fallbackOutput.parsed;
    outputError = fallbackOutput.error;
    assessment = outputError
      ? { valid:false, needsFallback:false, invalidReasons:[outputError], fallbackReasons:[] }
      : assess(parsed);
    selectedModel = fallbackModel;
  }

  return {
    parsed,
    assessment,
    selectedModel,
    fallbackUsed,
    outputError,
  };
}
