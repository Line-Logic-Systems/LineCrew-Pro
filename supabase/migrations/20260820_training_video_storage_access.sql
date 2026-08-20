begin;

-- Require an active paid subscription for training access.
create or replace function public.current_training_access()
returns table (
  company_id uuid,
  role text,
  subscription_status text,
  can_train boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.company_id,
    lower(coalesce(p.role,'')) as role,
    c.subscription_status,
    (
      coalesce(p.active, true) is true
      and c.subscription_status = 'active'
      and (c.subscription_expires_at is null or c.subscription_expires_at > now())
    ) as can_train
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid();
$$;

-- Match the catalog to the exact uploaded object names.
update public.training_videos set storage_path = case slug
when 'welcome-linecrew-pro' then 'welcome/Welcome to LineCrew Pro.mp4'
when 'foreman-jsa' then 'foreman/LineCrew Pro - Foreman JSA.mp4'
when 'foreman-core-part-1' then 'foreman/Foreman Core Part 1.mp4'
when 'foreman-core-part-2' then 'foreman/Foreman Core Part 2.mp4'
when 'gf-overview' then 'gf/General Foreman Training.mp4'
when 'gf-dashboard-crews' then 'gf/GF_ Dashboard & Crews.mp4'
when 'gf-daily-report-review' then 'gf/GF Daily Report Review.mp4'
when 'gf-redline-review' then 'gf/GF Redline Review.mp4'
when 'gf-storm-crew-oversight' then 'gf/GF Storm Crew Oversight.mp4'
when 'gf-reports-exports' then 'gf/GF Reports & Exports.mp4'
when 'superintendent-overview' then 'superintendent/Superintendent Training.mp4'
when 'superintendent-job-oversight' then 'superintendent/Superintendent Job Oversight.mp4'
when 'superintendent-reporting' then 'superintendent/Superintendent Reporting.mp4'
when 'superintendent-oversight' then 'superintendent/Superintendent Oversight.mp4'
when 'admin-overview' then 'admin/Admin Training.mp4'
when 'admin-customers-contracts' then 'admin/Admin_ Customers & Contracts.mp4'
when 'admin-price-books' then 'admin/Admin_ Price Books.mp4'
when 'admin-jobs-packets' then 'admin/Admin_ Jobs & Packets.mp4'
when 'admin-users-roles' then 'admin/Admin_ Users & Roles.mp4'
when 'admin-daily-reports' then 'admin/Admin_ Daily Reports.mp4'
when 'admin-redlines' then 'admin/Admin_ Redlines.mp4'
when 'admin-storm-mode' then 'admin/Admin_ Storm Mode.mp4'
when 'admin-reports-exports' then 'admin/Admin_ Reports & Exports.mp4'
when 'admin-ai-assistant' then 'admin/Admin_ AI Assistant.mp4'
when 'owner-overview' then 'owner/Owner Training.mp4'
when 'owner-company-oversight' then 'owner/Owner Company Oversight.mp4'
when 'owner-admin-role-control' then 'owner/Owner Admin & Role Control.mp4'
when 'owner-reporting-admin' then 'owner/Owner Reporting & Admin.mp4'
when 'owner-security-recovery' then 'owner/Owner Security & Recovery.mp4'
else storage_path end;

-- Signed URLs require SELECT access to the underlying object. Enforce the same
-- role + subscription rule at Storage level so hidden training cannot be guessed.
drop policy if exists training_videos_role_subscriber_select on storage.objects;
create policy training_videos_role_subscriber_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'training-videos'
  and exists (
    select 1
    from public.training_videos tv
    join lateral public.current_training_access() a on true
    where tv.storage_path = storage.objects.name
      and tv.active is true
      and a.can_train is true
      and public.training_role_rank(a.role) >= public.training_role_rank(tv.minimum_role)
  )
);

commit;