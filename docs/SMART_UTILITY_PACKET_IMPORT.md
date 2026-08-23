# Smart Utility Packet Import

## Safety boundary

Packet extraction is a draft. It never changes a job's authorized production until an authorized user reviews the source rows and chooses **Import Reviewed Contractor Units**.

Unsupported or uncertain formats return no rows. A new utility/co-op format must get its own versioned profile and fixture tests; it must not inherit Oncor column meaning by guesswork.

## Canonical source row

| Field | Meaning |
| --- | --- |
| `provider_key` | Detected utility profile (`oncor` in v1) |
| `format_key` | Detected document layout |
| `source_page` | One-based PDF page for audit/review |
| `work_point_code` | Utility location; Oncor `Station` |
| `work_type` | `install` or `remove` |
| `material_cu` | Utility material/storeroom code; never a production unit |
| `contractor_unit_code` | Contractor production/pay unit matched to the contract Price Book |
| `estimated_quantity` | Designed quantity from the utility packet |
| `confidence` | Extraction confidence for review prioritization |

## Oncor Tivoli/IBM profile v1

- Detect Tivoli/IBM branding plus the CU Estimate table headings before applying the profile.
- Read construction CU Estimate pages only.
- `Station` becomes the work point and keeps leading zeros.
- `Est Qty` is the designed/authorized quantity.
- `CU` is retained as `material_cu` only.
- `Contractor CU` is the production/pay unit.
- Blank Contractor CU rows are retained for audit and excluded from production import.
- Install and Remove remain distinct.
- Matching Station + Contractor CU rows are summed at finalization, while install and remove quantities remain separate columns.
- Every included Contractor Unit must match an active Price Book item for the job's contract. A mismatch blocks the entire transaction.

For the reviewed Station 0014 example, the expected consolidated production rows are:

| Work | Contractor Unit | Quantity |
| --- | --- | ---: |
| Install | OH4200 | 3 |
| Install | OH4100 | 3 |
| Install | OH4030 | 1 |
| Install | OH4010 | 1 |
| Install | MS7000 | 3 |
| Remove | OH4100 | 3 |
| Remove | OH4030 | 1 |

## Transaction and audit behavior

1. The authenticated browser hashes the PDF.
2. The Edge Function verifies the role, detects the profile, and returns strict structured source rows.
3. One RPC creates the package and stages all source rows atomically.
4. The reviewer can correct Station, work type, Contractor Unit, quantity, and inclusion.
5. Finalization validates every included Contractor Unit before writing any authorized unit.
6. Finalization consolidates duplicates, writes authorized units, records the source filename, and marks the import reviewed/imported in the same transaction.
7. The same file hash cannot be attached twice to the same job.

## Role behavior

- Owner and Admin: job creation and packet import.
- General Foreman: the same job creation and packet import workflow.
- Superintendent: the same workflow when the relevant `jobs` and `job_packages` capabilities are enabled.
- Foreman: assigned-job field reporting only; cannot create jobs or import packets.

## Adding another utility

A new profile must define positive detection evidence, page/table selection, work-point mapping, production-code mapping, material-code handling, work-type mapping, quantity meaning, exclusion rules, and known fixture totals. If detection is not decisive, return `unsupported` or `uncertain`; never silently fall back to Oncor.
