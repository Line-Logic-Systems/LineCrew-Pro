begin;

alter table public.companies
  add column if not exists contact_email text,
  add column if not exists contact_phone text,
  add column if not exists logo_url text,
  add column if not exists primary_color text not null default '#0b2d4d',
  add column if not exists timezone text not null default 'America/Chicago',
  add column if not exists updated_at timestamptz not null default now();

alter table public.companies
  drop constraint if exists companies_primary_color_format;

alter table public.companies
  add constraint companies_primary_color_format
  check (primary_color ~ '^#[0-9A-Fa-f]{6}$');

create or replace function public.update_company_settings(
  p_name text,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_logo_url text default null,
  p_primary_color text default '#0b2d4d',
  p_timezone text default 'America/Chicago'
)
returns table(
  id uuid,
  name text,
  contact_email text,
  contact_phone text,
  logo_url text,
  primary_color text,
  timezone text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_role text;
  v_name text := trim(coalesce(p_name, ''));
  v_email text := nullif(trim(coalesce(p_contact_email, '')), '');
  v_phone text := nullif(trim(coalesce(p_contact_phone, '')), '');
  v_logo text := nullif(trim(coalesce(p_logo_url, '')), '');
  v_color text := lower(trim(coalesce(p_primary_color, '')));
  v_timezone text := trim(coalesce(p_timezone, ''));
begin
  if auth.uid() is null then
    raise exception 'Authentication required.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, ''))
    into v_company_id, v_role
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_role <> 'admin' then
    raise exception 'Only a company Admin can update company settings.';
  end if;

  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'Company name must be between 2 and 120 characters.';
  end if;

  if v_email is not null and
     (length(v_email) > 254 or position('@' in v_email) < 2) then
    raise exception 'Enter a valid company email address.';
  end if;

  if v_phone is not null and length(v_phone) > 40 then
    raise exception 'Company phone must be 40 characters or fewer.';
  end if;

  if v_logo is not null and
     (length(v_logo) > 1000 or v_logo !~* '^https://') then
    raise exception 'Logo URL must be a secure https:// address.';
  end if;

  if v_color !~ '^#[0-9a-f]{6}$' then
    raise exception 'Brand color must use the format #0b2d4d.';
  end if;

  if v_timezone not in (
    'America/Chicago',
    'America/New_York',
    'America/Denver',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu'
  ) then
    raise exception 'Unsupported company time zone.';
  end if;

  return query
  update public.companies company
  set
    name = v_name,
    contact_email = v_email,
    contact_phone = v_phone,
    logo_url = v_logo,
    primary_color = v_color,
    timezone = v_timezone,
    updated_at = now()
  where company.id = v_company_id
  returning
    company.id,
    company.name,
    company.contact_email,
    company.contact_phone,
    company.logo_url,
    company.primary_color,
    company.timezone,
    company.updated_at;
end;
$$;

revoke all on function public.update_company_settings(
  text, text, text, text, text, text
) from public, anon;
grant execute on function public.update_company_settings(
  text, text, text, text, text, text
) to authenticated;

commit;
