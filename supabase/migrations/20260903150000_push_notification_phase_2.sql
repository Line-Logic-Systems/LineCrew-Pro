-- Phase 2 push routing for Daily Reports and JSAs.
-- Notification bodies intentionally contain no customer names, addresses, or money.

alter table public.companies
  add column if not exists daily_report_reminder_time time default '18:00',
  add column if not exists jsa_reminder_time time default '09:00';

comment on column public.companies.daily_report_reminder_time is
  'Local company time for missing Daily Report reminders. NULL disables them.';
comment on column public.companies.jsa_reminder_time is
  'Local company time for missing or unsigned JSA reminders. NULL disables them.';

create table public.push_notification_preferences (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  gf_delivery_mode text not null default 'submitted_and_reminders'
    check (gf_delivery_mode in ('submitted_only', 'submitted_and_reminders')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (company_id, user_id)
);

alter table public.push_notification_preferences enable row level security;
revoke all on public.push_notification_preferences from public, anon, authenticated;
grant select on public.push_notification_preferences to service_role;

create table public.push_notification_outbox (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  event_key text not null unique,
  event_type text not null,
  subject_id uuid,
  title text not null default 'LineCrew Pro',
  body text not null,
  url text not null default '/',
  tag text not null,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'failed')),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index push_notification_outbox_pending_idx
  on public.push_notification_outbox (available_at, created_at)
  where status = 'pending';

alter table public.push_notification_outbox enable row level security;
revoke all on public.push_notification_outbox from public, anon, authenticated;
grant select, update on public.push_notification_outbox to service_role;

create or replace function public.linecrew_my_gf_notification_preference()
returns text
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_mode text;
begin
  select profile.company_id, lower(coalesce(profile.role, ''))
  into v_company_id, v_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role <> 'gf' then
    raise exception using errcode = '42501',
      message = 'An active General Foreman profile is required.';
  end if;

  select preference.gf_delivery_mode
  into v_mode
  from public.push_notification_preferences preference
  where preference.company_id = v_company_id
    and preference.user_id = auth.uid();

  return coalesce(v_mode, 'submitted_and_reminders');
end;
$$;

create or replace function public.linecrew_set_my_gf_notification_preference(p_mode text)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_mode text := lower(btrim(coalesce(p_mode, '')));
begin
  select profile.company_id, lower(coalesce(profile.role, ''))
  into v_company_id, v_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role <> 'gf' then
    raise exception using errcode = '42501',
      message = 'An active General Foreman profile is required.';
  end if;

  if v_mode not in ('submitted_only', 'submitted_and_reminders') then
    raise exception using errcode = '22023',
      message = 'Choose Submitted only or Submitted + reminders.';
  end if;

  insert into public.push_notification_preferences (
    company_id, user_id, gf_delivery_mode, updated_at
  ) values (
    v_company_id, auth.uid(), v_mode, now()
  )
  on conflict (company_id, user_id) do update set
    gf_delivery_mode = excluded.gf_delivery_mode,
    updated_at = now();

  return v_mode;
end;
$$;

create or replace function public.set_company_notification_reminder_times(
  p_daily_report_reminder_time time,
  p_jsa_reminder_time time
)
returns table (daily_report_reminder_time time, jsa_reminder_time time)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select profile.company_id, lower(coalesce(profile.role, ''))
  into v_company_id, v_role
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role not in ('owner', 'admin') then
    raise exception using errcode = '42501',
      message = 'Only an active Owner or Admin can change reminder times.';
  end if;

  update public.companies company
  set daily_report_reminder_time = p_daily_report_reminder_time,
      jsa_reminder_time = p_jsa_reminder_time,
      updated_at = now()
  where company.id = v_company_id;

  return query
  select company.daily_report_reminder_time, company.jsa_reminder_time
  from public.companies company
  where company.id = v_company_id;
end;
$$;

