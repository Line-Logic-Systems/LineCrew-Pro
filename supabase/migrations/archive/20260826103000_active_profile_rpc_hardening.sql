-- Close legacy SECURITY DEFINER paths that read profiles directly instead of
-- going through my_role()/my_company_id(), both of which already enforce active=true.

create or replace function public.delete_daily_report_attachment(p_attachment_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_attachment public.daily_report_attachments%rowtype;
begin
  select * into v_profile
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  if v_profile.id is null then
    raise exception using errcode='42501', message='An active company profile is required.';
  end if;

  if lower(coalesce(v_profile.role,'')) = 'superintendent'
     and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501', message='This Superintendent does not have production review permission.';
  end if;

  select * into v_attachment
  from public.daily_report_attachments attachment
  where attachment.id = p_attachment_id
    and attachment.company_id = v_profile.company_id;

  if v_attachment.id is null then
    raise exception using errcode='P0002', message='Attachment not found for your company.';
  end if;

  if v_attachment.uploaded_by <> auth.uid()
     and lower(coalesce(v_profile.role,'')) not in ('admin','gf','owner','superintendent') then
    raise exception using errcode='42501', message='Only the uploader or company leadership may delete this attachment.';
  end if;

  delete from public.daily_report_attachments where id = v_attachment.id;
  return v_attachment.storage_path;
end;
$$;

create or replace function public.set_company_storm_mode(p_enabled boolean, p_event_name text default null)
returns table(storm_mode_enabled boolean, storm_event_name text, storm_started_at timestamptz, storm_ended_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501', message='An active company Admin, Owner, or permitted Superintendent is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('storm_mode') then
    raise exception using errcode='42501', message='This Superintendent does not have storm mode permission.';
  end if;

  if coalesce(p_enabled,false) and length(trim(coalesce(p_event_name,''))) = 0 then
    raise exception using errcode='22023', message='A storm or event name is required when Storm Mode is enabled.';
  end if;

  update public.companies c
  set storm_mode_enabled = coalesce(p_enabled,false),
      storm_event_name = case when coalesce(p_enabled,false) then trim(p_event_name) else null end,
      storm_started_at = case
        when coalesce(p_enabled,false) and not c.storm_mode_enabled then now()
        when coalesce(p_enabled,false) then c.storm_started_at
        else c.storm_started_at end,
      storm_ended_at = case
        when not coalesce(p_enabled,false) and c.storm_mode_enabled then now()
        when coalesce(p_enabled,false) then null
        else c.storm_ended_at end
  where c.id = v_company_id;

  return query
  select c.storm_mode_enabled,c.storm_event_name,c.storm_started_at,c.storm_ended_at
  from public.companies c where c.id = v_company_id;
end;
$$;

create or replace function public.update_company_settings(
  p_name text,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_logo_url text default null,
  p_primary_color text default '#0b2d4d',
  p_timezone text default 'America/Chicago'
)
returns table(id uuid, name text, contact_email text, contact_phone text, logo_url text, primary_color text, timezone text, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_name text := trim(coalesce(p_name,''));
  v_email text := nullif(trim(coalesce(p_contact_email,'')),'');
  v_phone text := nullif(trim(coalesce(p_contact_phone,'')),'');
  v_logo text := nullif(trim(coalesce(p_logo_url,'')),'');
  v_color text := lower(trim(coalesce(p_primary_color,'')));
  v_timezone text := trim(coalesce(p_timezone,''));
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501', message='An active company Admin, Owner, or permitted Superintendent is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('company_settings') then
    raise exception using errcode='42501', message='This Superintendent does not have company settings permission.';
  end if;

  if length(v_name) < 2 or length(v_name) > 120 then raise exception 'Company name must be between 2 and 120 characters.'; end if;
  if v_email is not null and (length(v_email) > 254 or position('@' in v_email) < 2) then raise exception 'Enter a valid company email address.'; end if;
  if v_phone is not null and length(v_phone) > 40 then raise exception 'Company phone must be 40 characters or fewer.'; end if;
  if v_logo is not null and (length(v_logo) > 1000 or v_logo !~* '^https://') then raise exception 'Logo URL must be a secure https:// address.'; end if;
  if v_color !~ '^#[0-9a-f]{6}$' then raise exception 'Brand color must use the format #0b2d4d.'; end if;
  if v_timezone not in ('America/Chicago','America/New_York','America/Denver','America/Los_Angeles','America/Anchorage','Pacific/Honolulu') then raise exception 'Unsupported company time zone.'; end if;

  return query
  update public.companies company
  set name=v_name,contact_email=v_email,contact_phone=v_phone,logo_url=v_logo,primary_color=v_color,timezone=v_timezone,updated_at=now()
  where company.id=v_company_id
  returning company.id,company.name,company.contact_email,company.contact_phone,company.logo_url,company.primary_color,company.timezone,company.updated_at;
end;
$$;

revoke all on function public.delete_daily_report_attachment(uuid) from public, anon;
grant execute on function public.delete_daily_report_attachment(uuid) to authenticated, service_role;
revoke all on function public.set_company_storm_mode(boolean,text) from public, anon;
grant execute on function public.set_company_storm_mode(boolean,text) to authenticated, service_role;
revoke all on function public.update_company_settings(text,text,text,text,text,text) from public, anon;
grant execute on function public.update_company_settings(text,text,text,text,text,text) to authenticated, service_role;
