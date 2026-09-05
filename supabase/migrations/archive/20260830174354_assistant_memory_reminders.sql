begin;

-- Assistant memories are deliberately separate from operational records.
-- The browser may only request narrowly validated mutations through the RPCs
-- below, after an Owner/Admin explicitly confirms the assistant's proposal.
create table public.assistant_memories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete cascade,
  memory_type text not null check (memory_type in ('company_workflow', 'job_reminder')),
  title text not null check (char_length(title) between 1 and 160),
  instruction text not null check (char_length(instruction) between 1 and 800),
  trigger_type text not null check (
    trigger_type in ('always', 'job_open', 'production_review', 'final_billing', 'timekeeping', 'billing', 'manual')
  ),
  active boolean not null default true,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_by uuid references public.profiles(id) on delete restrict,
  completed_at timestamptz,
  removed_by uuid references public.profiles(id) on delete restrict,
  removed_at timestamptz,
  constraint assistant_memory_job_scope check (
    (memory_type = 'job_reminder' and job_id is not null) or
    (memory_type = 'company_workflow' and job_id is null)
  ),
  constraint assistant_memory_terminal_state check (
    not (completed_at is not null and removed_at is not null)
  )
);

comment on table public.assistant_memories is
  'Owner/Admin-confirmed workflow notes and advisory job reminders; never operational job, report, timekeeping, or billing mutations.';

create index assistant_memories_company_active_trigger_idx
  on public.assistant_memories (company_id, active, trigger_type, created_at desc);
create index assistant_memories_job_active_idx
  on public.assistant_memories (job_id, active, created_at desc)
  where job_id is not null;

alter table public.assistant_memories enable row level security;

revoke all on table public.assistant_memories from public, anon, authenticated;
grant select on table public.assistant_memories to authenticated;

create policy assistant_memories_owner_admin_select
on public.assistant_memories
for select
to authenticated
using (
  exists (
    select 1
    from public.profiles profile
    where profile.id = (select auth.uid())
      and profile.company_id = assistant_memories.company_id
      and profile.active is true
      and lower(coalesce(profile.role, '')) in ('owner', 'admin')
  )
);

create or replace function public.create_assistant_memory(
  p_memory_type text,
  p_title text,
  p_instruction text,
  p_trigger_type text,
  p_job_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_company uuid;
  v_role text;
  v_active boolean;
  v_memory_type text := lower(btrim(coalesce(p_memory_type, '')));
  v_title text := btrim(coalesce(p_title, ''));
  v_instruction text := btrim(coalesce(p_instruction, ''));
  v_trigger_type text := lower(btrim(coalesce(p_trigger_type, '')));
  v_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
    into v_company, v_role, v_active
  from public.profiles profile
  where profile.id = v_actor;

  if v_actor is null or v_company is null or v_active is not true or
     v_role not in ('owner', 'admin') then
    raise exception using errcode = '42501',
      message = 'Only an active Owner or Admin can save Assistant Memory.';
  end if;

  if v_memory_type not in ('company_workflow', 'job_reminder') then
    raise exception using errcode = '22023', message = 'Invalid Assistant Memory type.';
  end if;
  if v_trigger_type not in ('always', 'job_open', 'production_review', 'final_billing', 'timekeeping', 'billing', 'manual') then
    raise exception using errcode = '22023', message = 'Invalid Assistant Memory trigger.';
  end if;
  if char_length(v_title) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'Memory title must be 1 to 160 characters.';
  end if;
  if char_length(v_instruction) not between 1 and 800 then
    raise exception using errcode = '22023', message = 'Memory instruction must be 1 to 800 characters.';
  end if;

  if v_memory_type = 'job_reminder' then
    if p_job_id is null or not exists (
      select 1 from public.jobs job
      where job.id = p_job_id and job.company_id = v_company
    ) then
      raise exception using errcode = '22023',
        message = 'Select a job from your company for this reminder.';
    end if;
  elsif p_job_id is not null then
    raise exception using errcode = '22023',
      message = 'Company workflow memories cannot be attached to a job.';
  end if;

  insert into public.assistant_memories (
    company_id, job_id, memory_type, title, instruction, trigger_type, created_by
  ) values (
    v_company, p_job_id, v_memory_type, v_title, v_instruction, v_trigger_type, v_actor
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.complete_assistant_memory(p_memory_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_company uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
    into v_company, v_role, v_active
  from public.profiles profile
  where profile.id = v_actor;

  if v_actor is null or v_company is null or v_active is not true or
     v_role not in ('owner', 'admin') then
    raise exception using errcode = '42501',
      message = 'Only an active Owner or Admin can complete Assistant Memory reminders.';
  end if;

  update public.assistant_memories memory
  set active = false,
      completed_by = v_actor,
      completed_at = now(),
      updated_at = now()
  where memory.id = p_memory_id
    and memory.company_id = v_company
    and memory.memory_type = 'job_reminder'
    and memory.active is true;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Active job reminder was not found.';
  end if;
end;
$$;

create or replace function public.remove_assistant_memory(p_memory_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_company uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
    into v_company, v_role, v_active
  from public.profiles profile
  where profile.id = v_actor;

  if v_actor is null or v_company is null or v_active is not true or
     v_role not in ('owner', 'admin') then
    raise exception using errcode = '42501',
      message = 'Only an active Owner or Admin can remove Assistant Memory.';
  end if;

  update public.assistant_memories memory
  set active = false,
      removed_by = v_actor,
      removed_at = now(),
      updated_at = now()
  where memory.id = p_memory_id
    and memory.company_id = v_company
    and memory.active is true;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Active Assistant Memory was not found.';
  end if;
end;
$$;

revoke all on function public.create_assistant_memory(text, text, text, text, uuid)
  from public, anon, authenticated;
revoke all on function public.complete_assistant_memory(uuid)
  from public, anon, authenticated;
revoke all on function public.remove_assistant_memory(uuid)
  from public, anon, authenticated;

grant execute on function public.create_assistant_memory(text, text, text, text, uuid)
  to authenticated;
grant execute on function public.complete_assistant_memory(uuid)
  to authenticated;
grant execute on function public.remove_assistant_memory(uuid)
  to authenticated;

commit;
