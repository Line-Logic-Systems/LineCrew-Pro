import assert from "node:assert/strict";
import {
  assessPacketExtraction,
  parsePacketOutput,
  runPacketModelFallback,
} from "./packet-logic.mjs";

const context = {
  profileVersion: "adaptive-utility-packet-v2",
  pageOffset: 10,
  pageCount: 5,
};

function supported(overrides = {}) {
  return {
    status: "supported",
    batch_disposition: "supported_rows",
    provider_key: "oncor",
    format_key: "oncor-tivoli-cu-estimate",
    profile_version: context.profileVersion,
    work_order: "WO-100",
    confidence: 0.98,
    warnings: [],
    rows: [{
      source_page: 11,
      work_point_code: "0014",
      work_point_description: "Pole 14",
      work_type: "install",
      material_cu: "M1",
      contractor_unit_code: "U1",
      estimated_quantity: 2,
      description: "Fixture unit",
      confidence: 0.97,
      include_in_import: true,
      review_note: "",
    }],
    ...overrides,
  };
}

assert.deepEqual(
  assessPacketExtraction(supported(), context),
  { valid:true, needsFallback:false, invalidReasons:[], fallbackReasons:[] },
  "A high-confidence, structurally valid Mini result must not spend a full-model call.",
);

assert.deepEqual(
  assessPacketExtraction(supported({
    provider_key:"united-cooperative-services",
    format_key:"provider-specific-construction-table",
  }), context),
  { valid:true, needsFallback:false, invalidReasons:[], fallbackReasons:[] },
  "A structurally valid packet from an unfamiliar utility must be accepted for review.",
);

assert.equal(
  assessPacketExtraction(supported({
    provider_key:"united-cooperative-services",
    rows:[{ ...supported().rows[0], work_type:"transfer" }],
  }), context).valid,
  true,
  "Adaptive packets must support transfer rows as well as install and remove.",
);

assert.equal(
  assessPacketExtraction(supported({ confidence:0.72 }), context).needsFallback,
  true,
  "Low packet confidence must trigger GPT-5.4.",
);

assert.equal(
  assessPacketExtraction(supported({
    rows:[{ ...supported().rows[0], confidence:0.7 }],
  }), context).needsFallback,
  true,
  "A low-confidence row must trigger GPT-5.4.",
);

const impossiblePage = assessPacketExtraction(supported({
  rows:[{ ...supported().rows[0], source_page:16 }],
}), context);
assert.equal(impossiblePage.valid, false);
assert.equal(impossiblePage.needsFallback, true);
assert(impossiblePage.invalidReasons.includes("source_page_out_of_range"));

assert.deepEqual(
  assessPacketExtraction({
    ...supported(),
    status:"uncertain",
    batch_disposition:"no_candidate_table",
    provider_key:"oncor",
    confidence:0.7,
    rows:[],
  }, context),
  { valid:true, needsFallback:false, invalidReasons:[], fallbackReasons:[] },
  "A normal cover/map batch must not trigger an expensive retry.",
);

const requestedReview = assessPacketExtraction({
  ...supported(),
  status:"uncertain",
  batch_disposition:"needs_review",
  provider_key:"oncor",
  confidence:0.55,
  warnings:["The CU table is partially unreadable."],
  rows:[],
}, context);
assert.equal(requestedReview.valid, true);
assert.equal(requestedReview.needsFallback, true);
assert(requestedReview.fallbackReasons.includes("model_requested_review"));

assert.equal(parsePacketOutput('{"status":"supported"}').error, null);
assert.equal(parsePacketOutput("not json").error, "invalid_json");

const fallbackCalls = [];
const fullResult = supported({ confidence:0.99, work_order:"WO-FULL" });
const fallbackRun = await runPacketModelFallback({
  primaryModel:"gpt-5.4-mini",
  fallbackModel:"gpt-5.4",
  analyze:async (model, attempt, reasons) => {
    fallbackCalls.push({ model, attempt, reasons });
    return {
      parsed:attempt === "primary" ? supported({ confidence:0.6 }) : fullResult,
      error:null,
    };
  },
  assess:parsed => assessPacketExtraction(parsed, context),
});
assert.deepEqual(fallbackCalls.map(call => call.model), ["gpt-5.4-mini", "gpt-5.4"]);
assert.equal(fallbackRun.fallbackUsed, true);
assert.equal(fallbackRun.selectedModel, "gpt-5.4");
assert.equal(fallbackRun.parsed.work_order, "WO-FULL");
assert.equal(fallbackRun.assessment.valid, true);

let routineCallCount = 0;
const routineRun = await runPacketModelFallback({
  primaryModel:"gpt-5.4-mini",
  fallbackModel:"gpt-5.4",
  analyze:async () => {
    routineCallCount += 1;
    return { parsed:supported(), error:null };
  },
  assess:parsed => assessPacketExtraction(parsed, context),
});
assert.equal(routineCallCount, 1, "A clean Mini result must make exactly one model call.");
assert.equal(routineRun.fallbackUsed, false);
assert.equal(routineRun.selectedModel, "gpt-5.4-mini");

let noTableCallCount = 0;
const noTableResult = {
  ...supported(),
  status:"uncertain",
  batch_disposition:"no_candidate_table",
  provider_key:"oncor",
  confidence:0.65,
  rows:[],
};
const noTableRun = await runPacketModelFallback({
  primaryModel:"gpt-5.4-mini",
  fallbackModel:"gpt-5.4",
  analyze:async () => {
    noTableCallCount += 1;
    return { parsed:noTableResult, error:null };
  },
  assess:parsed => assessPacketExtraction(parsed, context),
});
assert.equal(noTableCallCount, 1, "Cover, map, and drawing pages must not spend a GPT-5.4 call.");
assert.equal(noTableRun.fallbackUsed, false);

const malformedCalls = [];
const malformedRun = await runPacketModelFallback({
  primaryModel:"gpt-5.4-mini",
  fallbackModel:"gpt-5.4",
  analyze:async (model, attempt) => {
    malformedCalls.push(model);
    return attempt === "primary"
      ? { parsed:null, error:"invalid_json" }
      : { parsed:fullResult, error:null };
  },
  assess:parsed => assessPacketExtraction(parsed, context),
});
assert.deepEqual(malformedCalls, ["gpt-5.4-mini", "gpt-5.4"]);
assert.equal(malformedRun.outputError, null);
assert.equal(malformedRun.assessment.valid, true);

console.log("Packet parser fallback logic tests passed.");
