# Smart Utility Packet Import

## Safety boundary

Packet extraction is a draft. It never changes a job's authorized production until an authorized user reviews the source rows and chooses **Import Reviewed Contractor Units**.

The adaptive extractor reads unfamiliar utility/co-op layouts into the same canonical review rows. It uses document labels and table meaning instead of inheriting Oncor column meaning. Ambiguous rows remain excluded or require review; unfamiliar branding alone is never a reason to reject a packet.

## Canonical source row

| Field | Meaning |
| --- | --- |
| `provider_key` | Detected utility/co-op slug, or `unknown` when branding is unavailable |
| `format_key` | Detected document layout |
| `source_page` | One-based PDF page for audit/review |
| `work_point_code` | Utility location; Oncor `Station` |
| `work_type` | `install`, `transfer` or `remove` |
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

1. The authenticated browser hashes the PDF and splits packets into two-page request batches so dense construction tables stay safely inside the Edge Function request timeout.
2. The Edge Function verifies the role, detects the profile, preserves original PDF page numbers, and returns strict structured source rows for each batch.
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

## Unfamiliar utilities and layouts

The adaptive profile identifies page/table selection, work-point mapping, production-code mapping, material-code handling, work-type mapping, and authorized quantity meaning from the packet itself. Every extracted row remains a draft until an authorized user reviews it, and every included production unit must match the job's active contract Price Book before finalization. Provider-specific fixtures should still be added as real packet examples become available so recurring formats receive regression coverage.
