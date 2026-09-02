begin;

-- Remove every known permissive SELECT policy that can widen Daily Report
-- visibility to all active members of a company. PostgreSQL ORs permissive
-- policies together, so leaving even one broad policy would bypass the
-- role-scoped policy below.
drop policy if exists "company members read daily reports"
  on public.daily_reports;
drop policy if exists reports_company_select
  on public.daily_reports;
drop policy if exists linecrew_owner_daily_reports_select
  on public.daily_reports;
drop policy if exists daily_reports_role_scoped_select
  on public.daily_reports;

create policy daily_reports_role_scoped_select
on public.daily_reports
for select
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (
      lower(coalesce((select public.my_role()), '')) = 'superintendent'
      and (
        (select public.linecrew_has_capability('production_review'))
        or (select public.linecrew_has_capability('reporting'))
      )
    )
    or (
      lower(coalesce((select public.my_role()), '')) = 'foreman'
      and (
        foreman_id = (select auth.uid())
        or created_by = (select auth.uid())
      )
    )
  )
);

commit;
