# Flexible JSA workflow

LineCrew Pro supports contractor safety documentation without requiring a JSA before production.

## Company choices

Owner/Admin chooses one company default:

- `digital` — use the LineCrew Pro digital JSA.
- `upload` — use the contractor's existing paper/company JSA and upload PDF/photos.
- `both` — Foreman chooses either method for each JSA.

The default is `both` so existing contractors can adopt LineCrew Pro without replacing their current safety form.

## Uploaded company JSA

An uploaded JSA stores searchable metadata in `daily_report_jsas`:

- company
- job
- work date
- Foreman/user
- crew
- optional notes
- source = `upload`

Files are stored privately in the `jsa-uploads` bucket and metadata is recorded in `jsa_upload_attachments`. Supported formats: PDF, JPEG, PNG, HEIC/HEIF, maximum 15 MB per file. Multiple pages/files are supported with `page_order`.

Storage paths are company-prefixed and storage policies scope access to the signed-in user's company.

## Digital JSA

The existing LineCrew Pro JSA remains available and records `jsa_source = digital`.

## Important policy

A JSA is **not required** to create, edit, or submit a Daily Report. LineCrew Pro records JSAs when a contractor uses them but does not dictate when a JSA must exist. Contractor safety policies and applicable regulations remain the governing requirements.
