begin;

create or replace function public.get_pending_utility_packet_import_for_package(
  p_package_id uuid
)
returns table (
  import_id uuid,
  provider_key text,
  format_key text,
  profile_version text,
  source_filename text,
  detected_work_order text,
  extraction_confidence numeric,
  extraction_summary jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select packet_import.id, packet_import.provider_key, packet_import.format_key,
    packet_import.profile_version, packet_import.source_filename,
    packet_import.detected_work_order, packet_import.extraction_confidence,
    packet_import.extraction_summary
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  where packet_import.job_package_id = p_package_id
    and packet_import.status = 'review'
    and (
      lower(coalesce(profile.role,'')) in ('owner','admin','gf')
      or (
        lower(coalesce(profile.role,'')) = 'superintendent'
        and public.linecrew_has_capability('job_packages')
      )
    )
  order by packet_import.created_at desc
  limit 1;
$$;

revoke all on function public.get_pending_utility_packet_import_for_package(uuid)
  from public, anon;
grant execute on function public.get_pending_utility_packet_import_for_package(uuid)
  to authenticated;

commit;
