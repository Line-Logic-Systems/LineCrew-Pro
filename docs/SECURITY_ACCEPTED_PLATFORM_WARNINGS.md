# Accepted platform security warnings

## `pg_net` extension schema

Supabase's database linter reports `pg_net` as installed from the `public`
extension namespace. In production, version `0.20.4` reports itself as
non-relocatable, while its working tables and sequence already live in the
dedicated `net` schema.

Moving it would require dropping and reinstalling a managed networking
extension. That could remove or interrupt dependent HTTP jobs, webhooks, or
schedules. LineCrew Pro therefore accepts this informational platform warning
and does not mutate the extension. Re-evaluate only if Supabase provides a
supported relocation path for the installed version.
