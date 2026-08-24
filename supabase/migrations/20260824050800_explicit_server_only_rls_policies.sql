begin;

-- These tables are intentionally accessed only through guarded RPCs or the
-- service role. An explicit restrictive deny policy prevents a later table
-- grant from accidentally exposing raw tenant, billing, support, or audit data.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'app_error_events',
    'billing_export_attachments',
    'billing_export_batches',
    'billing_export_lines',
    'contract_field_settings',
    'daily_production_unit_locations',
    'daily_production_units',
    'daily_report_audit_events',
    'job_assignment_audit_events',
    'job_package_authorized_units',
    'job_package_work_points',
    'job_packages',
    'pilot_feedback',
    'platform_support_users',
    'storm_mode_assignments',
    'support_access_requests',
    'support_audit_events',
    'team_invitations',
    'utility_packet_import_rows',
    'utility_packet_imports',
    'work_points'
  ]
  loop
    if to_regclass('public.' || v_table) is not null then
      execute format('alter table public.%I enable row level security', v_table);
      execute format('revoke all on table public.%I from public, anon, authenticated', v_table);
      execute format('drop policy if exists server_only_no_direct_access on public.%I', v_table);
      execute format(
        'create policy server_only_no_direct_access on public.%I as restrictive for all to public using (false) with check (false)',
        v_table
      );
    end if;
  end loop;
end;
$$;

commit;
