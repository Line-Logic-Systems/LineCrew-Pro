begin;

create table if not exists public.daily_report_audit_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  daily_report_id uuid not null references public.daily_reports(id) on delete cascade,
  event_type text not null check (
    event_type in ('created', 'submitted', 'returned', 'approved', 'archived', 'restored')
  ),
  actor_id uuid null references auth.users(id) on delete set null,
  actor_name text null,
  actor_role text null,
  event_notes text null,
  created_at timestamptz not null default now()
);

create index if not exists daily_report_audit_events_report_created_idx
  on public.daily_report_audit_events (daily_report_id, created_at desc);

create index if not exists daily_report_audit_events_company_created_idx
  on public.daily_report_audit_events (company_id, created_at desc);

alter table public.daily_report_audit_events enable row level security;

revoke all on table public.daily_report_audit_events from public, anon, authenticated;

create or replace function public.record_daily_report_audit_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_type text;
  v_actor_name text;
  v_actor_role text;
  v_notes text;
begin
  if tg_op = 'INSERT' then
    v_event_type := 'created';
  elsif old.archived is distinct from new.archived then
    v_event_type := case when new.archived then 'archived' else 'restored' end;
  elsif lower(coalesce(old.status, 'draft')) is distinct from
        lower(coalesce(new.status, 'draft')) then
    v_event_type := case lower(coalesce(new.status, 'draft'))
      when 'submitted' then 'submitted'
      when 'approved' then 'approved'
      when 'draft' then 'returned'
      else null
    end;
  end if;

  if v_event_type is null then
    return new;
  end if;

  select profile.full_name, lower(coalesce(profile.role, ''))
  into v_actor_name, v_actor_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.company_id = new.company_id;

  v_notes := case
    when v_event_type = 'approved' and new.redline_override_reason is not null
      then 'Admin redline override: ' || new.redline_override_reason
    when v_event_type in ('approved', 'returned')
      then nullif(btrim(coalesce(new.review_notes, '')), '')
    else null
  end;

  insert into public.daily_report_audit_events (
    company_id,
    daily_report_id,
    event_type,
    actor_id,
    actor_name,
    actor_role,
    event_notes
  ) values (
    new.company_id,
    new.id,
    v_event_type,
    auth.uid(),
    coalesce(v_actor_name, 'System'),
    nullif(v_actor_role, ''),
    v_notes
  );

  return new;
end;
$$;

drop trigger if exists daily_report_audit_event_trigger on public.daily_reports;
create trigger daily_report_audit_event_trigger
after insert or update of status, archived on public.daily_reports
for each row execute function public.record_daily_report_audit_event();

create or replace function public.get_daily_report_audit_history(p_report_id uuid)
returns table (
  event_id uuid,
  event_type text,
  actor_name text,
  actor_role text,
  event_notes text,
  event_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_created_by uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  select report.company_id, report.created_by
  into v_report_company_id, v_created_by
  from public.daily_reports report
  where report.id = p_report_id;

  if v_active is not true or v_company_id is null or
     v_report_company_id is null or v_report_company_id <> v_company_id or
     (v_role not in ('admin', 'gf') and v_created_by <> auth.uid()) then
    raise exception using errcode = '42501',
      message = 'You cannot view this daily report history.';
  end if;

  return query
  select
    audit.id,
    audit.event_type,
    audit.actor_name,
    audit.actor_role,
    audit.event_notes,
    audit.created_at
  from public.daily_report_audit_events audit
  where audit.daily_report_id = p_report_id
    and audit.company_id = v_company_id
  order by audit.created_at desc, audit.id desc;
end;
$$;

revoke all on function public.get_daily_report_audit_history(uuid) from public, anon;
grant execute on function public.get_daily_report_audit_history(uuid) to authenticated;

commit;
