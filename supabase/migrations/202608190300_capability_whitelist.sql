-- Harden capability checks so misspelled/unknown permissions never default to allowed.
-- Owner/Admin keep full access to known company capabilities. Superintendent
-- keeps the existing default-allow behavior only for recognized capability keys.

create or replace function public.linecrew_has_capability(capability text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when capability is null or capability <> any(array[
      'company_settings',
      'team_management',
      'role_management',
      'customers_contracts',
      'price_books',
      'jobs',
      'job_packages',
      'production_review',
      'reporting',
      'storm_mode',
      'safety_records',
      'actual_pricing',
      'exports',
      'ai_assistant'
    ]::text[]) then false
    else coalesce((
      select case
        when lower(p.role) in ('owner','admin') then true
        when lower(p.role) = 'superintendent'
          then coalesce((p.role_permissions ->> capability)::boolean, true)
        else false
      end
      from public.profiles p
      where p.id = auth.uid()
        and p.active is true
    ), false)
  end;
$$;

revoke all on function public.linecrew_has_capability(text) from public;
revoke all on function public.linecrew_has_capability(text) from anon;
grant execute on function public.linecrew_has_capability(text) to authenticated;
