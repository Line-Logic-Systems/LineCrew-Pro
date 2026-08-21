create table if not exists public.pilot_feedback (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  submitted_by uuid not null references auth.users(id) on delete cascade,
  category text not null,
  rating smallint not null,
  message text not null,
  page text not null default 'app',
  contact_ok boolean not null default true,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null,
  constraint pilot_feedback_category_supported
    check (category in ('bug','idea','question','other')),
  constraint pilot_feedback_rating_supported check (rating between 1 and 5),
  constraint pilot_feedback_message_length
    check (char_length(message) between 10 and 2000)
);

create index if not exists pilot_feedback_company_created_idx
  on public.pilot_feedback(company_id, created_at desc);
create index if not exists pilot_feedback_unresolved_idx
  on public.pilot_feedback(created_at desc) where resolved_at is null;

alter table public.pilot_feedback enable row level security;
revoke all on table public.pilot_feedback from public, anon, authenticated;

create or replace function public.submit_pilot_feedback(
  p_category text,
  p_rating integer,
  p_message text,
  p_page text default 'app',
  p_contact_ok boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_company_id uuid;
  v_category text := lower(trim(coalesce(p_category,'')));
  v_message text := trim(coalesce(p_message,''));
  v_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode='42501', message='Sign in before sending feedback.';
  end if;

  select p.company_id into v_company_id
  from public.profiles p
  join public.companies c on c.id=p.company_id
  where p.id=v_user_id and p.active=true and c.active=true
    and c.subscription_status in ('trial','active','internal','past_due');

  if v_company_id is null then
    raise exception using errcode='42501', message='An active company account is required.';
  end if;
  if v_category not in ('bug','idea','question','other') then
    raise exception using errcode='22023', message='Choose a valid feedback category.';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception using errcode='22023', message='Choose a rating from 1 to 5.';
  end if;
  if char_length(v_message) not between 10 and 2000 then
    raise exception using errcode='22023', message='Feedback must be between 10 and 2,000 characters.';
  end if;

  insert into public.pilot_feedback(
    company_id,submitted_by,category,rating,message,page,contact_ok
  ) values (
    v_company_id,v_user_id,v_category,p_rating,v_message,
    left(regexp_replace(coalesce(p_page,'app'),'[^a-zA-Z0-9_./ -]','','g'),100),
    coalesce(p_contact_ok,true)
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.support_list_pilot_feedback(p_limit integer default 100)
returns table(
  id uuid,company_id uuid,company_name text,submitted_by uuid,submitted_name text,
  category text,rating smallint,message text,page text,contact_ok boolean,
  created_at timestamptz,resolved_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_support_user(auth.uid()) then
    raise exception using errcode='42501', message='Platform support access required.';
  end if;
  return query
  select f.id,f.company_id,c.name,f.submitted_by,p.full_name,
    f.category,f.rating,f.message,f.page,f.contact_ok,f.created_at,f.resolved_at
  from public.pilot_feedback f
  join public.companies c on c.id=f.company_id
  join public.profiles p on p.id=f.submitted_by and p.company_id=f.company_id
  order by f.created_at desc
  limit least(greatest(coalesce(p_limit,100),1),250);
end;
$$;

create or replace function public.support_resolve_pilot_feedback(p_feedback_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_company_id uuid;
begin
  if not public.is_platform_support_user(auth.uid()) then
    raise exception using errcode='42501', message='Platform support access required.';
  end if;
  update public.pilot_feedback
  set resolved_at=coalesce(resolved_at,now()),resolved_by=coalesce(resolved_by,auth.uid())
  where id=p_feedback_id
  returning company_id into v_company_id;
  if v_company_id is null then
    raise exception using errcode='P0002', message='Feedback was not found.';
  end if;
  insert into public.support_audit_events(
    company_id,support_user_id,actor_user_id,event_type,metadata
  ) values (
    v_company_id,auth.uid(),auth.uid(),'pilot_feedback_resolved',
    jsonb_build_object('feedback_id',p_feedback_id)
  );
end;
$$;

revoke all on function public.submit_pilot_feedback(text,integer,text,text,boolean) from public, anon;
revoke all on function public.support_list_pilot_feedback(integer) from public, anon;
revoke all on function public.support_resolve_pilot_feedback(uuid) from public, anon;
grant execute on function public.submit_pilot_feedback(text,integer,text,text,boolean) to authenticated;
grant execute on function public.support_list_pilot_feedback(integer) to authenticated;
grant execute on function public.support_resolve_pilot_feedback(uuid) to authenticated;
