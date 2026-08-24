begin;

-- Company files must become inaccessible immediately when a profile is
-- suspended, including through the Storage API (which is separate from the
-- PostgREST pre-request hook).
drop policy if exists linecrew_active_profile_required_for_company_files
  on storage.objects;
create policy linecrew_active_profile_required_for_company_files
on storage.objects
as restrictive
for all
to authenticated
using (
  not (bucket_id = any(array[
    'billing-export-attachments',
    'daily-report-attachments',
    'jsa-uploads'
  ]::text[]))
  or public.current_user_has_active_profile()
)
with check (
  not (bucket_id = any(array[
    'billing-export-attachments',
    'daily-report-attachments',
    'jsa-uploads'
  ]::text[]))
  or public.current_user_has_active_profile()
);

-- Daily-report objects must use company/report/file paths whose report belongs
-- to the active caller's company. Deletion remains available to the uploader
-- and production reviewers.
drop policy if exists daily_report_storage_company_insert on storage.objects;
create policy daily_report_storage_company_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'daily-report-attachments'
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.daily_reports report
    where report.id::text = (storage.foldername(name))[2]
      and report.company_id = public.my_company_id()
  )
);

drop policy if exists daily_report_storage_company_select on storage.objects;
create policy daily_report_storage_company_select
on storage.objects for select to authenticated
using (
  bucket_id = 'daily-report-attachments'
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.daily_reports report
    where report.id::text = (storage.foldername(name))[2]
      and report.company_id = public.my_company_id()
  )
);

drop policy if exists daily_report_storage_owner_or_lead_delete on storage.objects;
create policy daily_report_storage_owner_or_lead_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'daily-report-attachments'
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.daily_reports report
    where report.id::text = (storage.foldername(name))[2]
      and report.company_id = public.my_company_id()
  )
  and (
    owner_id = auth.uid()::text
    or public.can_review_daily_reports()
  )
);

-- JSA files follow the role-scoped JSA record rather than being available to
-- every member of the company. The creator and authorized safety reviewers can
-- read/delete; only the creator can upload into a newly-created JSA folder.
drop policy if exists "jsa uploads company insert" on storage.objects;
create policy "jsa uploads company insert"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'jsa-uploads'
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.daily_report_jsas jsa
    where jsa.id::text = (storage.foldername(name))[2]
      and jsa.company_id = public.my_company_id()
      and jsa.created_by = auth.uid()
  )
);

drop policy if exists "jsa uploads company read" on storage.objects;
create policy "jsa uploads company read"
on storage.objects for select to authenticated
using (
  bucket_id = 'jsa-uploads'
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.daily_report_jsas jsa
    where jsa.id::text = (storage.foldername(name))[2]
      and jsa.company_id = public.my_company_id()
      and (
        jsa.created_by = auth.uid()
        or public.my_role() = any(array['owner','admin','gf']::text[])
        or (
          public.my_role() = 'superintendent'
          and public.linecrew_has_capability('safety_records')
        )
      )
  )
);

drop policy if exists "jsa uploads company delete" on storage.objects;
create policy "jsa uploads company delete"
on storage.objects for delete to authenticated
using (
  bucket_id = 'jsa-uploads'
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.daily_report_jsas jsa
    where jsa.id::text = (storage.foldername(name))[2]
      and jsa.company_id = public.my_company_id()
      and (
        jsa.created_by = auth.uid()
        or public.my_role() = any(array['owner','admin','gf']::text[])
        or (
          public.my_role() = 'superintendent'
          and public.linecrew_has_capability('safety_records')
        )
      )
  )
);

-- Metadata reads receive the same immediate suspension protection.
do $$
begin
  if to_regclass('public.daily_report_attachments') is not null then
    alter table public.daily_report_attachments enable row level security;
    drop policy if exists daily_report_attachments_company_select
      on public.daily_report_attachments;
    create policy daily_report_attachments_company_select
      on public.daily_report_attachments for select to authenticated
      using (company_id = public.my_company_id());
    drop policy if exists active_profile_required
      on public.daily_report_attachments;
    create policy active_profile_required
      on public.daily_report_attachments as restrictive for all to authenticated
      using (public.current_user_has_active_profile())
      with check (public.current_user_has_active_profile());
  end if;

  if to_regclass('public.jsa_upload_attachments') is not null then
    alter table public.jsa_upload_attachments enable row level security;
    drop policy if exists active_profile_required
      on public.jsa_upload_attachments;
    create policy active_profile_required
      on public.jsa_upload_attachments as restrictive for all to authenticated
      using (public.current_user_has_active_profile())
      with check (public.current_user_has_active_profile());
  end if;
end;
$$;

commit;
