import fs from "node:fs";
import path from "node:path";

const baselinePath = process.argv[2];

if (!baselinePath) {
  console.error("Usage: node scripts/validate-supabase-baseline.mjs <schema.sql>");
  process.exit(1);
}

if (!fs.existsSync(baselinePath)) {
  console.error(`Baseline file not found: ${baselinePath}`);
  process.exit(1);
}

const sql = fs.readFileSync(baselinePath, "utf8");
const normalized = sql.toLowerCase();
const errors = [];

if (Buffer.byteLength(sql, "utf8") < 10_000) {
  errors.push("The schema dump is unexpectedly small (less than 10 KB).");
}

const forbiddenDataPatterns = [
  /^\s*copy\s+public\./gim,
  /^\s*insert\s+into\s+(?:only\s+)?public\./gim
];

if (forbiddenDataPatterns.some((pattern) => pattern.test(sql))) {
  errors.push("The dump appears to contain public table row data. The baseline must be schema-only.");
}

const requiredTables = [
  "companies",
  "profiles",
  "customers",
  "contracts",
  "price_books",
  "price_book_items",
  "jobs",
  "daily_reports"
];

const qualifiedIdentifierPattern = (name) => `(?:public\\.${name}|"public"\\."${name}")`;

for (const table of requiredTables) {
  const tablePattern = new RegExp(
    `create\\s+table(?:\\s+if\\s+not\\s+exists)?\\s+${qualifiedIdentifierPattern(table)}(?:\\s|\\()`,
    "i"
  );
  if (!tablePattern.test(sql)) {
    errors.push(`Missing core table definition: public.${table}`);
  }
}

const rlsTables = [
  "profiles",
  "customers",
  "contracts",
  "price_books",
  "price_book_items",
  "jobs",
  "daily_reports"
];

for (const table of rlsTables) {
  const rlsPattern = new RegExp(
    `alter\\s+table(?:\\s+only)?\\s+${qualifiedIdentifierPattern(table)}\\s+enable\\s+row\\s+level\\s+security`,
    "i"
  );
  if (!rlsPattern.test(sql)) {
    errors.push(`Row Level Security is not enabled in the dump for public.${table}`);
  }
}

if (!/create\s+policy\b/i.test(normalized)) {
  errors.push("No RLS policies were found in the schema dump.");
}

if (!/create(?:\s+or\s+replace)?\s+function\s+public\./i.test(normalized)) {
  errors.push("No public database functions were found in the schema dump.");
}

if (errors.length > 0) {
  console.error("Supabase baseline validation failed:\n");
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`Verified schema-only baseline: ${path.resolve(baselinePath)}`);
console.log(`Core tables checked: ${requiredTables.length}`);
console.log(`Tenant tables checked for RLS: ${rlsTables.length}`);
