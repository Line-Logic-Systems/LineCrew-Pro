-- Preserve every job close/reopen decision and require Owner authorization
-- when unresolved billing or production makes closeout an override.

begin;

create table if not exists public.job_closeout_history (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  job_id uuid not null references public.jobs(id) on delete restrict,
  action text not null check (action in ('closed', 'override_closed', 'reopened')),
  reason text,
  blockers jsonb not null default '{}'::jsonb,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  actor_role text not null,
  occurred_at timestamptz not null default now()
);

comment on table public.job_closeout_history is
  'Append-only audit trail for every job close, unresolved-work override close, and reopen.';
comment on column public.job_closeout_history.blockers is
  'Immutable closeout snapshot: paid Final Bill state plus unbilled and pending report counts.';

create index if not exists job_closeout_history_job_time_idx
  on public.job_closeout_history (job_id, occurred_at desc);
create index if not exists job_closeout_history_company_time_idx
  on public.job_closeout_history (company_id, occurred_at desc);

alter table public.job_closeout_history enable row level security;

revoke all on table public.job_closeout_history from public, anon, authenticated;
grant select on table public.job_closeout_history to service_role;

drop policy if exists server_only_no_direct_access on public.job_closeout_history;
create policy server_only_no_direct_access
  on public.job_closeout_history
  as restrictive
  for all
  to public
  using (false)
  with check (false);

create or replace function public.get_job_closeout_history(p_job_id uuid)
returns table (
  id uuid,
  action text,
  reason text,
  blockers jsonb,
  actor_id uuid,
  actor_name text,
  actor_role text,
  occurred_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
    into v_company, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company is null or not v_active or
     v_role not in ('owner', 'admin', 'superintendent', 'gf') then
    raise exception using errcode = '42501',
      message = 'Completed-job history access is required.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('reporting') then
    raise exception using errcode = '42501',
      message = 'Reporting permission is required.';
  end if;

  if not exists (
    select 1 from public.jobs j
    where j.id = p_job_id and j.company_id = v_company
  ) then
    raise exception using errcode = 'P0002', message = 'Job was not found.';
  end if;

  return query
  select h.id, h.action, h.reason, h.blockers, h.actor_id,
    coalesce(p.full_name, 'Former team member'), h.actor_role, h.occurred_at
  from public.job_closeout_history h
  left join public.profiles p on p.id = h.actor_id
  where h.job_id = p_job_id and h.company_id = v_company
  order by h.occurred_at asc, h.id asc;
end;
$$;

create or replace function public.set_job_closeout(
  p_job_id uuid,
  p_close boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid;
  v_role text;
  v_active boolean;
  v_job_active boolean;
  v_rec record;
  v_has_paid_final boolean := false;
  v_override_required boolean := false;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_blockers jsonb := '{}'::jsonb;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
    into v_company, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company is null or not v_active or
     v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Job closeout access is required.';
  end if;

  if v_role = 'superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode = '42501',
      message = 'Reporting and Actual Pricing permissions are required.';
  end if;

  select j.active into v_job_active
  from public.jobs j
  where j.id = p_job_id and j.company_id = v_company
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Job was not found.';
  end if;

  if coalesce(p_close, false) then
    if not v_job_active then
      raise exception using errcode = '23514', message = 'Job is already closed.';
    end if;

    select * into v_rec
    from public.get_job_billing_reconciliation(p_job_id);

    select exists (
      select 1
      from public.billing_export_batches b
      where b.company_id = v_company
        and b.job_id = p_job_id
        and b.billing_type = 'final'
        and b.status = 'paid'
    ) into v_has_paid_final;

    v_override_required :=
      not v_has_paid_final or
      coalesce(v_rec.approved_unbilled_value, 0) > 0.01 or
      coalesce(v_rec.awaiting_review_count, 0) > 0 or
      coalesce(v_rec.draft_report_count, 0) > 0;

    v_blockers := jsonb_build_object(
      'has_paid_final_bill', v_has_paid_final,
      'approved_unbilled_value', coalesce(v_rec.approved_unbilled_value, 0),
      'awaiting_review_count', coalesce(v_rec.awaiting_review_count, 0),
      'draft_report_count', coalesce(v_rec.draft_report_count, 0)
    );

    if v_override_required and v_reason is null then
      raise exception using errcode = '23514', message =
        'Closeout has unresolved billing or production. An Owner override reason is required.';
    end if;

    if v_override_required and v_role <> 'owner' then
      raise exception using errcode = '42501', message =
        'Only the company Owner can approve closeout with unresolved billing or production.';
    end if;

    update public.jobs
    set active = false,
      closed_at = now(),
      closed_by = auth.uid(),
      closeout_status = 'closed',
      closeout_notes = v_reason
    where id = p_job_id and company_id = v_company;

    insert into public.job_closeout_history (
      company_id, job_id, action, reason, blockers, actor_id, actor_role
    ) values (
      v_company,
      p_job_id,
      case when v_override_required then 'override_closed' else 'closed' end,
      v_reason,
      v_blockers,
      auth.uid(),
      v_role
    );
  else
    if v_job_active then
      raise exception using errcode = '23514', message = 'Job is already open.';
    end if;

    if v_reason is null then
      raise exception using errcode = '22023',
        message = 'Enter a reason for reopening the job.';
    end if;

    update public.jobs
    set active = true,
      closed_at = null,
      closeout_status = 'reopened',
      closeout_notes = v_reason,
      reopened_at = now(),
      reopened_by = auth.uid()
    where id = p_job_id and company_id = v_company;

    insert into public.job_closeout_history (
      company_id, job_id, action, reason, blockers, actor_id, actor_role
    ) values (
      v_company,
      p_job_id,
      'reopened',
      v_reason,
      '{}'::jsonb,
      auth.uid(),
      v_role
    );
  end if;
end;
$$;

revoke all on function public.get_job_closeout_history(uuid) from public, anon;
revoke all on function public.set_job_closeout(uuid, boolean, text) from public, anon;

grant execute on function public.get_job_closeout_history(uuid) to authenticated, service_role;
grant execute on function public.set_job_closeout(uuid, boolean, text) to authenticated, service_role;

commit;
