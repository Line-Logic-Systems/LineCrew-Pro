begin;

alter table public.daily_reports
  add column if not exists weather_conditions text null,
  add column if not exists delay_hours numeric(8,2) not null default 0,
  add column if not exists delay_reason text null;

alter table public.daily_reports
  drop constraint if exists daily_reports_delay_hours_nonnegative;

alter table public.daily_reports
  add constraint daily_reports_delay_hours_nonnegative
  check (delay_hours >= 0);

create or replace function public.set_daily_report_context(
  p_report_id uuid,
  p_weather_conditions text,
  p_delay_hours numeric,
  p_delay_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_delay_hours numeric := coalesce(p_delay_hours, 0);
  v_delay_reason text := nullif(btrim(coalesce(p_delay_reason, '')), '');
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501',
      message = 'An active company membership is required.';
  end if;

  if v_delay_hours < 0 then
    raise exception using errcode = '22023',
      message = 'Delay hours cannot be negative.';
  end if;

  if v_delay_hours > 0 and v_delay_reason is null then
    raise exception using errcode = '22023',
      message = 'A delay reason is required when delay hours are entered.';
  end if;

  update public.daily_reports report
  set weather_conditions = nullif(btrim(coalesce(p_weather_conditions, '')), ''),
      delay_hours = v_delay_hours,
      delay_reason = case when v_delay_hours > 0 then v_delay_reason else null end
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft'
    and (
      report.created_by = auth.uid()
      or v_role in ('admin', 'gf')
    );

  if not found then
    raise exception using errcode = '42501',
      message = 'Only the report creator, an Admin or a General Foreman can update a draft report in their company.';
  end if;
end;
$$;

revoke all on function public.set_daily_report_context(uuid, text, numeric, text)
  from public, anon;
grant execute on function public.set_daily_report_context(uuid, text, numeric, text)
  to authenticated;

commit;