create or replace function public.linecrew_enqueue_push_notification(
  p_company_id uuid,
  p_recipient_id uuid,
  p_event_key text,
  p_event_type text,
  p_subject_id uuid,
  p_body text,
  p_url text,
  p_tag text
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if p_company_id is null or p_recipient_id is null
     or nullif(btrim(coalesce(p_event_key, '')), '') is null then
    return;
  end if;

  if not exists (
    select 1
    from public.profiles profile
    where profile.id = p_recipient_id
      and profile.company_id = p_company_id
      and profile.active is true
  ) then
    return;
  end if;

  insert into public.push_notification_outbox (
    company_id, recipient_id, event_key, event_type, subject_id,
    title, body, url, tag
  ) values (
    p_company_id, p_recipient_id, left(p_event_key, 300), left(p_event_type, 80),
    p_subject_id, 'LineCrew Pro', left(p_body, 240),
    case when p_url like '/%' and p_url not like '//%' then left(p_url, 500) else '/' end,
    left(p_tag, 120)
  )
  on conflict (event_key) do nothing;
end;
$$;

create or replace function public.linecrew_queue_daily_report_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_gf record;
begin
  if old.status is distinct from new.status and new.status = 'submitted' then
    for v_gf in
      select assignment.gf_id
      from public.gf_foreman_assignments assignment
      join public.profiles profile
        on profile.id = assignment.gf_id
       and profile.company_id = assignment.company_id
       and profile.active is true
       and lower(coalesce(profile.role, '')) = 'gf'
      where assignment.company_id = new.company_id
        and assignment.foreman_id = new.foreman_id
    loop
      perform public.linecrew_enqueue_push_notification(
        new.company_id,
        v_gf.gf_id,
        'daily-report-submitted:' || new.id::text || ':' || v_gf.gf_id::text,
        'daily_report_submitted',
        new.id,
        'A Daily Report is ready for review',
        '/?notification=production-review',
        'daily-report-submitted-' || new.id::text
      );
    end loop;
  elsif old.status is distinct from new.status and new.status = 'approved' then
    perform public.linecrew_enqueue_push_notification(
      new.company_id,
      new.foreman_id,
      'daily-report-approved:' || new.id::text || ':' || new.foreman_id::text,
      'daily_report_approved',
      new.id,
      'Your Daily Report was approved',
      '/?notification=my-reports',
      'daily-report-approved-' || new.id::text
    );
  elsif old.status in ('submitted', 'approved') and new.status = 'draft' then
    perform public.linecrew_enqueue_push_notification(
      new.company_id,
      new.foreman_id,
      'daily-report-returned:' || new.id::text || ':' || new.foreman_id::text,
      'daily_report_returned',
      new.id,
      'Your Daily Report was returned - tap to see why',
      '/?notification=my-reports',
      'daily-report-returned-' || new.id::text
    );
  end if;

  return new;
end;
$$;

create or replace function public.linecrew_queue_completed_jsa_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_gf record;
begin
  if new.foreman_acknowledged is true
     and (tg_op = 'INSERT' or old.foreman_acknowledged is distinct from true) then
    for v_gf in
      select assignment.gf_id
      from public.gf_foreman_assignments assignment
      join public.profiles profile
        on profile.id = assignment.gf_id
       and profile.company_id = assignment.company_id
       and profile.active is true
       and lower(coalesce(profile.role, '')) = 'gf'
      where assignment.company_id = new.company_id
        and assignment.foreman_id = new.created_by
    loop
      perform public.linecrew_enqueue_push_notification(
        new.company_id,
        v_gf.gf_id,
        'jsa-completed:' || new.id::text || ':' || v_gf.gf_id::text,
        'jsa_completed',
        new.id,
        'A crew JSA was completed',
        '/?notification=safety',
        'jsa-completed-' || new.id::text
      );
    end loop;
  end if;

  return new;
end;
$$;

create or replace function public.linecrew_queue_uploaded_jsa_push()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_jsa public.daily_report_jsas%rowtype;
  v_gf record;
begin
  select safety.* into v_jsa
  from public.daily_report_jsas safety
  where safety.id = new.jsa_id
    and safety.company_id = new.company_id
    and safety.jsa_source = 'upload';

  if v_jsa.id is null then
    return new;
  end if;

  for v_gf in
    select assignment.gf_id
    from public.gf_foreman_assignments assignment
    join public.profiles profile
      on profile.id = assignment.gf_id
     and profile.company_id = assignment.company_id
     and profile.active is true
     and lower(coalesce(profile.role, '')) = 'gf'
    where assignment.company_id = v_jsa.company_id
      and assignment.foreman_id = v_jsa.created_by
  loop
    perform public.linecrew_enqueue_push_notification(
      v_jsa.company_id,
      v_gf.gf_id,
      'jsa-completed:' || v_jsa.id::text || ':' || v_gf.gf_id::text,
      'jsa_completed',
      v_jsa.id,
      'A crew JSA was completed',
      '/?notification=safety',
      'jsa-completed-' || v_jsa.id::text
    );
  end loop;

  return new;
end;
$$;

create or replace function public.linecrew_enqueue_due_push_reminders()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company record;
  v_foreman record;
  v_gf record;
  v_local_date date;
  v_count_before bigint;
  v_count_after bigint;
begin
  select count(*) into v_count_before from public.push_notification_outbox;

  -- One reminder per report/GF after 48 hours. Admins are intentionally not
  -- included in individual alerts; each assigned GF controls reminder delivery.
  for v_gf in
    select report.company_id, report.id as report_id, assignment.gf_id as id
    from public.daily_reports report
    join public.gf_foreman_assignments assignment
      on assignment.company_id = report.company_id
     and assignment.foreman_id = report.foreman_id
    join public.profiles gf
      on gf.id = assignment.gf_id
     and gf.company_id = assignment.company_id
     and gf.active is true
     and lower(coalesce(gf.role, '')) = 'gf'
    where report.status = 'submitted'
      and report.archived is not true
      and report.submitted_at <= now() - interval '48 hours'
      and coalesce((
        select preference.gf_delivery_mode
        from public.push_notification_preferences preference
        where preference.company_id = gf.company_id
          and preference.user_id = gf.id
      ), 'submitted_and_reminders') = 'submitted_and_reminders'
  loop
    perform public.linecrew_enqueue_push_notification(
      v_gf.company_id, v_gf.id,
      'daily-report-waiting-48h:' || v_gf.report_id::text || ':' || v_gf.id::text,
      'daily_report_waiting_48h', v_gf.report_id,
      'A Daily Report has been waiting 2 days',
      '/?notification=production-review',
      'daily-report-waiting-' || v_gf.report_id::text
    );
  end loop;

  for v_company in
    select company.id, company.timezone, company.jsa_method,
           company.daily_report_reminder_time, company.jsa_reminder_time
    from public.companies company
    where company.active is true
  loop
    v_local_date := (now() at time zone v_company.timezone)::date;

    if v_company.daily_report_reminder_time is not null
       and date_trunc('hour', now() at time zone v_company.timezone) =
           date_trunc('hour', v_local_date + v_company.daily_report_reminder_time) then
      for v_foreman in
        select distinct profile.id
        from public.profiles profile
        join public.job_leader_assignments assignment
          on assignment.company_id = profile.company_id
         and assignment.member_id = profile.id
        join public.jobs job
          on job.id = assignment.job_id
         and job.company_id = assignment.company_id
         and job.active is true
        where profile.company_id = v_company.id
          and profile.active is true
          and lower(coalesce(profile.role, '')) = 'foreman'
          and not exists (
            select 1 from public.daily_reports report
            where report.company_id = v_company.id
              and report.foreman_id = profile.id
              and coalesce(report.work_date, report.report_date) = v_local_date
              and report.status in ('submitted', 'approved')
              and report.archived is not true
          )
      loop
        perform public.linecrew_enqueue_push_notification(
          v_company.id, v_foreman.id,
          'daily-report-missing:' || v_company.id::text || ':' || v_foreman.id::text || ':' || v_local_date::text,
          'daily_report_missing', null,
          'Today''s Daily Report has not been submitted',
          '/?notification=my-reports',
          'daily-report-missing-' || v_local_date::text
        );
      end loop;
    end if;

    if v_company.jsa_reminder_time is not null
       and date_trunc('hour', now() at time zone v_company.timezone) =
           date_trunc('hour', v_local_date + v_company.jsa_reminder_time) then
      for v_foreman in
        select distinct profile.id
        from public.profiles profile
        join public.job_leader_assignments assignment
          on assignment.company_id = profile.company_id
         and assignment.member_id = profile.id
        join public.jobs job
          on job.id = assignment.job_id
         and job.company_id = assignment.company_id
         and job.active is true
        where profile.company_id = v_company.id
          and profile.active is true
          and lower(coalesce(profile.role, '')) = 'foreman'
          and not exists (
            select 1
            from public.daily_report_jsas safety
            where safety.company_id = v_company.id
              and safety.created_by = profile.id
              and safety.work_date = v_local_date
              and (
                (safety.jsa_source = 'digital' and safety.foreman_acknowledged is true)
                or (safety.jsa_source = 'upload' and exists (
                  select 1 from public.jsa_upload_attachments attachment
                  where attachment.company_id = safety.company_id
                    and attachment.jsa_id = safety.id
                ))
              )
          )
      loop
        perform public.linecrew_enqueue_push_notification(
          v_company.id, v_foreman.id,
          'jsa-missing:' || v_company.id::text || ':' || v_foreman.id::text || ':' || v_local_date::text,
          'jsa_missing', null,
          case when v_company.jsa_method = 'upload'
            then 'Today''s JSA has not been uploaded'
            else 'Today''s JSA has not been completed'
          end,
          '/?notification=new-jsa',
          'jsa-missing-' || v_local_date::text
        );
      end loop;

      for v_gf in
        select distinct gf.id
        from public.profiles gf
        join public.gf_foreman_assignments assignment
          on assignment.company_id = gf.company_id
         and assignment.gf_id = gf.id
        join public.profiles foreman
          on foreman.id = assignment.foreman_id
         and foreman.company_id = assignment.company_id
         and foreman.active is true
        join public.daily_reports report
          on report.company_id = assignment.company_id
         and report.foreman_id = assignment.foreman_id
         and coalesce(report.work_date, report.report_date) = v_local_date
         and report.archived is not true
        where gf.company_id = v_company.id
          and gf.active is true
          and lower(coalesce(gf.role, '')) = 'gf'
          and coalesce((
            select preference.gf_delivery_mode
            from public.push_notification_preferences preference
            where preference.company_id = gf.company_id
              and preference.user_id = gf.id
          ), 'submitted_and_reminders') = 'submitted_and_reminders'
          and not exists (
            select 1
            from public.daily_report_jsas safety
            where safety.company_id = v_company.id
              and safety.created_by = foreman.id
              and safety.work_date = v_local_date
              and (
                (safety.jsa_source = 'digital' and safety.foreman_acknowledged is true)
                or (safety.jsa_source = 'upload' and exists (
                  select 1 from public.jsa_upload_attachments attachment
                  where attachment.company_id = safety.company_id
                    and attachment.jsa_id = safety.id
                ))
              )
          )
      loop
        perform public.linecrew_enqueue_push_notification(
          v_company.id, v_gf.id,
          'gf-jsa-missing-summary:' || v_company.id::text || ':' || v_gf.id::text || ':' || v_local_date::text,
          'gf_jsa_missing_summary', null,
          'A crew has no signed JSA for today',
          '/?notification=safety',
          'gf-jsa-missing-summary-' || v_local_date::text
        );
      end loop;
    end if;
  end loop;

  select count(*) into v_count_after from public.push_notification_outbox;
  return (v_count_after - v_count_before)::integer;
end;
$$;

drop trigger if exists linecrew_daily_report_push on public.daily_reports;
create trigger linecrew_daily_report_push
after update of status on public.daily_reports
for each row execute function public.linecrew_queue_daily_report_push();

drop trigger if exists linecrew_completed_jsa_push on public.daily_report_jsas;
create trigger linecrew_completed_jsa_push
after insert or update of foreman_acknowledged on public.daily_report_jsas
for each row execute function public.linecrew_queue_completed_jsa_push();

drop trigger if exists linecrew_uploaded_jsa_push on public.jsa_upload_attachments;
create trigger linecrew_uploaded_jsa_push
after insert on public.jsa_upload_attachments
for each row execute function public.linecrew_queue_uploaded_jsa_push();

revoke all on function public.linecrew_my_gf_notification_preference() from public, anon;
revoke all on function public.linecrew_set_my_gf_notification_preference(text) from public, anon;
revoke all on function public.set_company_notification_reminder_times(time, time) from public, anon;
grant execute on function public.linecrew_my_gf_notification_preference() to authenticated;
grant execute on function public.linecrew_set_my_gf_notification_preference(text) to authenticated;
grant execute on function public.set_company_notification_reminder_times(time, time) to authenticated;

revoke all on function public.linecrew_enqueue_push_notification(uuid, uuid, text, text, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.linecrew_queue_daily_report_push() from public, anon, authenticated;
revoke all on function public.linecrew_queue_completed_jsa_push() from public, anon, authenticated;
revoke all on function public.linecrew_queue_uploaded_jsa_push() from public, anon, authenticated;
revoke all on function public.linecrew_enqueue_due_push_reminders() from public, anon, authenticated;
grant execute on function public.linecrew_enqueue_due_push_reminders() to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'linecrew-push-dispatch') then
    perform cron.unschedule('linecrew-push-dispatch');
  end if;
end;
$$;

select cron.schedule(
  'linecrew-push-dispatch',
  '* * * * *',
  $cron$
    select net.http_post(
      url := 'https://ldgkyxuozbozgkvwzadg.supabase.co/functions/v1/send-push-notification',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-push-cron-secret', coalesce((
          select secret.decrypted_secret
          from vault.decrypted_secrets secret
          where secret.name = 'linecrew_push_cron_secret'
          limit 1
        ), '')
      ),
      body := '{"mode":"notify","dispatch_queued":true}'::jsonb,
      timeout_milliseconds := 10000
    );
  $cron$
);
