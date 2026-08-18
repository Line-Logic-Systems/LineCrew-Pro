


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."add_daily_report_unit"("p_report_id" "uuid", "p_work_point" "text", "p_unit_code" "text", "p_description" "text" DEFAULT NULL::"text", "p_installed_qty" numeric DEFAULT 0, "p_retired_qty" numeric DEFAULT 0, "p_install_unit_price" numeric DEFAULT NULL::numeric, "p_retire_unit_price" numeric DEFAULT NULL::numeric, "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

declare

  v_unit_id uuid;

  v_job_id uuid;

begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;


  select job_id
  into v_job_id
  from public.daily_reports
  where id = p_report_id
    and company_id = public.my_company_id()
    and foreman_id = auth.uid()
    and status in ('draft','rejected');


  if v_job_id is null then

    raise exception
      'Report not found or report can no longer be edited';

  end if;


  if trim(coalesce(p_unit_code,'')) = '' then
    raise exception 'Unit code is required';
  end if;


  if coalesce(p_installed_qty,0) < 0
     or coalesce(p_retired_qty,0) < 0 then

    raise exception
      'Unit quantities cannot be negative';

  end if;


  insert into public.daily_report_units (

    company_id,
    report_id,
    job_id,
    work_point,
    unit_code,
    description,
    installed_qty,
    retired_qty,
    install_unit_price,
    retire_unit_price,
    notes

  )
  values (

    public.my_company_id(),
    p_report_id,
    v_job_id,
    nullif(trim(p_work_point),''),
    trim(p_unit_code),
    nullif(trim(p_description),''),
    coalesce(p_installed_qty,0),
    coalesce(p_retired_qty,0),
    p_install_unit_price,
    p_retire_unit_price,
    nullif(trim(p_notes),'')

  )
  returning id into v_unit_id;


  return v_unit_id;

end;
$$;


ALTER FUNCTION "public"."add_daily_report_unit"("p_report_id" "uuid", "p_work_point" "text", "p_unit_code" "text", "p_description" "text", "p_installed_qty" numeric, "p_retired_qty" numeric, "p_install_unit_price" numeric, "p_retire_unit_price" numeric, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_price_book"("p_name" "text", "p_customer_name" "text", "p_utility_name" "text", "p_effective_date" "date") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can create price books';
  end if;

  insert into public.price_books (
    company_id,
    name,
    customer_name,
    utility_name,
    effective_date,
    active,
    created_by
  )
  values (
    public.my_company_id(),
    trim(p_name),
    nullif(trim(p_customer_name),''),
    nullif(trim(p_utility_name),''),
    p_effective_date,
    true,
    auth.uid()
  )
  returning id into new_id;

  return new_id;
end;
$$;


ALTER FUNCTION "public"."admin_create_price_book"("p_name" "text", "p_customer_name" "text", "p_utility_name" "text", "p_effective_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_price_book"("p_price_book_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can delete price books';
  end if;

  delete from public.unit_prices
  where price_book_id = p_price_book_id
    and company_id = public.my_company_id();

  delete from public.price_books
  where id = p_price_book_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'Price book not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."admin_delete_price_book"("p_price_book_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_unit_price"("p_unit_price_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can delete unit pricing';
  end if;

  delete from public.unit_prices
  where id = p_unit_price_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'Unit price not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."admin_delete_unit_price"("p_unit_price_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_save_unit_price"("p_price_book_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  saved_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can change unit pricing';
  end if;

  if not exists (
    select 1
    from public.price_books
    where id = p_price_book_id
      and company_id = public.my_company_id()
  ) then
    raise exception 'Price book not found';
  end if;

  insert into public.unit_prices (
    company_id,
    price_book_id,
    unit,
    description,
    install,
    remove,
    transfer,
    active
  )
  values (
    public.my_company_id(),
    p_price_book_id,
    upper(trim(p_unit)),
    nullif(trim(p_description),''),
    coalesce(p_install,0),
    coalesce(p_remove,0),
    coalesce(p_transfer,0),
    true
  )
  returning id into saved_id;

  return saved_id;
end;
$$;


ALTER FUNCTION "public"."admin_save_unit_price"("p_price_book_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_company_settings"("p_adjustment_enabled" boolean, "p_adjustment_percent" numeric, "p_adjustment_label" "text", "p_primary_color" "text", "p_secondary_color" "text", "p_logo_url" "text", "p_gf_can_edit_reports" boolean, "p_gf_can_delete_reports" boolean, "p_location_label" "text", "p_job_label" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can change company settings';
  end if;

  if p_adjustment_percent < 0 or p_adjustment_percent > 100 then
    raise exception 'Adjustment percent must be between 0 and 100';
  end if;

  update public.company_settings
  set
    adjustment_enabled = p_adjustment_enabled,
    adjustment_percent = p_adjustment_percent,
    adjustment_label = p_adjustment_label,
    primary_color = p_primary_color,
    secondary_color = p_secondary_color,
    logo_url = p_logo_url,
    gf_can_edit_reports = p_gf_can_edit_reports,
    gf_can_delete_reports = p_gf_can_delete_reports,
    location_label = p_location_label,
    job_label = p_job_label,
    updated_at = now()
  where company_id = public.my_company_id();

  if not found then
    raise exception 'Company settings not found';
  end if;

end;
$$;


ALTER FUNCTION "public"."admin_update_company_settings"("p_adjustment_enabled" boolean, "p_adjustment_percent" numeric, "p_adjustment_label" "text", "p_primary_color" "text", "p_secondary_color" "text", "p_logo_url" "text", "p_gf_can_edit_reports" boolean, "p_gf_can_delete_reports" boolean, "p_location_label" "text", "p_job_label" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_unit_price"("p_unit_price_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric, "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can change unit pricing';
  end if;

  update public.unit_prices
  set
    unit = upper(trim(p_unit)),
    description = nullif(trim(p_description),''),
    install = coalesce(p_install,0),
    remove = coalesce(p_remove,0),
    transfer = coalesce(p_transfer,0),
    active = p_active
  where id = p_unit_price_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'Unit price not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."admin_update_unit_price"("p_unit_price_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric, "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_user"("target_user_id" "uuid", "new_role" "text", "new_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  target_company uuid;
begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can manage users';
  end if;

  if new_role not in ('admin','gf','foreman','employee') then
    raise exception 'Invalid role';
  end if;

  select company_id
  into target_company
  from public.profiles
  where id = target_user_id;

  if target_company is null then
    raise exception 'User not found';
  end if;

  if target_company <> public.my_company_id() then
    raise exception 'Cannot manage users from another company';
  end if;

  if target_user_id = auth.uid()
     and new_active = false then
    raise exception 'You cannot deactivate your own admin account';
  end if;

  update public.profiles
  set
    role = new_role,
    active = new_active
  where id = target_user_id;

end;
$$;


ALTER FUNCTION "public"."admin_update_user"("target_user_id" "uuid", "new_role" "text", "new_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_daily_report"("p_report_id" "uuid", "p_review_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_status text;
  v_require_gf boolean;
  v_redline_count bigint;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can approve reports.';
  end if;

  select report.company_id, lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'submitted' then
    raise exception using errcode = '23514',
      message = 'Only submitted reports can be approved.';
  end if;

  select company.require_gf_redline_approval
  into v_require_gf
  from public.companies company
  where company.id = v_company_id;

  select count(*)
  into v_redline_count
  from public.get_daily_report_unit_locations(p_report_id) location
  where location.authorization_status = 'redline';

  if coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin' and
     nullif(btrim(coalesce(p_review_notes, '')), '') is null then
    raise exception using errcode = '22023',
      message = 'Enter an Admin override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set
    status = 'approved',
    review_notes = nullif(btrim(coalesce(p_review_notes, '')), ''),
    redline_override_by = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then auth.uid() else null end,
    redline_override_reason = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then btrim(p_review_notes) else null end,
    redline_override_at = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then now() else null end
  where report.id = p_report_id
    and report.company_id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."approve_daily_report"("p_report_id" "uuid", "p_review_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_review_daily_reports"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    select exists (
        select 1
        from public.profiles
        where id = auth.uid()
          and company_id = public.my_company_id()
          and lower(role) in ('admin', 'gf')
    );
$$;


ALTER FUNCTION "public"."can_review_daily_reports"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_company"("company_name" "text", "admin_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  new_company_id uuid;
begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if exists (
    select 1 from public.profiles where id = auth.uid()
  ) then
    raise exception 'User already belongs to a company';
  end if;

  insert into public.companies(name, created_by)
  values (company_name, auth.uid())
  returning id into new_company_id;

  insert into public.profiles(
    id,
    company_id,
    full_name,
    role
  )
  values (
    auth.uid(),
    new_company_id,
    admin_name,
    'admin'
  );

  insert into public.company_settings(
    company_id,
    display_name
  )
  values (
    new_company_id,
    company_name
  );

  return new_company_id;

end;
$$;


ALTER FUNCTION "public"."create_company"("company_name" "text", "admin_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_contract_job"("p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
  v_job_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can create jobs.';
  end if;

  if length(trim(coalesce(p_job_number, ''))) = 0 or
     length(trim(coalesce(p_job_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Job number and job name are required.';
  end if;

  select customer.name
  into v_customer_name
  from public.contracts contract
  join public.customers customer
    on customer.id = contract.customer_id
   and customer.company_id = contract.company_id
  where contract.id = p_contract_id
    and contract.company_id = v_company_id
    and contract.active is true;

  if v_customer_name is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active contract was not found in your company.';
  end if;

  insert into public.jobs (
    company_id,
    contract_id,
    job_number,
    job_name,
    customer_name,
    utility_name,
    active
  ) values (
    v_company_id,
    p_contract_id,
    trim(p_job_number),
    trim(p_job_name),
    v_customer_name,
    v_customer_name,
    true
  )
  returning id into v_job_id;

  return v_job_id;
end;
$$;


ALTER FUNCTION "public"."create_contract_job"("p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_daily_report"("p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric DEFAULT 0, "p_overtime_hours" numeric DEFAULT 0, "p_crew_name" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

declare

  v_report_id uuid;

  v_foreman_name text;

begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;


  select full_name
  into v_foreman_name
  from public.profiles
  where id = auth.uid()
    and company_id = public.my_company_id();


  if v_foreman_name is null then
    raise exception 'User profile not found';
  end if;


  if not exists (

    select 1
    from public.jobs
    where id = p_job_id
      and company_id = public.my_company_id()
      and active = true

  ) then

    raise exception 'Active job not found';

  end if;


  insert into public.daily_reports (

    company_id,
    job_id,
    work_date,
    foreman_id,
    foreman_name,
    crew_name,
    regular_hours,
    overtime_hours,
    notes

  )
  values (

    public.my_company_id(),
    p_job_id,
    coalesce(p_work_date,current_date),
    auth.uid(),
    v_foreman_name,
    nullif(trim(p_crew_name),''),
    coalesce(p_regular_hours,0),
    coalesce(p_overtime_hours,0),
    nullif(trim(p_notes),'')

  )
  returning id into v_report_id;


  return v_report_id;

end;
$$;


ALTER FUNCTION "public"."create_daily_report"("p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_job"("p_job_number" "text", "p_job_name" "text", "p_customer_name" "text" DEFAULT NULL::"text", "p_utility_name" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_company_id uuid;
  v_job_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_company_id := public.my_company_id();
  v_role := public.my_role();

  if v_company_id is null then
    raise exception 'You are not assigned to a company';
  end if;

  if v_role not in ('admin', 'gf') then
    raise exception 'Only company admins and GFs can create jobs';
  end if;

  if nullif(trim(p_job_number), '') is null then
    raise exception 'Job number is required';
  end if;

  if nullif(trim(p_job_name), '') is null then
    raise exception 'Job name is required';
  end if;

  insert into public.jobs (
    company_id,
    job_number,
    job_name,
    customer_name,
    utility_name,
    active,
    created_by
  )
  values (
    v_company_id,
    trim(p_job_number),
    trim(p_job_name),
    nullif(trim(p_customer_name), ''),
    nullif(trim(p_utility_name), ''),
    true,
    auth.uid()
  )
  returning id into v_job_id;

  return v_job_id;
end;
$$;


ALTER FUNCTION "public"."create_job"("p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_job_package"("p_job_id" "uuid", "p_package_name" "text", "p_package_number" "text" DEFAULT NULL::"text", "p_received_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_package_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can add utility job packages.';
  end if;

  if length(trim(coalesce(p_package_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Package name is required.';
  end if;

  select job.contract_id
  into v_contract_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'An active job tied to your company contract is required.';
  end if;

  insert into public.job_packages (
    company_id,
    job_id,
    contract_id,
    package_name,
    package_number,
    received_date,
    notes,
    created_by
  ) values (
    v_company_id,
    p_job_id,
    v_contract_id,
    trim(p_package_name),
    nullif(trim(coalesce(p_package_number, '')), ''),
    p_received_date,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  )
  returning id into v_package_id;

  return v_package_id;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'That utility package reference already exists on this job.';
end;
$$;


ALTER FUNCTION "public"."create_job_package"("p_job_id" "uuid", "p_package_name" "text", "p_package_number" "text", "p_received_date" "date", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_job_package_work_point"("p_package_id" "uuid", "p_work_point_code" "text", "p_description" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
  v_work_point_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can add package work points.';
  end if;

  if length(trim(coalesce(p_work_point_code, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'Pole or work-point number is required.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  insert into public.job_package_work_points (
    company_id, job_package_id, job_id, work_point_code, description, created_by
  ) values (
    v_company_id, p_package_id, v_job_id, trim(p_work_point_code),
    nullif(trim(coalesce(p_description, '')), ''), auth.uid()
  )
  returning id into v_work_point_id;

  return v_work_point_id;
exception
  when unique_violation then
    raise exception using errcode = '23505',
      message = 'That pole or work point already exists in this package.';
end;
$$;


ALTER FUNCTION "public"."create_job_package_work_point"("p_package_id" "uuid", "p_work_point_code" "text", "p_description" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_standalone_jsa"("p_job_id" "uuid", "p_work_date" "date", "p_crew_name" "text", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_weather_conditions" "text" DEFAULT NULL::"text", "p_special_equipment" "text" DEFAULT NULL::"text", "p_foreman_acknowledged" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to complete a JSA.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and coalesce(j.active, true) = true
  ) then
    raise exception using errcode = 'P0002',
      message = 'An active job was not found for your company.';
  end if;

  if p_work_date is null
    or length(trim(coalesce(p_crew_name, ''))) = 0
    or length(trim(coalesce(p_job_briefing, ''))) = 0
    or length(trim(coalesce(p_hazards, ''))) = 0
    or length(trim(coalesce(p_controls, ''))) = 0
    or length(trim(coalesce(p_ppe, ''))) = 0
    or length(trim(coalesce(p_emergency_plan, ''))) = 0
    or length(trim(coalesce(p_crew_members, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'All required JSA fields must be completed.';
  end if;

  if not coalesce(p_foreman_acknowledged, false) then
    raise exception using errcode = '22023',
      message = 'The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas (
    company_id,
    daily_report_id,
    job_id,
    created_by,
    work_date,
    crew_name,
    job_briefing,
    hazards,
    controls,
    ppe,
    emergency_plan,
    weather_conditions,
    special_equipment,
    crew_members,
    foreman_acknowledged,
    acknowledged_at,
    updated_at
  ) values (
    v_company_id,
    null,
    p_job_id,
    auth.uid(),
    p_work_date,
    trim(p_crew_name),
    trim(p_job_briefing),
    trim(p_hazards),
    trim(p_controls),
    trim(p_ppe),
    trim(p_emergency_plan),
    nullif(trim(coalesce(p_weather_conditions, '')), ''),
    nullif(trim(coalesce(p_special_equipment, '')), ''),
    trim(p_crew_members),
    true,
    now(),
    now()
  )
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$$;


ALTER FUNCTION "public"."create_standalone_jsa"("p_job_id" "uuid", "p_work_date" "date", "p_crew_name" "text", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_weather_conditions" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_has_active_profile"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and active is true
  );
$$;


ALTER FUNCTION "public"."current_user_has_active_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_daily_report_attachment"("p_attachment_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_profile public.profiles%rowtype;
  v_attachment public.daily_report_attachments%rowtype;
begin
  select * into v_profile
  from public.profiles
  where id = auth.uid();

  select * into v_attachment
  from public.daily_report_attachments attachment
  where attachment.id = p_attachment_id
    and attachment.company_id = v_profile.company_id;

  if v_attachment.id is null then
    raise exception 'Attachment not found for your company.';
  end if;

  if v_attachment.uploaded_by <> auth.uid()
     and lower(coalesce(v_profile.role, '')) not in ('admin','gf') then
    raise exception 'Only the uploader, a General Foreman or an Admin may delete this attachment.';
  end if;

  delete from public.daily_report_attachments
  where id = v_attachment.id;

  return v_attachment.storage_path;
end;
$$;


ALTER FUNCTION "public"."delete_daily_report_attachment"("p_attachment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_daily_report_unit"("p_unit_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;


  delete from public.daily_report_units u

  using public.daily_reports r

  where u.id = p_unit_id

    and u.report_id = r.id

    and u.company_id = public.my_company_id()

    and r.company_id = public.my_company_id()

    and r.foreman_id = auth.uid()

    and r.status in ('draft','rejected');


  if not found then

    raise exception
      'Unit not found or report can no longer be edited';

  end if;

end;
$$;


ALTER FUNCTION "public"."delete_daily_report_unit"("p_unit_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_creator uuid;
  v_report_status text;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select dr.created_by, lower(coalesce(dr.status, 'draft'))
  into v_report_creator, v_report_status
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  delete from public.daily_production_units
  where daily_report_id = p_report_id
    and price_book_item_id = p_price_book_item_id
    and company_id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."delete_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_total_install numeric;
  v_total_retirement numeric;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_creator, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  delete from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id
    and location_line.pole_location_key =
      lower(btrim(coalesce(p_pole_location, '')));

  select
    coalesce(sum(location_line.install_quantity), 0),
    coalesce(sum(location_line.retirement_quantity), 0)
  into v_total_install, v_total_retirement
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id;

  if v_total_install = 0 and v_total_retirement = 0 then
    perform public.delete_daily_report_unit(
      p_report_id,
      p_price_book_item_id
    );
  else
    perform public.save_daily_report_unit(
      p_report_id,
      p_price_book_item_id,
      v_total_install,
      v_total_retirement
    );
  end if;
end;
$$;


ALTER FUNCTION "public"."delete_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_draft_daily_report"("p_report_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete draft daily reports.';
  end if;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft';

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Draft report was not found in your company. Submitted and approved reports must be archived.';
  end if;
end;
$$;


ALTER FUNCTION "public"."delete_draft_daily_report"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_job"("p_job_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() <> 'admin' then
    raise exception 'Only company admins can delete jobs';
  end if;

  delete from public.jobs
  where id = p_job_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'Job not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."delete_job"("p_job_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_job_package"("p_package_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete utility job packages.';
  end if;

  delete from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;
end;
$$;


ALTER FUNCTION "public"."delete_job_package"("p_package_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_job_package_authorized_unit"("p_authorized_unit_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete authorized units.';
  end if;

  delete from public.job_package_authorized_units authorized
  where authorized.id = p_authorized_unit_id
    and authorized.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Authorized unit was not found in your company.';
  end if;
end;
$$;


ALTER FUNCTION "public"."delete_job_package_authorized_unit"("p_authorized_unit_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_job_package_work_point"("p_work_point_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete package work points.';
  end if;

  if exists (
    select 1
    from public.job_package_authorized_units authorized
    where authorized.work_point_id = p_work_point_id
      and authorized.company_id = v_company_id
  ) then
    raise exception using errcode = '23503',
      message = 'Delete the authorized units from this work point first.';
  end if;

  delete from public.job_package_work_points point
  where point.id = p_work_point_id
    and point.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;
end;
$$;


ALTER FUNCTION "public"."delete_job_package_work_point"("p_work_point_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_assignable_job_leaders"() RETURNS TABLE("member_id" "uuid", "full_name" "text", "member_role" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can manage job leaders.';
  end if;

  return query
  select
    profile.id,
    coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(profile.role, 'foreman'))::text
  from public.profiles profile
  where profile.company_id = v_company_id
    and profile.active is true
    and lower(coalesce(profile.role, 'foreman')) in ('foreman', 'gf')
  order by
    case when lower(coalesce(profile.role, 'foreman')) = 'gf' then 0 else 1 end,
    lower(coalesce(profile.full_name, ''));
end;
$$;


ALTER FUNCTION "public"."get_assignable_job_leaders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_company_jsas"() RETURNS TABLE("id" "uuid", "daily_report_id" "uuid", "job_id" "uuid", "job_number" "text", "job_name" "text", "work_date" "date", "crew_name" "text", "weather_conditions" "text", "job_briefing" "text", "hazards" "text", "controls" "text", "ppe" "text", "emergency_plan" "text", "crew_members" "text", "special_equipment" "text", "foreman_name" "text", "acknowledged_at" timestamp with time zone, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to view JSAs.';
  end if;

  return query
  select
    safety.id,
    safety.daily_report_id,
    safety.job_id,
    job.job_number,
    job.job_name,
    safety.work_date,
    safety.crew_name,
    safety.weather_conditions,
    safety.job_briefing,
    safety.hazards,
    safety.controls,
    safety.ppe,
    safety.emergency_plan,
    safety.crew_members,
    safety.special_equipment,
    coalesce(nullif(trim(profile.full_name), ''), 'Foreman') as foreman_name,
    safety.acknowledged_at,
    safety.created_at
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id = safety.job_id
   and job.company_id = safety.company_id
  left join public.profiles profile
    on profile.id = safety.created_by
   and profile.company_id = safety.company_id
  where safety.company_id = v_company_id
    and (
      v_role in ('gf', 'admin')
      or safety.created_by = auth.uid()
    )
  order by safety.work_date desc, safety.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_company_jsas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_contract_field_settings"() RETURNS TABLE("contract_id" "uuid", "field_value_percent" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or
     v_role <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can view Field Value settings.';
  end if;

  return query
  select s.contract_id, s.field_value_percent
  from public.contract_field_settings s
  where s.company_id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."get_contract_field_settings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_report_audit_history"("p_report_id" "uuid") RETURNS TABLE("event_id" "uuid", "event_type" "text", "actor_name" "text", "actor_role" "text", "event_notes" "text", "event_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."get_daily_report_audit_history"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_report_authorization_summaries"() RETURNS TABLE("report_id" "uuid", "unit_entry_count" bigint, "authorized_count" bigint, "pending_packet_count" bigint, "redline_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view the review queue.';
  end if;

  return query
  select
    report.id,
    count(location.location_line_id),
    count(*) filter (where location.authorization_status = 'authorized'),
    count(*) filter (where location.authorization_status = 'pending_packet'),
    count(*) filter (where location.authorization_status = 'redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations(report.id) location
    on true
  where report.company_id = v_company_id
  group by report.id;
end;
$$;


ALTER FUNCTION "public"."get_daily_report_authorization_summaries"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_report_jsa"("p_report_id" "uuid") RETURNS TABLE("id" "uuid", "daily_report_id" "uuid", "job_briefing" "text", "hazards" "text", "controls" "text", "ppe" "text", "emergency_plan" "text", "crew_members" "text", "special_equipment" "text", "foreman_acknowledged" boolean, "acknowledged_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select j.id, j.daily_report_id, j.job_briefing, j.hazards, j.controls,
         j.ppe, j.emergency_plan, j.crew_members, j.special_equipment,
         j.foreman_acknowledged, j.acknowledged_at, j.updated_at
  from public.daily_report_jsas j
  join public.profiles p
    on p.id = auth.uid()
   and p.company_id = j.company_id
  join public.daily_reports dr
    on dr.id = j.daily_report_id
   and dr.company_id = j.company_id
  where j.daily_report_id = p_report_id
    and (
      lower(coalesce(p.role,'')) in ('admin','gf')
      or dr.created_by = auth.uid()
    );
$$;


ALTER FUNCTION "public"."get_daily_report_jsa"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_report_unit_catalog"("p_report_id" "uuid") RETURNS TABLE("price_book_item_id" "uuid", "item_code" "text", "item_name" "text", "description" "text", "unit_of_measure" "text", "category" "text", "install_price" numeric, "retirement_price" numeric, "actual_install_price" numeric, "actual_retirement_price" numeric, "adjusted_install_price" numeric, "adjusted_retirement_price" numeric, "has_adjustment" boolean, "install_quantity" numeric, "retirement_quantity" numeric, "actual_line_value" numeric, "adjusted_line_value" numeric, "visible_line_value" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_job_id uuid;
  v_contract_id uuid;
  v_price_book_id uuid;
  v_report_creator uuid;
  v_work_date date;
  v_can_see_actual boolean;
  v_percent numeric;
  v_report_has_adjustment boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select dr.company_id, dr.job_id, job.contract_id, dr.price_book_id,
         dr.created_by, dr.work_date, dr.field_value_percent_snapshot,
         dr.has_field_adjustment
  into v_report_company_id, v_job_id, v_contract_id, v_price_book_id,
       v_report_creator, v_work_date, v_percent,
       v_report_has_adjustment
  from public.daily_reports dr
  join public.jobs job
    on job.id = dr.job_id
   and job.company_id = dr.company_id
  where dr.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_contract_id is null then
    raise exception using
      errcode = '22023',
      message = 'Assign this job to a contract before entering units.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  if v_price_book_id is null then
    select pb.id
    into v_price_book_id
    from public.price_books pb
    where pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
      and (pb.active is true or pb.effective_end is not null)
      and (pb.effective_start is null or pb.effective_start <= v_work_date)
      and (pb.effective_end is null or pb.effective_end >= v_work_date)
    order by pb.effective_start desc nulls last, pb.created_at desc
    limit 1;

    if v_price_book_id is null then
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book covers this report date.';
    end if;

    update public.daily_reports
    set price_book_id = v_price_book_id
    where id = p_report_id
      and company_id = v_company_id
      and price_book_id is null;
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = v_price_book_id
      and pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'The report Price Book does not belong to this contract.';
  end if;

  if v_percent is null then
    select setting.field_value_percent
    into v_percent
    from public.contract_field_settings setting
    where setting.contract_id = v_contract_id
      and setting.company_id = v_company_id;

    v_report_has_adjustment := v_percent is not null;
    v_percent := coalesce(v_percent, 100);

    update public.daily_reports
    set
      field_value_percent_snapshot = v_percent,
      has_field_adjustment = v_report_has_adjustment
    where id = p_report_id
      and company_id = v_company_id
      and field_value_percent_snapshot is null;
  end if;

  v_report_has_adjustment := coalesce(v_report_has_adjustment, false);

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    item.id,
    item.item_code,
    item.item_name,
    item.description,
    item.unit_of_measure,
    item.category,
    case
      when v_can_see_actual then coalesce(line.actual_install_price, item.install_price)
      else coalesce(
        line.adjusted_install_price,
        round(item.install_price * v_percent / 100, 2)
      )
    end,
    case
      when v_can_see_actual then coalesce(line.actual_retirement_price, item.retirement_price)
      else coalesce(
        line.adjusted_retirement_price,
        round(item.retirement_price * v_percent / 100, 2)
      )
    end,
    case when v_can_see_actual
      then coalesce(line.actual_install_price, item.install_price)
      else null
    end,
    case when v_can_see_actual
      then coalesce(line.actual_retirement_price, item.retirement_price)
      else null
    end,
    coalesce(
      line.adjusted_install_price,
      round(item.install_price * v_percent / 100, 2)
    ),
    coalesce(
      line.adjusted_retirement_price,
      round(item.retirement_price * v_percent / 100, 2)
    ),
    coalesce(line.has_adjustment, v_report_has_adjustment),
    coalesce(line.install_quantity, 0),
    coalesce(line.retirement_quantity, 0),
    case when v_can_see_actual then
      round(
        coalesce(line.install_quantity, 0) *
          coalesce(line.actual_install_price, item.install_price) +
        coalesce(line.retirement_quantity, 0) *
          coalesce(line.actual_retirement_price, item.retirement_price),
        2
      )
    else null end,
    round(
      coalesce(line.install_quantity, 0) * coalesce(
        line.adjusted_install_price,
        round(item.install_price * v_percent / 100, 2)
      ) +
      coalesce(line.retirement_quantity, 0) * coalesce(
        line.adjusted_retirement_price,
        round(item.retirement_price * v_percent / 100, 2)
      ),
      2
    ),
    case when v_can_see_actual then
      round(
        coalesce(line.install_quantity, 0) *
          coalesce(line.actual_install_price, item.install_price) +
        coalesce(line.retirement_quantity, 0) *
          coalesce(line.actual_retirement_price, item.retirement_price),
        2
      )
    else
      round(
        coalesce(line.install_quantity, 0) * coalesce(
          line.adjusted_install_price,
          round(item.install_price * v_percent / 100, 2)
        ) +
        coalesce(line.retirement_quantity, 0) * coalesce(
          line.adjusted_retirement_price,
          round(item.retirement_price * v_percent / 100, 2)
        ),
        2
      )
    end
  from public.price_book_items item
  left join public.daily_production_units line
    on line.daily_report_id = p_report_id
   and line.price_book_item_id = item.id
   and line.company_id = v_company_id
  where item.price_book_id = v_price_book_id
    and item.company_id = v_company_id
    and (item.active is true or line.id is not null)
  order by item.active desc, item.item_code;
end;
$$;


ALTER FUNCTION "public"."get_daily_report_unit_catalog"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_report_unit_locations"("p_report_id" "uuid") RETURNS TABLE("location_line_id" "uuid", "price_book_item_id" "uuid", "item_code" "text", "item_name" "text", "description" "text", "unit_of_measure" "text", "category" "text", "pole_location" "text", "install_price" numeric, "retirement_price" numeric, "actual_install_price" numeric, "actual_retirement_price" numeric, "adjusted_install_price" numeric, "adjusted_retirement_price" numeric, "has_adjustment" boolean, "install_quantity" numeric, "retirement_quantity" numeric, "actual_line_value" numeric, "adjusted_line_value" numeric, "visible_line_value" numeric, "authorization_status" "text", "authorization_note" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_job_id uuid;
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by, report.job_id
  into v_report_company_id, v_report_creator, v_report_job_id
  from public.daily_reports report where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    location_line.id, aggregate_line.price_book_item_id,
    aggregate_line.item_code, aggregate_line.item_name,
    aggregate_line.description, aggregate_line.unit_of_measure,
    aggregate_line.category, location_line.pole_location,
    case when v_can_see_actual then aggregate_line.actual_install_price
      else aggregate_line.adjusted_install_price end,
    case when v_can_see_actual then aggregate_line.actual_retirement_price
      else aggregate_line.adjusted_retirement_price end,
    case when v_can_see_actual then aggregate_line.actual_install_price else null end,
    case when v_can_see_actual then aggregate_line.actual_retirement_price else null end,
    aggregate_line.adjusted_install_price,
    aggregate_line.adjusted_retirement_price, aggregate_line.has_adjustment,
    location_line.install_quantity, location_line.retirement_quantity,
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price, 2
    ) else null end,
    round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2
    ),
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price, 2
    ) else round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2
    ) end,
    case
      when package_summary.package_count = 0 then 'pending_packet'
      when auth_summary.authorized_unit_count = 0 then 'redline'
      when production.reported_install > auth_summary.authorized_install or
           production.reported_retirement > auth_summary.authorized_retirement
        then 'redline'
      else 'authorized'
    end,
    case
      when package_summary.package_count = 0
        then 'No utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when auth_summary.authorized_unit_count = 0
        then 'This unit is not authorized at this pole or work point in the utility job packet.'
      when production.reported_install > auth_summary.authorized_install or
           production.reported_retirement > auth_summary.authorized_retirement
        then 'Reported quantity exceeds the utility-authorized quantity at this pole or work point.'
      else null
    end
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
   and aggregate_line.price_book_item_id = location_line.price_book_item_id
  cross join lateral (
    select count(*)::integer as package_count
    from public.job_packages package
    where package.company_id = v_company_id and package.job_id = v_report_job_id
  ) package_summary
  cross join lateral (
    select count(authorized.id)::integer as authorized_unit_count,
      coalesce(sum(authorized.authorized_install_quantity), 0) as authorized_install,
      coalesce(sum(authorized.authorized_retirement_quantity), 0) as authorized_retirement
    from public.job_packages package
    join public.job_package_work_points point
      on point.job_package_id = package.id and point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = point.id and authorized.company_id = point.company_id
    where package.company_id = v_company_id and package.job_id = v_report_job_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(location_line.pole_location)
      and authorized.price_book_item_id = location_line.price_book_item_id
  ) auth_summary
  cross join lateral (
    select coalesce(sum(other_location.install_quantity), 0) as reported_install,
      coalesce(sum(other_location.retirement_quantity), 0) as reported_retirement
    from public.daily_production_unit_locations other_location
    join public.daily_reports other_report
      on other_report.id = other_location.daily_report_id
     and other_report.company_id = other_location.company_id
    where other_location.company_id = v_company_id
      and other_report.job_id = v_report_job_id
      and lower(coalesce(other_report.status, '')) <> 'rejected'
      and other_location.price_book_item_id = location_line.price_book_item_id
      and public.normalize_work_point_key(other_location.pole_location) =
          public.normalize_work_point_key(location_line.pole_location)
  ) production
  where location_line.daily_report_id = p_report_id
    and location_line.company_id = v_company_id
  order by location_line.pole_location_key, aggregate_line.item_code;
end;
$$;


ALTER FUNCTION "public"."get_daily_report_unit_locations"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_report_value_summaries"() RETURNS TABLE("report_id" "uuid", "unit_line_count" bigint, "actual_total" numeric, "adjusted_total" numeric, "visible_total" numeric, "has_adjustment" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_can_see_actual boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    dr.id,
    count(line.id),
    case when v_can_see_actual then coalesce(sum(
      line.install_quantity * line.actual_install_price +
      line.retirement_quantity * line.actual_retirement_price
    ), 0) else null end,
    coalesce(sum(
      line.install_quantity * line.adjusted_install_price +
      line.retirement_quantity * line.adjusted_retirement_price
    ), 0),
    case when v_can_see_actual then coalesce(sum(
      line.install_quantity * line.actual_install_price +
      line.retirement_quantity * line.actual_retirement_price
    ), 0) else coalesce(sum(
      line.install_quantity * line.adjusted_install_price +
      line.retirement_quantity * line.adjusted_retirement_price
    ), 0) end,
    coalesce(bool_or(line.has_adjustment), false)
  from public.daily_reports dr
  left join public.daily_production_units line
    on line.daily_report_id = dr.id
   and line.company_id = dr.company_id
  where dr.company_id = v_company_id
    and (v_role in ('admin', 'gf') or dr.created_by = auth.uid())
  group by dr.id;
end;
$$;


ALTER FUNCTION "public"."get_daily_report_value_summaries"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_unit_usage_memory"("p_report_id" "uuid") RETURNS TABLE("item_code" "text", "use_count" bigint, "last_used" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_contract_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by, job.contract_id
  into v_report_company_id, v_report_creator, v_contract_id
  from public.daily_reports report
  join public.jobs job
    on job.id = report.job_id
   and job.company_id = report.company_id
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can access search memory only for their own reports.';
  end if;

  if v_contract_id is null then
    return;
  end if;

  return query
  select
    min(aggregate_line.item_code),
    count(location_line.id),
    max(location_line.updated_at)
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
  join public.daily_reports historical_report
    on historical_report.id = location_line.daily_report_id
   and historical_report.company_id = location_line.company_id
  join public.jobs historical_job
    on historical_job.id = historical_report.job_id
   and historical_job.company_id = historical_report.company_id
  where location_line.company_id = v_company_id
    and location_line.created_by = auth.uid()
    and historical_job.contract_id = v_contract_id
  group by lower(btrim(aggregate_line.item_code));
end;
$$;


ALTER FUNCTION "public"."get_daily_unit_usage_memory"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_job_leader_assignments"() RETURNS TABLE("job_id" "uuid", "member_id" "uuid", "full_name" "text", "member_role" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job leader assignments.';
  end if;

  return query
  select
    assignment.job_id,
    assignment.member_id,
    coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(profile.role, 'foreman'))::text
  from public.job_leader_assignments assignment
  join public.jobs job
    on job.id = assignment.job_id
   and job.company_id = assignment.company_id
  join public.profiles profile
    on profile.id = assignment.member_id
   and profile.company_id = assignment.company_id
  where assignment.company_id = v_company_id
  order by lower(coalesce(profile.full_name, ''));
end;
$$;


ALTER FUNCTION "public"."get_job_leader_assignments"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_job_package_work_points"("p_package_id" "uuid") RETURNS TABLE("work_point_id" "uuid", "work_point_code" "text", "work_point_description" "text", "authorized_unit_id" "uuid", "unit_code" "text", "unit_name" "text", "unit_description" "text", "authorized_install_quantity" numeric, "authorized_retirement_quantity" numeric, "reported_install_quantity" numeric, "reported_retirement_quantity" numeric, "approved_install_quantity" numeric, "approved_retirement_quantity" numeric, "authorized_value" numeric, "reported_value" numeric, "approved_value" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active Admin or General Foreman can view package progress.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select
    point.id,
    point.work_point_code,
    point.description,
    authorized.id,
    authorized.unit_code,
    item.item_name,
    item.description,
    coalesce(authorized.authorized_install_quantity, 0),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(production.reported_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.reported_retirement, authorized.authorized_retirement_quantity) * item.retirement_price,
      0
    ),
    coalesce(
      least(production.approved_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.approved_retirement, authorized.authorized_retirement_quantity) * item.retirement_price,
      0
    )
  from public.job_package_work_points point
  left join public.job_package_authorized_units authorized
    on authorized.work_point_id = point.id
   and authorized.company_id = point.company_id
  left join public.price_book_items item
    on item.id = authorized.price_book_item_id
   and item.company_id = authorized.company_id
  left join lateral (
    select
      coalesce(sum(location.install_quantity), 0) as reported_install,
      coalesce(sum(location.retirement_quantity), 0) as reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) as approved_install,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) as approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
    join public.price_book_items historical_item
      on historical_item.id = location.price_book_item_id
     and historical_item.company_id = location.company_id
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and lower(trim(historical_item.item_code)) = lower(trim(authorized.unit_code))
  ) production on authorized.id is not null
  where point.job_package_id = p_package_id
    and point.company_id = v_company_id
  order by point.work_point_key, authorized.unit_code;
end;
$$;


ALTER FUNCTION "public"."get_job_package_work_points"("p_package_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_job_packages"("p_job_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "job_id" "uuid", "contract_id" "uuid", "package_name" "text", "package_number" "text", "received_date" "date", "source_filename" "text", "notes" "text", "status" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can view utility job packages.';
  end if;

  if p_job_id is not null and not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  return query
  select
    package.id,
    package.job_id,
    package.contract_id,
    package.package_name,
    package.package_number,
    package.received_date,
    package.source_filename,
    package.notes,
    package.status,
    package.created_at,
    package.updated_at
  from public.job_packages package
  where package.company_id = v_company_id
    and (p_job_id is null or package.job_id = p_job_id)
  order by package.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_job_packages"("p_job_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_job_progress_dashboard"() RETURNS TABLE("job_id" "uuid", "package_count" bigint, "work_point_count" bigint, "authorized_value" numeric, "reported_value" numeric, "approved_value" numeric, "remaining_value" numeric, "reported_percent" numeric, "approved_percent" numeric, "report_count" bigint, "redline_count" bigint, "pending_packet_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job progress.';
  end if;

  return query
  with package_totals as (
    select
      package.job_id,
      count(distinct package.id)::bigint as package_count,
      count(distinct progress.work_point_id)::bigint as work_point_count,
      coalesce(sum(progress.authorized_value), 0)::numeric as authorized_value,
      coalesce(sum(progress.reported_value), 0)::numeric as reported_value,
      coalesce(sum(progress.approved_value), 0)::numeric as approved_value
    from public.job_packages package
    left join lateral public.get_job_package_work_points(package.id) progress
      on true
    where package.company_id = v_company_id
    group by package.job_id
  ),
  report_totals as (
    select
      report.job_id,
      count(distinct report.id)::bigint as report_count
    from public.daily_reports report
    where report.company_id = v_company_id
      and report.archived is not true
    group by report.job_id
  ),
  exception_totals as (
    select
      report.job_id,
      count(*) filter (
        where location.authorization_status = 'redline'
      )::bigint as redline_count,
      count(*) filter (
        where location.authorization_status = 'pending_packet'
      )::bigint as pending_packet_count
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations(report.id) location
    where report.company_id = v_company_id
      and report.archived is not true
      and lower(coalesce(report.status, 'draft')) <> 'rejected'
    group by report.job_id
  )
  select
    job.id,
    coalesce(package.package_count, 0),
    coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0),
    coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(coalesce(package.authorized_value, 0) - coalesce(package.reported_value, 0), 0),
    case when coalesce(package.authorized_value, 0) > 0 then
      round(least(package.reported_value / package.authorized_value * 100, 100), 1)
    else 0 end,
    case when coalesce(package.authorized_value, 0) > 0 then
      round(least(package.approved_value / package.authorized_value * 100, 100), 1)
    else 0 end,
    coalesce(report.report_count, 0),
    coalesce(exception.redline_count, 0),
    coalesce(exception.pending_packet_count, 0)
  from public.jobs job
  left join package_totals package on package.job_id = job.id
  left join report_totals report on report.job_id = job.id
  left join exception_totals exception on exception.job_id = job.id
  where job.company_id = v_company_id
  order by job.active desc, job.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_job_progress_dashboard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_price_book_items_for_user"("p_price_book_id" "uuid") RETURNS TABLE("id" "uuid", "company_id" "uuid", "price_book_id" "uuid", "item_code" "text", "item_name" "text", "description" "text", "install_price" numeric, "retirement_price" numeric, "unit_of_measure" "text", "category" "text", "extra_data" "jsonb", "active" boolean, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "actual_install_price" numeric, "actual_retirement_price" numeric, "adjusted_install_price" numeric, "adjusted_retirement_price" numeric, "has_adjustment" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_can_see_actual boolean;
begin
  if p_price_book_id is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book is required.';
  end if;

  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  if v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'Your role cannot view contract unit values.';
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = p_price_book_id
      and pb.company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    i.id,
    i.company_id,
    i.price_book_id,
    i.item_code,
    i.item_name,
    i.description,
    case
      when v_can_see_actual then i.install_price
      else round(
        i.install_price * coalesce(s.field_value_percent, 100) / 100,
        2
      )
    end,
    case
      when v_can_see_actual then i.retirement_price
      else round(
        i.retirement_price * coalesce(s.field_value_percent, 100) / 100,
        2
      )
    end,
    i.unit_of_measure,
    i.category,
    i.extra_data,
    i.active,
    i.created_at,
    i.updated_at,
    case when v_can_see_actual then i.install_price else null end,
    case when v_can_see_actual then i.retirement_price else null end,
    round(
      i.install_price * coalesce(s.field_value_percent, 100) / 100,
      2
    ),
    round(
      i.retirement_price * coalesce(s.field_value_percent, 100) / 100,
      2
    ),
    s.field_value_percent is not null
  from public.price_book_items i
  join public.price_books pb
    on pb.id = i.price_book_id
   and pb.company_id = i.company_id
  left join public.contract_field_settings s
    on s.contract_id = pb.contract_id
   and s.company_id = i.company_id
  where i.price_book_id = p_price_book_id
    and i.company_id = v_company_id
  order by i.active desc, i.item_code asc;
end;
$$;


ALTER FUNCTION "public"."get_price_book_items_for_user"("p_price_book_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_storm_mode_assignments"() RETURNS TABLE("user_id" "uuid", "full_name" "text", "role" "text", "active" boolean, "assigned" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can view Storm Mode crew assignments.';
  end if;

  return query
  select p.id,
         coalesce(nullif(trim(p.full_name), ''), 'Unnamed Team Member'),
         lower(coalesce(p.role, 'foreman')),
         coalesce(p.active, true),
         (a.user_id is not null)
  from public.profiles p
  left join public.storm_mode_assignments a
    on a.company_id = p.company_id
   and a.user_id = p.id
  where p.company_id = v_company_id
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin')
  order by
    case lower(coalesce(p.role, 'foreman'))
      when 'gf' then 1
      when 'foreman' then 2
      else 3
    end,
    lower(coalesce(p.full_name, ''));
end;
$$;


ALTER FUNCTION "public"."get_storm_mode_assignments"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."import_job_package_units"("p_package_id" "uuid", "p_rows" "jsonb", "p_source_filename" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_job_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_description text;
  v_unit_code text;
  v_install numeric;
  v_retirement numeric;
  v_work_point_id uuid;
  v_price_book_item_id uuid;
  v_canonical_unit_code text;
  v_imported integer := 0;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can import utility job packets.';
  end if;

  select package.contract_id, package.job_id
  into v_contract_id, v_job_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'Import rows are required.';
  end if;

  if jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'A maximum of 2,000 consolidated rows can be imported at once.';
  end if;

  -- Validate every row before writing anything. Any exception rolls back the call.
  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := trim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := trim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    if length(v_work_point) = 0 or length(v_unit_code) = 0 or
       v_install < 0 or v_retirement < 0 or v_install + v_retirement <= 0 then
      raise exception using errcode = '22023',
        message = 'Import row ' || v_row_number || ' is incomplete or has an invalid quantity.';
    end if;

    if not exists (
      select 1
      from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id
       and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id
        and book.active is true
        and item.active is true
        and lower(trim(item.item_code)) = lower(v_unit_code)
    ) then
      raise exception using errcode = 'P0002',
        message = 'Import row ' || v_row_number || ': unit ' || v_unit_code ||
          ' was not found in an active Price Book for this contract.';
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_work_point := trim(v_row->>'work_point_code');
    v_description := nullif(trim(coalesce(v_row->>'work_point_description', '')), '');
    v_unit_code := trim(v_row->>'unit_code');
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    select point.id
    into v_work_point_id
    from public.job_package_work_points point
    where point.company_id = v_company_id
      and point.job_package_id = p_package_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(v_work_point)
    order by point.created_at
    limit 1;

    if v_work_point_id is null then
      insert into public.job_package_work_points (
        company_id, job_package_id, job_id, work_point_code, description, created_by
      ) values (
        v_company_id, p_package_id, v_job_id, v_work_point, v_description, auth.uid()
      )
      returning id into v_work_point_id;
    elsif v_description is not null then
      update public.job_package_work_points
      set description = coalesce(description, v_description), updated_at = now()
      where id = v_work_point_id and company_id = v_company_id;
    end if;

    select item.id, item.item_code
    into v_price_book_item_id, v_canonical_unit_code
    from public.price_book_items item
    join public.price_books book
      on book.id = item.price_book_id
     and book.company_id = item.company_id
    where item.company_id = v_company_id
      and book.contract_id = v_contract_id
      and book.active is true
      and item.active is true
      and lower(trim(item.item_code)) = lower(v_unit_code)
    order by book.effective_start desc nulls last, book.updated_at desc nulls last
    limit 1;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_retirement_quantity, created_by
    ) values (
      v_company_id, p_package_id, v_work_point_id, v_price_book_item_id,
      v_canonical_unit_code, v_install, v_retirement, auth.uid()
    )
    on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

    v_imported := v_imported + 1;
  end loop;

  update public.job_packages
  set source_filename = nullif(trim(coalesce(p_source_filename, '')), ''),
      updated_at = now()
  where id = p_package_id and company_id = v_company_id;

  return jsonb_build_object('imported_rows', v_imported);
exception
  when invalid_text_representation then
    raise exception using errcode = '22023',
      message = 'One or more quantities are not valid numbers. Nothing was imported.';
end;
$$;


ALTER FUNCTION "public"."import_job_package_units"("p_package_id" "uuid", "p_rows" "jsonb", "p_source_filename" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_current_user_in_storm_mode"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce((
    select c.storm_mode_enabled
       and exists (
         select 1
         from public.storm_mode_assignments a
         where a.company_id = p.company_id
           and a.user_id = auth.uid()
       )
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and coalesce(p.active, true)
  ), false);
$$;


ALTER FUNCTION "public"."is_current_user_in_storm_mode"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_my_profile_suspended"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and active is false
  );
$$;


ALTER FUNCTION "public"."is_my_profile_suspended"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_company"("company_code" "text", "user_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'Sign in before joining a company.';
  end if;

  if nullif(btrim(company_code), '') is null or
     nullif(btrim(user_name), '') is null then
    raise exception using
      errcode = '22004',
      message = 'Company code and name are required.';
  end if;

  if exists (
    select 1
    from public.profiles
    where id = auth.uid()
  ) then
    raise exception using
      errcode = '23505',
      message = 'This account already belongs to a company.';
  end if;

  select id
  into v_company_id
  from public.companies
  where upper(btrim(join_code)) = upper(btrim(company_code))
  limit 1;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Company code was not found.';
  end if;

  insert into public.profiles (
    id,
    company_id,
    full_name,
    role
  ) values (
    auth.uid(),
    v_company_id,
    btrim(user_name),
    'foreman'
  );
end;
$$;


ALTER FUNCTION "public"."join_company"("company_code" "text", "user_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_company_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select company_id
  from public.profiles
  where id = auth.uid()
  limit 1;
$$;


ALTER FUNCTION "public"."my_company_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select role
  from public.profiles
  where id = auth.uid()
  limit 1;
$$;


ALTER FUNCTION "public"."my_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_work_point_key"("p_value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select regexp_replace(
    regexp_replace(
      lower(btrim(coalesce(p_value, ''))),
      '^(pole|wp|work[[:space:]_-]*point)[[:space:]#:_-]*',
      '',
      'i'
    ),
    '[^a-z0-9]+',
    '',
    'g'
  );
$$;


ALTER FUNCTION "public"."normalize_work_point_key"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."protect_daily_report_unit_history"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1
    from public.daily_production_units line
    where line.daily_report_id = old.id
  ) and (
    new.job_id is distinct from old.job_id or
    new.work_date is distinct from old.work_date
  ) then
    raise exception using
      errcode = '23514',
      message = 'Remove saved unit production before changing the job or work date.';
  end if;

  if lower(coalesce(old.status, 'draft')) = 'draft' and
     lower(coalesce(new.status, 'draft')) = 'submitted' and
     not exists (
       select 1
       from public.daily_production_units line
       where line.daily_report_id = old.id
     ) then
    raise exception using
      errcode = '23514',
      message = 'Add at least one unit before submitting this daily report.';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."protect_daily_report_unit_history"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_daily_report_audit_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."record_daily_report_audit_event"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."daily_report_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "daily_report_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "original_filename" "text" NOT NULL,
    "mime_type" "text",
    "file_size_bytes" bigint DEFAULT 0 NOT NULL,
    "caption" "text",
    "uploaded_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_report_attachments_file_size_bytes_check" CHECK ((("file_size_bytes" >= 0) AND ("file_size_bytes" <= 15728640)))
);


ALTER TABLE "public"."daily_report_attachments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_daily_report_attachment"("p_report_id" "uuid", "p_storage_path" "text", "p_original_filename" "text", "p_mime_type" "text" DEFAULT NULL::"text", "p_file_size_bytes" bigint DEFAULT 0, "p_caption" "text" DEFAULT NULL::"text") RETURNS "public"."daily_report_attachments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_profile public.profiles%rowtype;
  v_report public.daily_reports%rowtype;
  v_result public.daily_report_attachments;
begin
  select * into v_profile
  from public.profiles
  where id = auth.uid();

  if v_profile.id is null or v_profile.company_id is null then
    raise exception 'Active company membership required.';
  end if;

  select * into v_report
  from public.daily_reports
  where id = p_report_id
    and company_id = v_profile.company_id;

  if v_report.id is null then
    raise exception 'Daily report not found for your company.';
  end if;

  if p_storage_path is null or
     p_storage_path not like v_profile.company_id::text || '/' || p_report_id::text || '/%' then
    raise exception 'Invalid attachment storage path.';
  end if;

  if trim(coalesce(p_original_filename, '')) = '' then
    raise exception 'Attachment filename is required.';
  end if;

  if coalesce(p_file_size_bytes, 0) < 0 or
     coalesce(p_file_size_bytes, 0) > 15728640 then
    raise exception 'Attachment must be 15 MB or smaller.';
  end if;

  insert into public.daily_report_attachments(
    company_id, daily_report_id, storage_path, original_filename,
    mime_type, file_size_bytes, caption, uploaded_by
  ) values (
    v_profile.company_id, p_report_id, p_storage_path,
    left(trim(p_original_filename), 255),
    nullif(trim(coalesce(p_mime_type, '')), ''),
    coalesce(p_file_size_bytes, 0),
    nullif(left(trim(coalesce(p_caption, '')), 500), ''),
    auth.uid()
  )
  returning * into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."register_daily_report_attachment"("p_report_id" "uuid", "p_storage_path" "text", "p_original_filename" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_caption" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."return_daily_report"("p_report_id" "uuid", "p_review_notes" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin

    if not public.can_review_daily_reports() then
        raise exception 'You do not have permission to return reports';
    end if;

    if nullif(trim(p_review_notes), '') is null then
        raise exception 'Review notes are required when returning a report';
    end if;

    update public.daily_reports
    set
        status = 'draft',
        reviewed_at = now(),
        review_notes = trim(p_review_notes)
    where id = p_report_id
      and company_id = public.my_company_id()
      and status = 'submitted';

    if not found then
        raise exception 'Report not found or cannot be returned';
    end if;

end;
$$;


ALTER FUNCTION "public"."return_daily_report"("p_report_id" "uuid", "p_review_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."review_daily_report"("p_report_id" "uuid", "p_approved" boolean, "p_review_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;


  if public.my_role() not in ('admin','gf') then

    raise exception
      'Only GF or Admin users can review reports';

  end if;


  update public.daily_reports

  set

    status =
      case
        when p_approved
          then 'approved'
        else 'rejected'
      end,

    reviewed_by = auth.uid(),

    reviewed_at = now(),

    review_notes =
      nullif(trim(p_review_notes),''),

    updated_at = now()

  where id = p_report_id

    and company_id = public.my_company_id()

    and status = 'submitted';


  if not found then

    raise exception
      'Submitted report not found';

  end if;

end;
$$;


ALTER FUNCTION "public"."review_daily_report"("p_report_id" "uuid", "p_approved" boolean, "p_review_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rotate_company_join_code"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_new_code text;
begin
  select company_id, lower(coalesce(role, '')), active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     v_role <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can generate a new company code.';
  end if;

  loop
    v_new_code := upper(
      substr(
        replace(gen_random_uuid()::text, '-', ''),
        1,
        8
      )
    );

    exit when not exists (
      select 1
      from public.companies
      where upper(btrim(join_code)) = v_new_code
    );
  end loop;

  update public.companies
  set join_code = v_new_code
  where id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Company was not found.';
  end if;

  return v_new_code;
end;
$$;


ALTER FUNCTION "public"."rotate_company_join_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_daily_report_jsa"("p_report_id" "uuid", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_special_equipment" "text" DEFAULT NULL::"text", "p_foreman_acknowledged" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_job_id uuid;
  v_created_by uuid;
  v_work_date date;
  v_crew_name text;
  v_weather text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman','gf','admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to save a JSA.';
  end if;

  select dr.job_id, dr.created_by, dr.work_date, dr.crew_name, dr.weather_conditions
    into v_job_id, v_created_by, v_work_date, v_crew_name, v_weather
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id
    and lower(coalesce(dr.status, 'draft')) = 'draft';

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'An editable daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only save a JSA for their own daily reports.';
  end if;

  if length(trim(coalesce(p_job_briefing, ''))) = 0
    or length(trim(coalesce(p_hazards, ''))) = 0
    or length(trim(coalesce(p_controls, ''))) = 0
    or length(trim(coalesce(p_ppe, ''))) = 0
    or length(trim(coalesce(p_emergency_plan, ''))) = 0
    or length(trim(coalesce(p_crew_members, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'All required JSA fields must be completed.';
  end if;

  if not coalesce(p_foreman_acknowledged, false) then
    raise exception using errcode = '22023',
      message = 'The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas (
    company_id, daily_report_id, job_id, created_by, work_date, crew_name,
    job_briefing, hazards, controls, ppe, emergency_plan, weather_conditions,
    special_equipment, crew_members, foreman_acknowledged, acknowledged_at,
    updated_at
  ) values (
    v_company_id, p_report_id, v_job_id, auth.uid(), v_work_date, v_crew_name,
    trim(p_job_briefing), trim(p_hazards), trim(p_controls), trim(p_ppe),
    trim(p_emergency_plan), v_weather, nullif(trim(coalesce(p_special_equipment,'')), ''),
    trim(p_crew_members), true, now(), now()
  )
  on conflict (daily_report_id) do update set
    job_id = excluded.job_id,
    work_date = excluded.work_date,
    crew_name = excluded.crew_name,
    job_briefing = excluded.job_briefing,
    hazards = excluded.hazards,
    controls = excluded.controls,
    ppe = excluded.ppe,
    emergency_plan = excluded.emergency_plan,
    weather_conditions = excluded.weather_conditions,
    special_equipment = excluded.special_equipment,
    crew_members = excluded.crew_members,
    foreman_acknowledged = excluded.foreman_acknowledged,
    acknowledged_at = now(),
    updated_at = now()
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$$;


ALTER FUNCTION "public"."save_daily_report_jsa"("p_report_id" "uuid", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_install_quantity" numeric, "p_retirement_quantity" numeric) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_job_id uuid;
  v_contract_id uuid;
  v_price_book_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_work_date date;
  v_item public.price_book_items%rowtype;
  v_percent numeric;
  v_has_adjustment boolean;
  v_line_id uuid;
begin
  if coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 then
    raise exception using
      errcode = '22023',
      message = 'Unit quantities cannot be negative.';
  end if;

  if coalesce(p_install_quantity, 0) = 0 and
     coalesce(p_retirement_quantity, 0) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Enter an installed or removed quantity.';
  end if;

  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select dr.company_id, dr.job_id, job.contract_id, dr.price_book_id,
         dr.created_by, lower(coalesce(dr.status, 'draft')), dr.work_date,
         dr.field_value_percent_snapshot, dr.has_field_adjustment
  into v_report_company_id, v_job_id, v_contract_id, v_price_book_id,
       v_report_creator, v_report_status, v_work_date,
       v_percent, v_has_adjustment
  from public.daily_reports dr
  join public.jobs job
    on job.id = dr.job_id
   and job.company_id = dr.company_id
  where dr.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  if v_contract_id is null then
    raise exception using
      errcode = '22023',
      message = 'Assign this job to a contract before entering units.';
  end if;

  if v_price_book_id is null then
    select pb.id
    into v_price_book_id
    from public.price_books pb
    where pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
      and (pb.active is true or pb.effective_end is not null)
      and (pb.effective_start is null or pb.effective_start <= v_work_date)
      and (pb.effective_end is null or pb.effective_end >= v_work_date)
    order by pb.effective_start desc nulls last, pb.created_at desc
    limit 1;

    if v_price_book_id is null then
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book covers this report date.';
    end if;

    update public.daily_reports
    set price_book_id = v_price_book_id
    where id = p_report_id
      and company_id = v_company_id
      and price_book_id is null;
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = v_price_book_id
      and pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'The report Price Book does not belong to this contract.';
  end if;

  select item.*
  into v_item
  from public.price_book_items item
  where item.id = p_price_book_item_id
    and item.company_id = v_company_id
    and item.price_book_id = v_price_book_id
    and (
      item.active is true or
      exists (
        select 1
        from public.daily_production_units existing_line
        where existing_line.daily_report_id = p_report_id
          and existing_line.price_book_item_id = item.id
          and existing_line.company_id = v_company_id
      )
    );

  if v_item.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Unit was not found in this report Price Book.';
  end if;

  if v_percent is null then
    select setting.field_value_percent
    into v_percent
    from public.contract_field_settings setting
    where setting.contract_id = v_contract_id
      and setting.company_id = v_company_id;

    v_has_adjustment := v_percent is not null;
    v_percent := coalesce(v_percent, 100);

    update public.daily_reports
    set
      field_value_percent_snapshot = v_percent,
      has_field_adjustment = v_has_adjustment
    where id = p_report_id
      and company_id = v_company_id
      and field_value_percent_snapshot is null;
  end if;

  v_has_adjustment := coalesce(v_has_adjustment, false);

  insert into public.daily_production_units (
    company_id,
    daily_report_id,
    job_id,
    contract_id,
    price_book_id,
    price_book_item_id,
    item_code,
    item_name,
    description,
    unit_of_measure,
    category,
    install_quantity,
    retirement_quantity,
    actual_install_price,
    actual_retirement_price,
    adjusted_install_price,
    adjusted_retirement_price,
    field_value_percent_snapshot,
    has_adjustment,
    created_by,
    updated_at
  ) values (
    v_company_id,
    p_report_id,
    v_job_id,
    v_contract_id,
    v_price_book_id,
    v_item.id,
    v_item.item_code,
    v_item.item_name,
    v_item.description,
    v_item.unit_of_measure,
    v_item.category,
    coalesce(p_install_quantity, 0),
    coalesce(p_retirement_quantity, 0),
    v_item.install_price,
    v_item.retirement_price,
    round(v_item.install_price * v_percent / 100, 2),
    round(v_item.retirement_price * v_percent / 100, 2),
    v_percent,
    v_has_adjustment,
    auth.uid(),
    now()
  )
  on conflict (daily_report_id, price_book_item_id) do update
  set
    install_quantity = excluded.install_quantity,
    retirement_quantity = excluded.retirement_quantity,
    item_code = excluded.item_code,
    item_name = excluded.item_name,
    description = excluded.description,
    unit_of_measure = excluded.unit_of_measure,
    category = excluded.category,
    actual_install_price = excluded.actual_install_price,
    actual_retirement_price = excluded.actual_retirement_price,
    adjusted_install_price = excluded.adjusted_install_price,
    adjusted_retirement_price = excluded.adjusted_retirement_price,
    field_value_percent_snapshot = excluded.field_value_percent_snapshot,
    has_adjustment = excluded.has_adjustment,
    updated_at = now()
  returning id into v_line_id;

  return v_line_id;
end;
$$;


ALTER FUNCTION "public"."save_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_install_quantity" numeric, "p_retirement_quantity" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_location text;
  v_total_install numeric;
  v_total_retirement numeric;
  v_aggregate_line_id uuid;
  v_location_line_id uuid;
begin
  v_location := btrim(coalesce(p_pole_location, ''));

  if length(v_location) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Enter a pole or work location.';
  end if;

  if coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 or
     (
       coalesce(p_install_quantity, 0) = 0 and
       coalesce(p_retirement_quantity, 0) = 0
     ) then
    raise exception using
      errcode = '22023',
      message = 'Enter an installed or removed quantity greater than zero.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_creator, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  select
    coalesce(sum(location_line.install_quantity), 0) +
      coalesce(p_install_quantity, 0),
    coalesce(sum(location_line.retirement_quantity), 0) +
      coalesce(p_retirement_quantity, 0)
  into v_total_install, v_total_retirement
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id
    and location_line.pole_location_key <> lower(v_location);

  v_aggregate_line_id := public.save_daily_report_unit(
    p_report_id,
    p_price_book_item_id,
    v_total_install,
    v_total_retirement
  );

  insert into public.daily_production_unit_locations (
    company_id,
    daily_report_id,
    daily_production_unit_id,
    price_book_item_id,
    pole_location,
    install_quantity,
    retirement_quantity,
    created_by,
    updated_at
  ) values (
    v_company_id,
    p_report_id,
    v_aggregate_line_id,
    p_price_book_item_id,
    v_location,
    coalesce(p_install_quantity, 0),
    coalesce(p_retirement_quantity, 0),
    auth.uid(),
    now()
  )
  on conflict (daily_report_id, price_book_item_id, pole_location_key)
  do update set
    daily_production_unit_id = excluded.daily_production_unit_id,
    pole_location = excluded.pole_location,
    install_quantity = excluded.install_quantity,
    retirement_quantity = excluded.retirement_quantity,
    updated_at = now()
  returning id into v_location_line_id;

  return v_location_line_id;
end;
$$;


ALTER FUNCTION "public"."save_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_job_package_authorized_unit"("p_work_point_id" "uuid", "p_unit_code" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_package_id uuid;
  v_contract_id uuid;
  v_price_book_item_id uuid;
  v_unit_code text;
  v_authorized_unit_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can add authorized units.';
  end if;

  if length(trim(coalesce(p_unit_code, ''))) = 0 or
     coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 or
     coalesce(p_install_quantity, 0) + coalesce(p_retirement_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'Unit code and an authorized quantity greater than zero are required.';
  end if;

  select point.job_package_id, package.contract_id
  into v_package_id, v_contract_id
  from public.job_package_work_points point
  join public.job_packages package
    on package.id = point.job_package_id
   and package.company_id = point.company_id
  where point.id = p_work_point_id
    and point.company_id = v_company_id;

  if v_package_id is null then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;

  select item.id, item.item_code
  into v_price_book_item_id, v_unit_code
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id
   and book.company_id = item.company_id
  where item.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
    and item.active is true
    and lower(trim(item.item_code)) = lower(trim(p_unit_code))
  order by book.effective_start desc nulls last, book.updated_at desc nulls last
  limit 1;

  if v_price_book_item_id is null then
    raise exception using errcode = 'P0002',
      message = 'That unit code was not found in an active Price Book for this contract.';
  end if;

  insert into public.job_package_authorized_units (
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_retirement_quantity, created_by
  ) values (
    v_company_id, v_package_id, p_work_point_id, v_price_book_item_id, v_unit_code,
    coalesce(p_install_quantity, 0), coalesce(p_retirement_quantity, 0), auth.uid()
  )
  on conflict (work_point_id, price_book_item_id) do update set
    authorized_install_quantity = excluded.authorized_install_quantity,
    authorized_retirement_quantity = excluded.authorized_retirement_quantity,
    unit_code = excluded.unit_code,
    updated_at = now()
  returning id into v_authorized_unit_id;

  return v_authorized_unit_id;
end;
$$;


ALTER FUNCTION "public"."save_job_package_authorized_unit"("p_work_point_id" "uuid", "p_unit_code" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_company_member_active"("p_member_id" "uuid", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_caller_company_id uuid;
  v_caller_role text;
  v_caller_active boolean;
  v_target_role text;
  v_active_admin_count integer;
begin
  if p_member_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and access status are required.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_caller_company_id, v_caller_role, v_caller_active
  from public.profiles
  where id = auth.uid();

  if v_caller_company_id is null or
     v_caller_role <> 'admin' or
     v_caller_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change team access.';
  end if;

  if p_member_id = auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Admins cannot suspend their own account.';
  end if;

  select lower(coalesce(role, ''))
  into v_target_role
  from public.profiles
  where id = p_member_id
    and company_id = v_caller_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  if p_active is false and v_target_role = 'admin' then
    select count(*)
    into v_active_admin_count
    from public.profiles
    where company_id = v_caller_company_id
      and lower(coalesce(role, '')) = 'admin'
      and active is true;

    if v_active_admin_count <= 1 then
      raise exception using
        errcode = '23514',
        message = 'The last active company Admin cannot be suspended.';
    end if;
  end if;

  update public.profiles
  set active = p_active
  where id = p_member_id
    and company_id = v_caller_company_id;
end;
$$;


ALTER FUNCTION "public"."set_company_member_active"("p_member_id" "uuid", "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_company_member_role"("p_member_id" "uuid", "p_role" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_caller_company_id uuid;
  v_caller_role text;
  v_caller_active boolean;
  v_target_role text;
  v_next_role text;
  v_admin_count integer;
begin
  v_next_role := lower(btrim(coalesce(p_role, '')));

  if p_member_id is null or
     v_next_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '22023',
      message = 'Choose Foreman, General Foreman, or Admin.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_caller_company_id, v_caller_role, v_caller_active
  from public.profiles
  where id = auth.uid();

  if v_caller_company_id is null or
     v_caller_role <> 'admin' or
     v_caller_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change team roles.';
  end if;

  select lower(coalesce(role, ''))
  into v_target_role
  from public.profiles
  where id = p_member_id
    and company_id = v_caller_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  if v_target_role = 'admin' and v_next_role <> 'admin' then
    select count(*)
    into v_admin_count
    from public.profiles
    where company_id = v_caller_company_id
      and lower(coalesce(role, '')) = 'admin'
      and active is true;

    if v_admin_count <= 1 then
      raise exception using
        errcode = '23514',
        message = 'Assign another Admin before changing the last Admin role.';
    end if;
  end if;

  update public.profiles
  set role = v_next_role
  where id = p_member_id
    and company_id = v_caller_company_id;
end;
$$;


ALTER FUNCTION "public"."set_company_member_role"("p_member_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_company_redline_approval_requirement"("p_required" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can change redline approval requirements.';
  end if;

  update public.companies company
  set require_gf_redline_approval = coalesce(p_required, false)
  where company.id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."set_company_redline_approval_requirement"("p_required" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_company_storm_mode"("p_enabled" boolean, "p_event_name" "text" DEFAULT NULL::"text") RETURNS TABLE("storm_mode_enabled" boolean, "storm_event_name" "text", "storm_started_at" timestamp with time zone, "storm_ended_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can change Storm Mode.';
  end if;

  if coalesce(p_enabled, false) and length(trim(coalesce(p_event_name, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'A storm or event name is required when Storm Mode is enabled.';
  end if;

  update public.companies c
  set storm_mode_enabled = coalesce(p_enabled, false),
      storm_event_name = case when coalesce(p_enabled, false)
        then trim(p_event_name) else null end,
      storm_started_at = case
        when coalesce(p_enabled, false) and not c.storm_mode_enabled then now()
        when coalesce(p_enabled, false) then c.storm_started_at
        else c.storm_started_at end,
      storm_ended_at = case
        when not coalesce(p_enabled, false) and c.storm_mode_enabled then now()
        when coalesce(p_enabled, false) then null
        else c.storm_ended_at end
  where c.id = v_company_id;

  return query
  select c.storm_mode_enabled, c.storm_event_name,
         c.storm_started_at, c.storm_ended_at
  from public.companies c
  where c.id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."set_company_storm_mode"("p_enabled" boolean, "p_event_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_contract_field_value_percent"("p_contract_id" "uuid", "p_field_value_percent" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  if p_contract_id is null then
    raise exception using
      errcode = '22004',
      message = 'Contract is required.';
  end if;

  if p_field_value_percent is not null and
     (p_field_value_percent < 0 or p_field_value_percent > 100) then
    raise exception using
      errcode = '22023',
      message = 'Field Value must be between 0% and 100%.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     v_role <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change Field Value settings.';
  end if;

  if not exists (
    select 1
    from public.contracts
    where id = p_contract_id
      and company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Contract was not found in your company.';
  end if;

  if p_field_value_percent is null then
    delete from public.contract_field_settings
    where contract_id = p_contract_id
      and company_id = v_company_id;
  else
    insert into public.contract_field_settings (
      contract_id,
      company_id,
      field_value_percent,
      updated_by,
      updated_at
    ) values (
      p_contract_id,
      v_company_id,
      p_field_value_percent,
      auth.uid(),
      now()
    )
    on conflict (contract_id) do update
    set
      field_value_percent = excluded.field_value_percent,
      updated_by = excluded.updated_by,
      updated_at = now()
    where public.contract_field_settings.company_id = v_company_id;
  end if;
end;
$$;


ALTER FUNCTION "public"."set_contract_field_value_percent"("p_contract_id" "uuid", "p_field_value_percent" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_daily_report_archived"("p_report_id" "uuid", "p_archived" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can archive daily reports.';
  end if;

  update public.daily_reports report
  set archived = coalesce(p_archived, false)
  where report.id = p_report_id
    and report.company_id = v_company_id
    and (
      coalesce(p_archived, false) is false or
      lower(coalesce(report.status, '')) = 'approved'
    );

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Only approved reports can be archived. Draft reports may be deleted instead.';
  end if;
end;
$$;


ALTER FUNCTION "public"."set_daily_report_archived"("p_report_id" "uuid", "p_archived" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_daily_report_context"("p_report_id" "uuid", "p_weather_conditions" "text", "p_delay_hours" numeric, "p_delay_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."set_daily_report_context"("p_report_id" "uuid", "p_weather_conditions" "text", "p_delay_hours" numeric, "p_delay_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_daily_report_date"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.report_date is null then
    new.report_date := new.work_date;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."set_daily_report_date"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_daily_report_storm_context"("p_report_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_report_created_by uuid;
  v_enabled boolean;
  v_event_name text;
  v_assigned boolean;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('foreman','gf','admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to update this daily report.';
  end if;

  select dr.created_by
    into v_report_created_by
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id;

  if v_report_created_by is null then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_report_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only update their own daily reports.';
  end if;

  select c.storm_mode_enabled, c.storm_event_name,
         exists (
           select 1
           from public.storm_mode_assignments a
           where a.company_id = v_company_id
             and a.user_id = v_report_created_by
         )
    into v_enabled, v_event_name, v_assigned
  from public.companies c
  where c.id = v_company_id;

  update public.daily_reports
  set storm_mode = coalesce(v_enabled, false) and coalesce(v_assigned, false),
      storm_event_name = case
        when coalesce(v_enabled, false) and coalesce(v_assigned, false)
          then v_event_name
        else null
      end
  where id = p_report_id
    and company_id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."set_daily_report_storm_context"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_job_active"("p_job_id" "uuid", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() not in ('admin', 'gf') then
    raise exception 'Only company admins and GFs can change job status';
  end if;

  update public.jobs
  set
    active = p_active,
    closed_at = case
      when p_active then null
      else now()
    end
  where id = p_job_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'Job not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."set_job_active"("p_job_id" "uuid", "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_job_leader_assignment"("p_job_id" "uuid", "p_member_id" "uuid", "p_assigned" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_member_role text;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can change job leaders.';
  end if;

  if not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select lower(coalesce(profile.role, 'foreman'))
  into v_member_role
  from public.profiles profile
  where profile.id = p_member_id
    and profile.company_id = v_company_id
    and profile.active is true;

  if v_member_role is null or v_member_role not in ('foreman', 'gf') then
    raise exception using errcode = '22023',
      message = 'Select an active Foreman or General Foreman from your company.';
  end if;

  if coalesce(p_assigned, false) then
    insert into public.job_leader_assignments (
      company_id,
      job_id,
      member_id,
      assigned_by
    ) values (
      v_company_id,
      p_job_id,
      p_member_id,
      auth.uid()
    )
    on conflict (job_id, member_id) do nothing;
  else
    delete from public.job_leader_assignments assignment
    where assignment.company_id = v_company_id
      and assignment.job_id = p_job_id
      and assignment.member_id = p_member_id;
  end if;
end;
$$;


ALTER FUNCTION "public"."set_job_leader_assignment"("p_job_id" "uuid", "p_member_id" "uuid", "p_assigned" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_job_package_status"("p_package_id" "uuid", "p_status" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_next_status text;
  v_job_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change a utility package status.';
  end if;

  v_next_status := lower(trim(coalesce(p_status, '')));
  if v_next_status not in ('active', 'closed') then
    raise exception using
      errcode = '22023',
      message = 'A utility package can only be activated or closed.';
  end if;

  select job.active
  into v_job_active
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_active is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if v_next_status = 'active' and v_job_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reopen the job before activating this utility package.';
  end if;

  if v_next_status = 'active' and not exists (
    select 1
    from public.job_package_authorized_units unit
    where unit.company_id = v_company_id
      and unit.job_package_id = p_package_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Add at least one authorized unit before activating this utility package.';
  end if;

  update public.job_packages package
  set status = v_next_status,
      updated_at = now()
  where package.id = p_package_id
    and package.company_id = v_company_id;

  return v_next_status;
end;
$$;


ALTER FUNCTION "public"."set_job_package_status"("p_package_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_price_book_active"("p_price_book_id" "uuid", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_target public.price_books%rowtype;
begin
  if p_price_book_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book ID and active status are required.';
  end if;

  select company_id, role, active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     lower(coalesce(v_role, '')) <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change Price Book status.';
  end if;

  select *
  into v_target
  from public.price_books
  where id = p_price_book_id
    and company_id = v_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Price Book not found for the current company.';
  end if;

  if p_active then
    update public.price_books
    set active = false, updated_at = now()
    where company_id = v_company_id
      and id <> v_target.id
      and contract_id is not distinct from v_target.contract_id
      and coalesce(lower(btrim(name)), '') =
        coalesce(lower(btrim(v_target.name)), '')
      and active is true;
  end if;

  update public.price_books
  set active = p_active, updated_at = now()
  where id = v_target.id
    and company_id = v_company_id;
end;
$$;


ALTER FUNCTION "public"."set_price_book_active"("p_price_book_id" "uuid", "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_storm_mode_assignments"("p_user_ids" "uuid"[]) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_requested_count integer;
  v_valid_count integer;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can change Storm Mode crew assignments.';
  end if;

  select count(distinct requested_id)
    into v_requested_count
  from unnest(coalesce(p_user_ids, array[]::uuid[])) requested_id;

  select count(*)
    into v_valid_count
  from public.profiles p
  where p.company_id = v_company_id
    and p.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and coalesce(p.active, true)
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin');

  if v_requested_count <> v_valid_count then
    raise exception using errcode = '22023',
      message = 'One or more selected Storm Mode crew leaders are invalid for this company.';
  end if;

  delete from public.storm_mode_assignments
  where company_id = v_company_id;

  insert into public.storm_mode_assignments(company_id, user_id, assigned_by)
  select v_company_id, p.id, auth.uid()
  from public.profiles p
  where p.company_id = v_company_id
    and p.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and coalesce(p.active, true)
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin')
  on conflict (company_id, user_id) do nothing;

  return v_valid_count;
end;
$$;


ALTER FUNCTION "public"."set_storm_mode_assignments"("p_user_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_daily_report"("p_report_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

begin

  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;


  update public.daily_reports

  set

    status = 'submitted',

    submitted_at = now(),

    updated_at = now(),

    review_notes = null

  where id = p_report_id

    and company_id = public.my_company_id()

    and foreman_id = auth.uid()

    and status in ('draft','rejected');


  if not found then

    raise exception
      'Report not found or cannot be submitted';

  end if;

end;
$$;


ALTER FUNCTION "public"."submit_daily_report"("p_report_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_company_settings"("p_name" "text", "p_contact_email" "text" DEFAULT NULL::"text", "p_contact_phone" "text" DEFAULT NULL::"text", "p_logo_url" "text" DEFAULT NULL::"text", "p_primary_color" "text" DEFAULT '#0b2d4d'::"text", "p_timezone" "text" DEFAULT 'America/Chicago'::"text") RETURNS TABLE("id" "uuid", "name" "text", "contact_email" "text", "contact_phone" "text", "logo_url" "text", "primary_color" "text", "timezone" "text", "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."update_company_settings"("p_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_logo_url" "text", "p_primary_color" "text", "p_timezone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_contract_job"("p_job_id" "uuid", "p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can update jobs.';
  end if;

  if length(trim(coalesce(p_job_number, ''))) = 0 or
     length(trim(coalesce(p_job_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Job number and job name are required.';
  end if;

  select customer.name
  into v_customer_name
  from public.contracts contract
  join public.customers customer
    on customer.id = contract.customer_id
   and customer.company_id = contract.company_id
  where contract.id = p_contract_id
    and contract.company_id = v_company_id
    and contract.active is true;

  if v_customer_name is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active contract was not found in your company.';
  end if;

  update public.jobs
  set
    contract_id = p_contract_id,
    job_number = trim(p_job_number),
    job_name = trim(p_job_name),
    customer_name = v_customer_name,
    utility_name = v_customer_name
  where id = p_job_id
    and company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;
end;
$$;


ALTER FUNCTION "public"."update_contract_job"("p_job_id" "uuid", "p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_daily_report"("p_report_id" "uuid", "p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin

    update public.daily_reports
    set
        job_id = p_job_id,
        work_date = p_work_date,
        regular_hours = coalesce(p_regular_hours, 0),
        overtime_hours = coalesce(p_overtime_hours, 0),
        crew_name = nullif(trim(p_crew_name), ''),
        notes = nullif(trim(p_notes), '')
    where id = p_report_id
      and company_id = public.my_company_id()
      and status = 'draft'
      and foreman_id = auth.uid();

    if not found then
        raise exception 'Draft report not found or cannot be edited';
    end if;

end;
$$;


ALTER FUNCTION "public"."update_daily_report"("p_report_id" "uuid", "p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_job"("p_job_id" "uuid", "p_job_number" "text", "p_job_name" "text", "p_customer_name" "text" DEFAULT NULL::"text", "p_utility_name" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.my_role() not in ('admin', 'gf') then
    raise exception 'Only company admins and GFs can update jobs';
  end if;

  update public.jobs
  set
    job_number = trim(p_job_number),
    job_name = trim(p_job_name),
    customer_name = nullif(trim(p_customer_name), ''),
    utility_name = nullif(trim(p_utility_name), '')
  where id = p_job_id
    and company_id = public.my_company_id();

  if not found then
    raise exception 'Job not found';
  end if;
end;
$$;


ALTER FUNCTION "public"."update_job"("p_job_id" "uuid", "p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_job_package_import"("p_package_id" "uuid", "p_rows" "jsonb") RETURNS TABLE("row_number" integer, "is_valid" boolean, "error_message" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_unit_code text;
  v_install numeric;
  v_retirement numeric;
  v_error text;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can validate job packet imports.';
  end if;

  select package.contract_id
  into v_contract_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'Import rows are required.';
  end if;

  if jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'A maximum of 2,000 consolidated rows can be imported at once.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := trim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := trim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);
    v_error := null;

    if length(v_work_point) = 0 then
      v_error := 'Missing work point';
    elsif length(v_unit_code) = 0 then
      v_error := 'Missing unit code';
    elsif v_install < 0 or v_retirement < 0 or v_install + v_retirement <= 0 then
      v_error := 'Authorized quantity must be greater than zero';
    elsif not exists (
      select 1
      from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id
       and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id
        and book.active is true
        and item.active is true
        and lower(trim(item.item_code)) = lower(v_unit_code)
    ) then
      v_error := 'Unit code was not found in an active Price Book for this contract';
    end if;

    row_number := v_row_number;
    is_valid := v_error is null;
    error_message := v_error;
    return next;
  end loop;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023',
      message = 'One or more quantities are not valid numbers.';
end;
$$;


ALTER FUNCTION "public"."validate_job_package_import"("p_package_id" "uuid", "p_rows" "jsonb") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_log" (
    "id" bigint NOT NULL,
    "company_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "action" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_id" "uuid",
    "old_data" "jsonb",
    "new_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."audit_log" OWNER TO "postgres";


ALTER TABLE "public"."audit_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."audit_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."companies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "join_code" "text" DEFAULT "upper"("substr"("replace"(("gen_random_uuid"())::"text", '-'::"text", ''::"text"), 1, 8)) NOT NULL,
    "created_by" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "require_gf_redline_approval" boolean DEFAULT false NOT NULL,
    "contact_email" "text",
    "contact_phone" "text",
    "logo_url" "text",
    "primary_color" "text" DEFAULT '#0b2d4d'::"text" NOT NULL,
    "timezone" "text" DEFAULT 'America/Chicago'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "storm_mode_enabled" boolean DEFAULT false NOT NULL,
    "storm_event_name" "text",
    "storm_started_at" timestamp with time zone,
    "storm_ended_at" timestamp with time zone,
    CONSTRAINT "companies_primary_color_format" CHECK (("primary_color" ~ '^#[0-9A-Fa-f]{6}$'::"text"))
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "display_name" "text",
    "logo_url" "text",
    "primary_color" "text" DEFAULT '#0b2d4d'::"text",
    "secondary_color" "text" DEFAULT '#1677d2'::"text",
    "adjustment_enabled" boolean DEFAULT false NOT NULL,
    "adjustment_percent" numeric(8,4) DEFAULT 0 NOT NULL,
    "adjustment_label" "text" DEFAULT 'Adjustment'::"text",
    "show_original_pricing" boolean DEFAULT true NOT NULL,
    "gf_can_edit_reports" boolean DEFAULT true NOT NULL,
    "gf_can_delete_reports" boolean DEFAULT true NOT NULL,
    "pole_label" "text" DEFAULT 'Pole / Location'::"text" NOT NULL,
    "job_label" "text" DEFAULT 'Job'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."company_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contract_field_settings" (
    "contract_id" "uuid" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "field_value_percent" numeric(5,2) NOT NULL,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contract_field_value_percent_range" CHECK ((("field_value_percent" >= (0)::numeric) AND ("field_value_percent" <= (100)::numeric)))
);


ALTER TABLE "public"."contract_field_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contracts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "customer_id" "uuid" NOT NULL,
    "contract_name" "text" NOT NULL,
    "contract_number" "text",
    "pay_item_label" "text" DEFAULT 'Pay Item'::"text" NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "notes" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."contracts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "foreman_id" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."crews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "customer_type" "text",
    "account_number" "text",
    "contact_name" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "notes" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."customers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_production_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "daily_report_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "work_point_id" "uuid",
    "price_book_item_id" "uuid",
    "action_type" "text" NOT NULL,
    "quantity" numeric(12,3) DEFAULT 1 NOT NULL,
    "item_code_snapshot" "text",
    "item_name_snapshot" "text" NOT NULL,
    "description_snapshot" "text",
    "unit_price_snapshot" numeric(12,2) DEFAULT 0 NOT NULL,
    "extended_value" numeric(14,2) GENERATED ALWAYS AS ("round"(("quantity" * "unit_price_snapshot"), 2)) STORED,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_production_items_action_type_check" CHECK (("lower"("action_type") = ANY (ARRAY['install'::"text", 'retire'::"text"])))
);


ALTER TABLE "public"."daily_production_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_production_unit_locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "daily_report_id" "uuid" NOT NULL,
    "daily_production_unit_id" "uuid" NOT NULL,
    "price_book_item_id" "uuid" NOT NULL,
    "pole_location" "text" NOT NULL,
    "pole_location_key" "text" GENERATED ALWAYS AS ("lower"("btrim"("pole_location"))) STORED,
    "install_quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "retirement_quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_production_unit_locations_has_quantity" CHECK ((("install_quantity" > (0)::numeric) OR ("retirement_quantity" > (0)::numeric))),
    CONSTRAINT "daily_production_unit_locations_location_not_blank" CHECK (("length"("btrim"("pole_location")) > 0)),
    CONSTRAINT "daily_production_unit_locations_nonnegative" CHECK ((("install_quantity" >= (0)::numeric) AND ("retirement_quantity" >= (0)::numeric)))
);


ALTER TABLE "public"."daily_production_unit_locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_production_units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "daily_report_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "contract_id" "uuid" NOT NULL,
    "price_book_id" "uuid" NOT NULL,
    "price_book_item_id" "uuid" NOT NULL,
    "item_code" "text" NOT NULL,
    "item_name" "text",
    "description" "text",
    "unit_of_measure" "text",
    "category" "text",
    "install_quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "retirement_quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "actual_install_price" numeric(14,2) NOT NULL,
    "actual_retirement_price" numeric(14,2) NOT NULL,
    "adjusted_install_price" numeric(14,2) NOT NULL,
    "adjusted_retirement_price" numeric(14,2) NOT NULL,
    "field_value_percent_snapshot" numeric(5,2) NOT NULL,
    "has_adjustment" boolean DEFAULT false NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_production_units_has_quantity" CHECK ((("install_quantity" > (0)::numeric) OR ("retirement_quantity" > (0)::numeric))),
    CONSTRAINT "daily_production_units_nonnegative_quantities" CHECK ((("install_quantity" >= (0)::numeric) AND ("retirement_quantity" >= (0)::numeric)))
);


ALTER TABLE "public"."daily_production_units" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_report_audit_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "daily_report_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "actor_id" "uuid",
    "actor_name" "text",
    "actor_role" "text",
    "event_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_report_audit_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['created'::"text", 'submitted'::"text", 'returned'::"text", 'approved'::"text", 'archived'::"text", 'restored'::"text"])))
);


ALTER TABLE "public"."daily_report_audit_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_report_jsas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "daily_report_id" "uuid",
    "job_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "work_date" "date" NOT NULL,
    "crew_name" "text",
    "job_briefing" "text" NOT NULL,
    "hazards" "text" NOT NULL,
    "controls" "text" NOT NULL,
    "ppe" "text" NOT NULL,
    "emergency_plan" "text" NOT NULL,
    "weather_conditions" "text",
    "special_equipment" "text",
    "crew_members" "text" NOT NULL,
    "foreman_acknowledged" boolean DEFAULT false NOT NULL,
    "acknowledged_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_report_jsas_controls_not_blank" CHECK (("length"(TRIM(BOTH FROM "controls")) > 0)),
    CONSTRAINT "daily_report_jsas_crew_members_not_blank" CHECK (("length"(TRIM(BOTH FROM "crew_members")) > 0)),
    CONSTRAINT "daily_report_jsas_emergency_plan_not_blank" CHECK (("length"(TRIM(BOTH FROM "emergency_plan")) > 0)),
    CONSTRAINT "daily_report_jsas_hazards_not_blank" CHECK (("length"(TRIM(BOTH FROM "hazards")) > 0)),
    CONSTRAINT "daily_report_jsas_job_briefing_not_blank" CHECK (("length"(TRIM(BOTH FROM "job_briefing")) > 0)),
    CONSTRAINT "daily_report_jsas_ppe_not_blank" CHECK (("length"(TRIM(BOTH FROM "ppe")) > 0))
);


ALTER TABLE "public"."daily_report_jsas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_report_units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "report_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "work_point" "text",
    "unit_code" "text" NOT NULL,
    "description" "text",
    "installed_qty" numeric(12,2) DEFAULT 0 NOT NULL,
    "retired_qty" numeric(12,2) DEFAULT 0 NOT NULL,
    "install_unit_price" numeric(14,2),
    "retire_unit_price" numeric(14,2),
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."daily_report_units" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "crew_id" "uuid",
    "foreman_id" "uuid" NOT NULL,
    "report_date" "date" NOT NULL,
    "crew_size" numeric(8,2) DEFAULT 0 NOT NULL,
    "hours" numeric(8,2) DEFAULT 0 NOT NULL,
    "unit_revenue" numeric(14,2) DEFAULT 0 NOT NULL,
    "adjusted_revenue" numeric(14,2) DEFAULT 0 NOT NULL,
    "manhour_revenue" numeric(14,2) DEFAULT 0 NOT NULL,
    "crewhour_revenue" numeric(14,2) DEFAULT 0 NOT NULL,
    "notes" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "work_date" "date" DEFAULT CURRENT_DATE,
    "foreman_name" "text",
    "crew_name" "text",
    "regular_hours" numeric(8,2) DEFAULT 0,
    "overtime_hours" numeric(8,2) DEFAULT 0,
    "submitted_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_notes" "text",
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "price_book_id" "uuid",
    "field_value_percent_snapshot" numeric(5,2),
    "has_field_adjustment" boolean,
    "archived" boolean DEFAULT false NOT NULL,
    "redline_override_by" "uuid",
    "redline_override_reason" "text",
    "redline_override_at" timestamp with time zone,
    "weather_conditions" "text",
    "delay_hours" numeric(8,2) DEFAULT 0 NOT NULL,
    "delay_reason" "text",
    "storm_mode" boolean DEFAULT false NOT NULL,
    "storm_event_name" "text",
    CONSTRAINT "daily_reports_delay_hours_nonnegative" CHECK (("delay_hours" >= (0)::numeric)),
    CONSTRAINT "daily_reports_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'submitted'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."daily_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "crew_id" "uuid",
    "employee_number" "text",
    "full_name" "text" NOT NULL,
    "classification" "text",
    "hourly_cost" numeric(12,2),
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_leader_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "member_id" "uuid" NOT NULL,
    "assigned_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."job_leader_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_package_authorized_units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_package_id" "uuid" NOT NULL,
    "work_point_id" "uuid" NOT NULL,
    "price_book_item_id" "uuid" NOT NULL,
    "unit_code" "text" NOT NULL,
    "authorized_install_quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "authorized_retirement_quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "job_package_authorized_units_has_quantity" CHECK ((("authorized_install_quantity" > (0)::numeric) OR ("authorized_retirement_quantity" > (0)::numeric))),
    CONSTRAINT "job_package_authorized_units_nonnegative" CHECK ((("authorized_install_quantity" >= (0)::numeric) AND ("authorized_retirement_quantity" >= (0)::numeric)))
);


ALTER TABLE "public"."job_package_authorized_units" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_package_work_points" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_package_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "work_point_code" "text" NOT NULL,
    "work_point_key" "text" GENERATED ALWAYS AS ("lower"(TRIM(BOTH FROM "work_point_code"))) STORED,
    "description" "text",
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "job_package_work_points_code_not_blank" CHECK (("length"(TRIM(BOTH FROM "work_point_code")) > 0))
);


ALTER TABLE "public"."job_package_work_points" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_packages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "contract_id" "uuid" NOT NULL,
    "package_name" "text" NOT NULL,
    "package_number" "text",
    "received_date" "date",
    "source_filename" "text",
    "notes" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "job_packages_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "package_name")) > 0)),
    CONSTRAINT "job_packages_status_supported" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."job_packages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_number" "text" NOT NULL,
    "job_name" "text",
    "customer_name" "text",
    "utility_name" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_at" timestamp with time zone,
    "customer_id" "uuid",
    "contract_id" "uuid",
    "price_book_id" "uuid"
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_book_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "price_book_id" "uuid" NOT NULL,
    "item_code" "text",
    "item_name" "text" NOT NULL,
    "description" "text",
    "install_price" numeric(12,2),
    "retirement_price" numeric(12,2),
    "unit_of_measure" "text",
    "category" "text",
    "extra_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."price_book_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."price_books" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "customer_name" "text",
    "utility_name" "text",
    "effective_date" "date",
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "contract_id" "uuid",
    "version_name" "text",
    "effective_start" "date",
    "effective_end" "date",
    "source_filename" "text",
    "notes" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."price_books" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "role" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'gf'::"text", 'foreman'::"text", 'employee'::"text"]))),
    CONSTRAINT "profiles_role_supported" CHECK (("lower"("role") = ANY (ARRAY['foreman'::"text", 'gf'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."report_units" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "report_id" "uuid" NOT NULL,
    "pole_location" "text" NOT NULL,
    "unit" "text" NOT NULL,
    "action" "text" NOT NULL,
    "quantity" numeric(12,2) NOT NULL,
    "rate" numeric(14,2) NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "report_units_action_check" CHECK (("action" = ANY (ARRAY['install'::"text", 'remove'::"text", 'transfer'::"text"])))
);


ALTER TABLE "public"."report_units" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."storm_mode_assignments" (
    "company_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "assigned_by" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."storm_mode_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."unit_prices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "price_book_id" "uuid",
    "unit" "text" NOT NULL,
    "description" "text",
    "install" numeric(14,2),
    "remove" numeric(14,2),
    "transfer" numeric(14,2),
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."unit_prices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."work_points" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "job_id" "uuid" NOT NULL,
    "work_point_number" "text" NOT NULL,
    "description" "text",
    "latitude" numeric,
    "longitude" numeric,
    "notes" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."work_points" OWNER TO "postgres";


ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_join_code_key" UNIQUE ("join_code");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_settings"
    ADD CONSTRAINT "company_settings_company_id_key" UNIQUE ("company_id");



ALTER TABLE ONLY "public"."company_settings"
    ADD CONSTRAINT "company_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."contract_field_settings"
    ADD CONSTRAINT "contract_field_settings_pkey" PRIMARY KEY ("contract_id");



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."crews"
    ADD CONSTRAINT "crews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_report_item_location_unique" UNIQUE ("daily_report_id", "price_book_item_id", "pole_location_key");



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_report_item_unique" UNIQUE ("daily_report_id", "price_book_item_id");



ALTER TABLE ONLY "public"."daily_report_attachments"
    ADD CONSTRAINT "daily_report_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_report_attachments"
    ADD CONSTRAINT "daily_report_attachments_storage_path_key" UNIQUE ("storage_path");



ALTER TABLE ONLY "public"."daily_report_audit_events"
    ADD CONSTRAINT "daily_report_audit_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_report_jsas"
    ADD CONSTRAINT "daily_report_jsas_daily_report_id_key" UNIQUE ("daily_report_id");



ALTER TABLE ONLY "public"."daily_report_jsas"
    ADD CONSTRAINT "daily_report_jsas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_report_units"
    ADD CONSTRAINT "daily_report_units_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_leader_assignments"
    ADD CONSTRAINT "job_leader_assignments_job_id_member_id_key" UNIQUE ("job_id", "member_id");



ALTER TABLE ONLY "public"."job_leader_assignments"
    ADD CONSTRAINT "job_leader_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_point_item_unique" UNIQUE ("work_point_id", "price_book_item_id");



ALTER TABLE ONLY "public"."job_package_work_points"
    ADD CONSTRAINT "job_package_work_points_package_code_unique" UNIQUE ("job_package_id", "work_point_key");



ALTER TABLE ONLY "public"."job_package_work_points"
    ADD CONSTRAINT "job_package_work_points_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_packages"
    ADD CONSTRAINT "job_packages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_company_id_job_number_key" UNIQUE ("company_id", "job_number");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_book_items"
    ADD CONSTRAINT "price_book_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."price_books"
    ADD CONSTRAINT "price_books_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."report_units"
    ADD CONSTRAINT "report_units_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."storm_mode_assignments"
    ADD CONSTRAINT "storm_mode_assignments_pkey" PRIMARY KEY ("company_id", "user_id");



ALTER TABLE ONLY "public"."unit_prices"
    ADD CONSTRAINT "unit_prices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."unit_prices"
    ADD CONSTRAINT "unit_prices_price_book_id_unit_key" UNIQUE ("price_book_id", "unit");



ALTER TABLE ONLY "public"."work_points"
    ADD CONSTRAINT "work_points_job_id_work_point_number_key" UNIQUE ("job_id", "work_point_number");



ALTER TABLE ONLY "public"."work_points"
    ADD CONSTRAINT "work_points_pkey" PRIMARY KEY ("id");



CREATE INDEX "contracts_company_id_idx" ON "public"."contracts" USING "btree" ("company_id");



CREATE INDEX "contracts_customer_id_idx" ON "public"."contracts" USING "btree" ("customer_id");



CREATE INDEX "customers_company_id_idx" ON "public"."customers" USING "btree" ("company_id");



CREATE INDEX "daily_production_items_company_id_idx" ON "public"."daily_production_items" USING "btree" ("company_id");



CREATE INDEX "daily_production_items_daily_report_id_idx" ON "public"."daily_production_items" USING "btree" ("daily_report_id");



CREATE INDEX "daily_production_items_job_id_idx" ON "public"."daily_production_items" USING "btree" ("job_id");



CREATE INDEX "daily_production_items_price_book_item_id_idx" ON "public"."daily_production_items" USING "btree" ("price_book_item_id");



CREATE INDEX "daily_production_items_work_point_id_idx" ON "public"."daily_production_items" USING "btree" ("work_point_id");



CREATE INDEX "daily_production_unit_locations_company_report_idx" ON "public"."daily_production_unit_locations" USING "btree" ("company_id", "daily_report_id");



CREATE INDEX "daily_production_units_company_report_idx" ON "public"."daily_production_units" USING "btree" ("company_id", "daily_report_id");



CREATE INDEX "daily_report_attachments_report_idx" ON "public"."daily_report_attachments" USING "btree" ("company_id", "daily_report_id", "created_at");



CREATE INDEX "daily_report_audit_events_company_created_idx" ON "public"."daily_report_audit_events" USING "btree" ("company_id", "created_at" DESC);



CREATE INDEX "daily_report_audit_events_report_created_idx" ON "public"."daily_report_audit_events" USING "btree" ("daily_report_id", "created_at" DESC);



CREATE INDEX "daily_report_jsas_company_work_date_idx" ON "public"."daily_report_jsas" USING "btree" ("company_id", "work_date" DESC);



CREATE INDEX "daily_report_units_company_idx" ON "public"."daily_report_units" USING "btree" ("company_id");



CREATE INDEX "daily_report_units_job_idx" ON "public"."daily_report_units" USING "btree" ("job_id");



CREATE INDEX "daily_report_units_report_idx" ON "public"."daily_report_units" USING "btree" ("report_id");



CREATE INDEX "daily_reports_company_archived_work_date_idx" ON "public"."daily_reports" USING "btree" ("company_id", "archived", "work_date" DESC);



CREATE INDEX "daily_reports_company_idx" ON "public"."daily_reports" USING "btree" ("company_id");



CREATE INDEX "daily_reports_date_idx" ON "public"."daily_reports" USING "btree" ("work_date");



CREATE INDEX "daily_reports_foreman_idx" ON "public"."daily_reports" USING "btree" ("foreman_id");



CREATE INDEX "daily_reports_job_idx" ON "public"."daily_reports" USING "btree" ("job_id");



CREATE INDEX "idx_jobs_company" ON "public"."jobs" USING "btree" ("company_id");



CREATE INDEX "idx_prices_company" ON "public"."unit_prices" USING "btree" ("company_id");



CREATE INDEX "idx_profiles_company" ON "public"."profiles" USING "btree" ("company_id");



CREATE INDEX "idx_report_units_company" ON "public"."report_units" USING "btree" ("company_id");



CREATE INDEX "idx_report_units_report" ON "public"."report_units" USING "btree" ("report_id");



CREATE INDEX "idx_reports_company" ON "public"."daily_reports" USING "btree" ("company_id");



CREATE INDEX "idx_reports_date" ON "public"."daily_reports" USING "btree" ("report_date");



CREATE INDEX "idx_reports_foreman" ON "public"."daily_reports" USING "btree" ("foreman_id");



CREATE INDEX "idx_reports_job" ON "public"."daily_reports" USING "btree" ("job_id");



CREATE INDEX "job_leader_assignments_company_job_idx" ON "public"."job_leader_assignments" USING "btree" ("company_id", "job_id");



CREATE INDEX "job_leader_assignments_company_member_idx" ON "public"."job_leader_assignments" USING "btree" ("company_id", "member_id");



CREATE INDEX "job_package_authorized_units_company_package_idx" ON "public"."job_package_authorized_units" USING "btree" ("company_id", "job_package_id");



CREATE INDEX "job_package_work_points_company_job_idx" ON "public"."job_package_work_points" USING "btree" ("company_id", "job_id");



CREATE INDEX "job_packages_company_contract_idx" ON "public"."job_packages" USING "btree" ("company_id", "contract_id");



CREATE INDEX "job_packages_company_job_idx" ON "public"."job_packages" USING "btree" ("company_id", "job_id", "created_at" DESC);



CREATE UNIQUE INDEX "job_packages_reference_unique" ON "public"."job_packages" USING "btree" ("company_id", "job_id", "lower"(TRIM(BOTH FROM "package_number"))) WHERE (("package_number" IS NOT NULL) AND ("length"(TRIM(BOTH FROM "package_number")) > 0));



CREATE INDEX "jobs_company_contract_idx" ON "public"."jobs" USING "btree" ("company_id", "contract_id");



CREATE INDEX "jobs_contract_id_idx" ON "public"."jobs" USING "btree" ("contract_id");



CREATE INDEX "jobs_customer_id_idx" ON "public"."jobs" USING "btree" ("customer_id");



CREATE INDEX "jobs_price_book_id_idx" ON "public"."jobs" USING "btree" ("price_book_id");



CREATE INDEX "price_book_items_company_id_idx" ON "public"."price_book_items" USING "btree" ("company_id");



CREATE INDEX "price_book_items_item_code_idx" ON "public"."price_book_items" USING "btree" ("item_code");



CREATE INDEX "price_book_items_price_book_id_idx" ON "public"."price_book_items" USING "btree" ("price_book_id");



CREATE INDEX "price_books_contract_id_idx" ON "public"."price_books" USING "btree" ("contract_id");



CREATE UNIQUE INDEX "price_books_one_active_version_per_family" ON "public"."price_books" USING "btree" ("company_id", COALESCE("contract_id", '00000000-0000-0000-0000-000000000000'::"uuid"), COALESCE("lower"("btrim"("name")), ''::"text")) WHERE ("active" IS TRUE);



CREATE INDEX "storm_mode_assignments_user_idx" ON "public"."storm_mode_assignments" USING "btree" ("user_id", "company_id");



CREATE OR REPLACE TRIGGER "daily_report_audit_event_trigger" AFTER INSERT OR UPDATE OF "status", "archived" ON "public"."daily_reports" FOR EACH ROW EXECUTE FUNCTION "public"."record_daily_report_audit_event"();



CREATE OR REPLACE TRIGGER "protect_daily_report_unit_history_trigger" BEFORE UPDATE ON "public"."daily_reports" FOR EACH ROW EXECUTE FUNCTION "public"."protect_daily_report_unit_history"();



CREATE OR REPLACE TRIGGER "trg_set_daily_report_date" BEFORE INSERT OR UPDATE ON "public"."daily_reports" FOR EACH ROW EXECUTE FUNCTION "public"."set_daily_report_date"();



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."company_settings"
    ADD CONSTRAINT "company_settings_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contract_field_settings"
    ADD CONSTRAINT "contract_field_settings_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contract_field_settings"
    ADD CONSTRAINT "contract_field_settings_contract_id_fkey" FOREIGN KEY ("contract_id") REFERENCES "public"."contracts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contract_field_settings"
    ADD CONSTRAINT "contract_field_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."crews"
    ADD CONSTRAINT "crews_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crews"
    ADD CONSTRAINT "crews_foreman_id_fkey" FOREIGN KEY ("foreman_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_daily_report_id_fkey" FOREIGN KEY ("daily_report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_price_book_item_id_fkey" FOREIGN KEY ("price_book_item_id") REFERENCES "public"."price_book_items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_production_items"
    ADD CONSTRAINT "daily_production_items_work_point_id_fkey" FOREIGN KEY ("work_point_id") REFERENCES "public"."work_points"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_daily_production_unit_id_fkey" FOREIGN KEY ("daily_production_unit_id") REFERENCES "public"."daily_production_units"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_daily_report_id_fkey" FOREIGN KEY ("daily_report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_unit_locations"
    ADD CONSTRAINT "daily_production_unit_locations_price_book_item_id_fkey" FOREIGN KEY ("price_book_item_id") REFERENCES "public"."price_book_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_contract_id_fkey" FOREIGN KEY ("contract_id") REFERENCES "public"."contracts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_daily_report_id_fkey" FOREIGN KEY ("daily_report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_price_book_id_fkey" FOREIGN KEY ("price_book_id") REFERENCES "public"."price_books"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_production_units"
    ADD CONSTRAINT "daily_production_units_price_book_item_id_fkey" FOREIGN KEY ("price_book_item_id") REFERENCES "public"."price_book_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_report_attachments"
    ADD CONSTRAINT "daily_report_attachments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_attachments"
    ADD CONSTRAINT "daily_report_attachments_daily_report_id_fkey" FOREIGN KEY ("daily_report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_attachments"
    ADD CONSTRAINT "daily_report_attachments_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_report_audit_events"
    ADD CONSTRAINT "daily_report_audit_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_report_audit_events"
    ADD CONSTRAINT "daily_report_audit_events_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_audit_events"
    ADD CONSTRAINT "daily_report_audit_events_daily_report_id_fkey" FOREIGN KEY ("daily_report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_jsas"
    ADD CONSTRAINT "daily_report_jsas_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_jsas"
    ADD CONSTRAINT "daily_report_jsas_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_report_jsas"
    ADD CONSTRAINT "daily_report_jsas_daily_report_id_fkey" FOREIGN KEY ("daily_report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_jsas"
    ADD CONSTRAINT "daily_report_jsas_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_units"
    ADD CONSTRAINT "daily_report_units_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_report_units"
    ADD CONSTRAINT "daily_report_units_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_report_units"
    ADD CONSTRAINT "daily_report_units_report_id_fkey" FOREIGN KEY ("report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_crew_id_fkey" FOREIGN KEY ("crew_id") REFERENCES "public"."crews"("id");



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_foreman_id_fkey" FOREIGN KEY ("foreman_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_price_book_id_fkey" FOREIGN KEY ("price_book_id") REFERENCES "public"."price_books"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_redline_override_by_fkey" FOREIGN KEY ("redline_override_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."daily_reports"
    ADD CONSTRAINT "daily_reports_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_crew_id_fkey" FOREIGN KEY ("crew_id") REFERENCES "public"."crews"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."job_leader_assignments"
    ADD CONSTRAINT "job_leader_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."job_leader_assignments"
    ADD CONSTRAINT "job_leader_assignments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_leader_assignments"
    ADD CONSTRAINT "job_leader_assignments_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_leader_assignments"
    ADD CONSTRAINT "job_leader_assignments_member_id_fkey" FOREIGN KEY ("member_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_job_package_id_fkey" FOREIGN KEY ("job_package_id") REFERENCES "public"."job_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_price_book_item_id_fkey" FOREIGN KEY ("price_book_item_id") REFERENCES "public"."price_book_items"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."job_package_authorized_units"
    ADD CONSTRAINT "job_package_authorized_units_work_point_id_fkey" FOREIGN KEY ("work_point_id") REFERENCES "public"."job_package_work_points"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_package_work_points"
    ADD CONSTRAINT "job_package_work_points_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_package_work_points"
    ADD CONSTRAINT "job_package_work_points_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."job_package_work_points"
    ADD CONSTRAINT "job_package_work_points_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_package_work_points"
    ADD CONSTRAINT "job_package_work_points_job_package_id_fkey" FOREIGN KEY ("job_package_id") REFERENCES "public"."job_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_packages"
    ADD CONSTRAINT "job_packages_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_packages"
    ADD CONSTRAINT "job_packages_contract_id_fkey" FOREIGN KEY ("contract_id") REFERENCES "public"."contracts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."job_packages"
    ADD CONSTRAINT "job_packages_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."job_packages"
    ADD CONSTRAINT "job_packages_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_contract_id_fkey" FOREIGN KEY ("contract_id") REFERENCES "public"."contracts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_price_book_id_fkey" FOREIGN KEY ("price_book_id") REFERENCES "public"."price_books"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."price_book_items"
    ADD CONSTRAINT "price_book_items_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_book_items"
    ADD CONSTRAINT "price_book_items_price_book_id_fkey" FOREIGN KEY ("price_book_id") REFERENCES "public"."price_books"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_books"
    ADD CONSTRAINT "price_books_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_books"
    ADD CONSTRAINT "price_books_contract_id_fkey" FOREIGN KEY ("contract_id") REFERENCES "public"."contracts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."price_books"
    ADD CONSTRAINT "price_books_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."report_units"
    ADD CONSTRAINT "report_units_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."report_units"
    ADD CONSTRAINT "report_units_report_id_fkey" FOREIGN KEY ("report_id") REFERENCES "public"."daily_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."storm_mode_assignments"
    ADD CONSTRAINT "storm_mode_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."storm_mode_assignments"
    ADD CONSTRAINT "storm_mode_assignments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."storm_mode_assignments"
    ADD CONSTRAINT "storm_mode_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."unit_prices"
    ADD CONSTRAINT "unit_prices_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."unit_prices"
    ADD CONSTRAINT "unit_prices_price_book_id_fkey" FOREIGN KEY ("price_book_id") REFERENCES "public"."price_books"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_points"
    ADD CONSTRAINT "work_points_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_points"
    ADD CONSTRAINT "work_points_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."work_points"
    ADD CONSTRAINT "work_points_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can delete contracts" ON "public"."contracts" FOR DELETE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can delete customers" ON "public"."customers" FOR DELETE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can delete price book items" ON "public"."price_book_items" FOR DELETE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can delete production items" ON "public"."daily_production_items" FOR DELETE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can insert contracts" ON "public"."contracts" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can insert customers" ON "public"."customers" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can insert price book items" ON "public"."price_book_items" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text"))))));



CREATE POLICY "Admins can update contracts" ON "public"."contracts" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text")))))) WITH CHECK (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Admins can update customers" ON "public"."customers" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text")))))) WITH CHECK (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Admins can update price book items" ON "public"."price_book_items" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."company_id" = "public"."my_company_id"()) AND ("lower"("profiles"."role") = 'admin'::"text")))))) WITH CHECK (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Company members can view contracts" ON "public"."contracts" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Company members can view customers" ON "public"."customers" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Company members can view price book items" ON "public"."price_book_items" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Company users can create production items" ON "public"."daily_production_items" FOR INSERT TO "authenticated" WITH CHECK (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Company users can update production items" ON "public"."daily_production_items" FOR UPDATE TO "authenticated" USING (("company_id" = "public"."my_company_id"())) WITH CHECK (("company_id" = "public"."my_company_id"()));



CREATE POLICY "Company users can view production items" ON "public"."daily_production_items" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "active_profile_required" ON "public"."companies" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."contracts" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."customers" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."daily_reports" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."jobs" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."price_book_items" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."price_books" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "active_profile_required" ON "public"."profiles" AS RESTRICTIVE TO "authenticated" USING (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile")) WITH CHECK (( SELECT "public"."current_user_has_active_profile"() AS "current_user_has_active_profile"));



CREATE POLICY "audit_admin_select" ON "public"."audit_log" FOR SELECT TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text")));



ALTER TABLE "public"."audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."companies" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "company members read daily reports" ON "public"."daily_reports" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "company members read daily units" ON "public"."daily_report_units" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "company_admin_update" ON "public"."companies" FOR UPDATE TO "authenticated" USING ((("id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text")));



CREATE POLICY "company_same_company_select" ON "public"."companies" FOR SELECT TO "authenticated" USING ((("id" = "public"."my_company_id"()) OR ("created_by" = "auth"."uid"())));



ALTER TABLE "public"."company_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contract_field_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contracts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "crews_admin_gf_insert" ON "public"."crews" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "crews_admin_gf_update" ON "public"."crews" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "crews_same_company_select" ON "public"."crews" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_production_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_production_unit_locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_production_units" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_report_attachments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "daily_report_attachments_company_select" ON "public"."daily_report_attachments" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "profile"."company_id"
   FROM "public"."profiles" "profile"
  WHERE ("profile"."id" = "auth"."uid"()))));



ALTER TABLE "public"."daily_report_audit_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_report_jsas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "daily_report_jsas_same_company_select" ON "public"."daily_report_jsas" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "p"."company_id"
   FROM "public"."profiles" "p"
  WHERE ("p"."id" = "auth"."uid"()))));



ALTER TABLE "public"."daily_report_units" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employees_admin_gf_manage" ON "public"."employees" TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"])))) WITH CHECK ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "employees_same_company_select" ON "public"."employees" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



ALTER TABLE "public"."job_leader_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "job_leader_assignments_same_company_select" ON "public"."job_leader_assignments" FOR SELECT TO "authenticated" USING (("company_id" = ( SELECT "profile"."company_id"
   FROM "public"."profiles" "profile"
  WHERE (("profile"."id" = "auth"."uid"()) AND ("profile"."active" IS TRUE)))));



ALTER TABLE "public"."job_package_authorized_units" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_package_work_points" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_packages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "jobs_admin_gf_manage" ON "public"."jobs" TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"])))) WITH CHECK ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "jobs_same_company_select" ON "public"."jobs" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



ALTER TABLE "public"."price_book_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."price_books" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "price_books_admin_manage" ON "public"."price_books" TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text"))) WITH CHECK ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text")));



CREATE POLICY "price_books_same_company_select" ON "public"."price_books" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_admin_update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text")));



CREATE POLICY "profiles_same_company_select" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) OR ("id" = "auth"."uid"())));



ALTER TABLE "public"."report_units" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "report_units_admin_gf_delete" ON "public"."report_units" FOR DELETE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "report_units_admin_gf_update" ON "public"."report_units" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "report_units_company_select" ON "public"."report_units" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



CREATE POLICY "report_units_foreman_insert" ON "public"."report_units" FOR INSERT TO "authenticated" WITH CHECK (("company_id" = "public"."my_company_id"()));



CREATE POLICY "reports_admin_gf_delete" ON "public"."daily_reports" FOR DELETE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "reports_admin_gf_update" ON "public"."daily_reports" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"]))));



CREATE POLICY "reports_company_select" ON "public"."daily_reports" FOR SELECT TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND (("public"."my_role"() = ANY (ARRAY['admin'::"text", 'gf'::"text"])) OR ("foreman_id" = "auth"."uid"()))));



CREATE POLICY "reports_foreman_insert" ON "public"."daily_reports" FOR INSERT TO "authenticated" WITH CHECK ((("company_id" = "public"."my_company_id"()) AND ("foreman_id" = "auth"."uid"())));



CREATE POLICY "settings_admin_update" ON "public"."company_settings" FOR UPDATE TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text")));



CREATE POLICY "settings_same_company_select" ON "public"."company_settings" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



ALTER TABLE "public"."storm_mode_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."unit_prices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "unit_prices_admin_manage" ON "public"."unit_prices" TO "authenticated" USING ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text"))) WITH CHECK ((("company_id" = "public"."my_company_id"()) AND ("public"."my_role"() = 'admin'::"text")));



CREATE POLICY "unit_prices_same_company_select" ON "public"."unit_prices" FOR SELECT TO "authenticated" USING (("company_id" = "public"."my_company_id"()));



ALTER TABLE "public"."work_points" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_daily_report_unit"("p_report_id" "uuid", "p_work_point" "text", "p_unit_code" "text", "p_description" "text", "p_installed_qty" numeric, "p_retired_qty" numeric, "p_install_unit_price" numeric, "p_retire_unit_price" numeric, "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_daily_report_unit"("p_report_id" "uuid", "p_work_point" "text", "p_unit_code" "text", "p_description" "text", "p_installed_qty" numeric, "p_retired_qty" numeric, "p_install_unit_price" numeric, "p_retire_unit_price" numeric, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_daily_report_unit"("p_report_id" "uuid", "p_work_point" "text", "p_unit_code" "text", "p_description" "text", "p_installed_qty" numeric, "p_retired_qty" numeric, "p_install_unit_price" numeric, "p_retire_unit_price" numeric, "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_price_book"("p_name" "text", "p_customer_name" "text", "p_utility_name" "text", "p_effective_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_price_book"("p_name" "text", "p_customer_name" "text", "p_utility_name" "text", "p_effective_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_price_book"("p_name" "text", "p_customer_name" "text", "p_utility_name" "text", "p_effective_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_delete_price_book"("p_price_book_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_price_book"("p_price_book_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_price_book"("p_price_book_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_delete_unit_price"("p_unit_price_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_unit_price"("p_unit_price_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_unit_price"("p_unit_price_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_save_unit_price"("p_price_book_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_save_unit_price"("p_price_book_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_save_unit_price"("p_price_book_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_company_settings"("p_adjustment_enabled" boolean, "p_adjustment_percent" numeric, "p_adjustment_label" "text", "p_primary_color" "text", "p_secondary_color" "text", "p_logo_url" "text", "p_gf_can_edit_reports" boolean, "p_gf_can_delete_reports" boolean, "p_location_label" "text", "p_job_label" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_company_settings"("p_adjustment_enabled" boolean, "p_adjustment_percent" numeric, "p_adjustment_label" "text", "p_primary_color" "text", "p_secondary_color" "text", "p_logo_url" "text", "p_gf_can_edit_reports" boolean, "p_gf_can_delete_reports" boolean, "p_location_label" "text", "p_job_label" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_company_settings"("p_adjustment_enabled" boolean, "p_adjustment_percent" numeric, "p_adjustment_label" "text", "p_primary_color" "text", "p_secondary_color" "text", "p_logo_url" "text", "p_gf_can_edit_reports" boolean, "p_gf_can_delete_reports" boolean, "p_location_label" "text", "p_job_label" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_unit_price"("p_unit_price_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric, "p_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_unit_price"("p_unit_price_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric, "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_unit_price"("p_unit_price_id" "uuid", "p_unit" "text", "p_description" "text", "p_install" numeric, "p_remove" numeric, "p_transfer" numeric, "p_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_user"("target_user_id" "uuid", "new_role" "text", "new_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_user"("target_user_id" "uuid", "new_role" "text", "new_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_user"("target_user_id" "uuid", "new_role" "text", "new_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_daily_report"("p_report_id" "uuid", "p_review_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_daily_report"("p_report_id" "uuid", "p_review_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_daily_report"("p_report_id" "uuid", "p_review_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_review_daily_reports"() TO "anon";
GRANT ALL ON FUNCTION "public"."can_review_daily_reports"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_review_daily_reports"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_company"("company_name" "text", "admin_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_company"("company_name" "text", "admin_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_company"("company_name" "text", "admin_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_contract_job"("p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_contract_job"("p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_contract_job"("p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_daily_report"("p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_daily_report"("p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_daily_report"("p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_job"("p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_job"("p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_job"("p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_job_package"("p_job_id" "uuid", "p_package_name" "text", "p_package_number" "text", "p_received_date" "date", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_job_package"("p_job_id" "uuid", "p_package_name" "text", "p_package_number" "text", "p_received_date" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_job_package"("p_job_id" "uuid", "p_package_name" "text", "p_package_number" "text", "p_received_date" "date", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_job_package_work_point"("p_package_id" "uuid", "p_work_point_code" "text", "p_description" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_job_package_work_point"("p_package_id" "uuid", "p_work_point_code" "text", "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_job_package_work_point"("p_package_id" "uuid", "p_work_point_code" "text", "p_description" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_standalone_jsa"("p_job_id" "uuid", "p_work_date" "date", "p_crew_name" "text", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_weather_conditions" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_standalone_jsa"("p_job_id" "uuid", "p_work_date" "date", "p_crew_name" "text", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_weather_conditions" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_standalone_jsa"("p_job_id" "uuid", "p_work_date" "date", "p_crew_name" "text", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_weather_conditions" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."current_user_has_active_profile"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_user_has_active_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_has_active_profile"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_daily_report_attachment"("p_attachment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_daily_report_attachment"("p_attachment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_daily_report_attachment"("p_attachment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_daily_report_unit"("p_unit_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_daily_report_unit"("p_unit_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_daily_report_unit"("p_unit_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_draft_daily_report"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_draft_daily_report"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_draft_daily_report"("p_report_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_job"("p_job_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_job"("p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_job"("p_job_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_job_package"("p_package_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_job_package"("p_package_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_job_package"("p_package_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_job_package_authorized_unit"("p_authorized_unit_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_job_package_authorized_unit"("p_authorized_unit_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_job_package_authorized_unit"("p_authorized_unit_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_job_package_work_point"("p_work_point_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_job_package_work_point"("p_work_point_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_job_package_work_point"("p_work_point_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_assignable_job_leaders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_assignable_job_leaders"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_assignable_job_leaders"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_company_jsas"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_company_jsas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_company_jsas"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_contract_field_settings"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_contract_field_settings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_contract_field_settings"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_report_audit_history"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_report_audit_history"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_report_audit_history"("p_report_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_report_authorization_summaries"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_report_authorization_summaries"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_report_authorization_summaries"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_report_jsa"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_report_jsa"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_report_jsa"("p_report_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_report_unit_catalog"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_report_unit_catalog"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_report_unit_catalog"("p_report_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_report_unit_locations"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_report_unit_locations"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_report_unit_locations"("p_report_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_report_value_summaries"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_report_value_summaries"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_report_value_summaries"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_daily_unit_usage_memory"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_daily_unit_usage_memory"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_unit_usage_memory"("p_report_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_job_leader_assignments"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_job_leader_assignments"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_job_leader_assignments"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_job_package_work_points"("p_package_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_job_package_work_points"("p_package_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_job_package_work_points"("p_package_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_job_packages"("p_job_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_job_packages"("p_job_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_job_packages"("p_job_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_job_progress_dashboard"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_job_progress_dashboard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_job_progress_dashboard"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_price_book_items_for_user"("p_price_book_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_price_book_items_for_user"("p_price_book_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_price_book_items_for_user"("p_price_book_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_storm_mode_assignments"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_storm_mode_assignments"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_storm_mode_assignments"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."import_job_package_units"("p_package_id" "uuid", "p_rows" "jsonb", "p_source_filename" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."import_job_package_units"("p_package_id" "uuid", "p_rows" "jsonb", "p_source_filename" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."import_job_package_units"("p_package_id" "uuid", "p_rows" "jsonb", "p_source_filename" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_current_user_in_storm_mode"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_current_user_in_storm_mode"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_current_user_in_storm_mode"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_my_profile_suspended"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_my_profile_suspended"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_my_profile_suspended"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."join_company"("company_code" "text", "user_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."join_company"("company_code" "text", "user_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."join_company"("company_code" "text", "user_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."my_company_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_company_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_company_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."my_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_role"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."normalize_work_point_key"("p_value" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."normalize_work_point_key"("p_value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_work_point_key"("p_value" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."protect_daily_report_unit_history"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."protect_daily_report_unit_history"() TO "service_role";



GRANT ALL ON FUNCTION "public"."record_daily_report_audit_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."record_daily_report_audit_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_daily_report_audit_event"() TO "service_role";



GRANT ALL ON TABLE "public"."daily_report_attachments" TO "anon";
GRANT ALL ON TABLE "public"."daily_report_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_report_attachments" TO "service_role";



REVOKE ALL ON FUNCTION "public"."register_daily_report_attachment"("p_report_id" "uuid", "p_storage_path" "text", "p_original_filename" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_caption" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_daily_report_attachment"("p_report_id" "uuid", "p_storage_path" "text", "p_original_filename" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_caption" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_daily_report_attachment"("p_report_id" "uuid", "p_storage_path" "text", "p_original_filename" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_caption" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."return_daily_report"("p_report_id" "uuid", "p_review_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."return_daily_report"("p_report_id" "uuid", "p_review_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."return_daily_report"("p_report_id" "uuid", "p_review_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."review_daily_report"("p_report_id" "uuid", "p_approved" boolean, "p_review_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."review_daily_report"("p_report_id" "uuid", "p_approved" boolean, "p_review_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."review_daily_report"("p_report_id" "uuid", "p_approved" boolean, "p_review_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."rotate_company_join_code"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rotate_company_join_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rotate_company_join_code"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_daily_report_jsa"("p_report_id" "uuid", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_daily_report_jsa"("p_report_id" "uuid", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_daily_report_jsa"("p_report_id" "uuid", "p_job_briefing" "text", "p_hazards" "text", "p_controls" "text", "p_ppe" "text", "p_emergency_plan" "text", "p_crew_members" "text", "p_special_equipment" "text", "p_foreman_acknowledged" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_install_quantity" numeric, "p_retirement_quantity" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_install_quantity" numeric, "p_retirement_quantity" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_daily_report_unit"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_install_quantity" numeric, "p_retirement_quantity" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_daily_report_unit_location"("p_report_id" "uuid", "p_price_book_item_id" "uuid", "p_pole_location" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_job_package_authorized_unit"("p_work_point_id" "uuid", "p_unit_code" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_job_package_authorized_unit"("p_work_point_id" "uuid", "p_unit_code" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_job_package_authorized_unit"("p_work_point_id" "uuid", "p_unit_code" "text", "p_install_quantity" numeric, "p_retirement_quantity" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_company_member_active"("p_member_id" "uuid", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_company_member_active"("p_member_id" "uuid", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_company_member_active"("p_member_id" "uuid", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_company_member_role"("p_member_id" "uuid", "p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_company_member_role"("p_member_id" "uuid", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_company_member_role"("p_member_id" "uuid", "p_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_company_redline_approval_requirement"("p_required" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_company_redline_approval_requirement"("p_required" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_company_redline_approval_requirement"("p_required" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_company_storm_mode"("p_enabled" boolean, "p_event_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_company_storm_mode"("p_enabled" boolean, "p_event_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_company_storm_mode"("p_enabled" boolean, "p_event_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_contract_field_value_percent"("p_contract_id" "uuid", "p_field_value_percent" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_contract_field_value_percent"("p_contract_id" "uuid", "p_field_value_percent" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_contract_field_value_percent"("p_contract_id" "uuid", "p_field_value_percent" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_daily_report_archived"("p_report_id" "uuid", "p_archived" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_daily_report_archived"("p_report_id" "uuid", "p_archived" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_daily_report_archived"("p_report_id" "uuid", "p_archived" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_daily_report_context"("p_report_id" "uuid", "p_weather_conditions" "text", "p_delay_hours" numeric, "p_delay_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_daily_report_context"("p_report_id" "uuid", "p_weather_conditions" "text", "p_delay_hours" numeric, "p_delay_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_daily_report_context"("p_report_id" "uuid", "p_weather_conditions" "text", "p_delay_hours" numeric, "p_delay_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_daily_report_date"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_daily_report_date"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_daily_report_date"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_daily_report_storm_context"("p_report_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_daily_report_storm_context"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_daily_report_storm_context"("p_report_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_job_active"("p_job_id" "uuid", "p_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_job_active"("p_job_id" "uuid", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_job_active"("p_job_id" "uuid", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_job_leader_assignment"("p_job_id" "uuid", "p_member_id" "uuid", "p_assigned" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_job_leader_assignment"("p_job_id" "uuid", "p_member_id" "uuid", "p_assigned" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_job_leader_assignment"("p_job_id" "uuid", "p_member_id" "uuid", "p_assigned" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_job_package_status"("p_package_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_job_package_status"("p_package_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_job_package_status"("p_package_id" "uuid", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_price_book_active"("p_price_book_id" "uuid", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_price_book_active"("p_price_book_id" "uuid", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_price_book_active"("p_price_book_id" "uuid", "p_active" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_storm_mode_assignments"("p_user_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_storm_mode_assignments"("p_user_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_storm_mode_assignments"("p_user_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_daily_report"("p_report_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_daily_report"("p_report_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_daily_report"("p_report_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_company_settings"("p_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_logo_url" "text", "p_primary_color" "text", "p_timezone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_company_settings"("p_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_logo_url" "text", "p_primary_color" "text", "p_timezone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_company_settings"("p_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_logo_url" "text", "p_primary_color" "text", "p_timezone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_contract_job"("p_job_id" "uuid", "p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_contract_job"("p_job_id" "uuid", "p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_contract_job"("p_job_id" "uuid", "p_contract_id" "uuid", "p_job_number" "text", "p_job_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_daily_report"("p_report_id" "uuid", "p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_daily_report"("p_report_id" "uuid", "p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_daily_report"("p_report_id" "uuid", "p_job_id" "uuid", "p_work_date" "date", "p_regular_hours" numeric, "p_overtime_hours" numeric, "p_crew_name" "text", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_job"("p_job_id" "uuid", "p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_job"("p_job_id" "uuid", "p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_job"("p_job_id" "uuid", "p_job_number" "text", "p_job_name" "text", "p_customer_name" "text", "p_utility_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."validate_job_package_import"("p_package_id" "uuid", "p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_job_package_import"("p_package_id" "uuid", "p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_job_package_import"("p_package_id" "uuid", "p_rows" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."audit_log" TO "anon";
GRANT ALL ON TABLE "public"."audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."audit_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."audit_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."audit_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."companies" TO "anon";
GRANT ALL ON TABLE "public"."companies" TO "authenticated";
GRANT ALL ON TABLE "public"."companies" TO "service_role";



GRANT ALL ON TABLE "public"."company_settings" TO "anon";
GRANT ALL ON TABLE "public"."company_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."company_settings" TO "service_role";



GRANT ALL ON TABLE "public"."contract_field_settings" TO "service_role";



GRANT ALL ON TABLE "public"."contracts" TO "anon";
GRANT ALL ON TABLE "public"."contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."contracts" TO "service_role";



GRANT ALL ON TABLE "public"."crews" TO "anon";
GRANT ALL ON TABLE "public"."crews" TO "authenticated";
GRANT ALL ON TABLE "public"."crews" TO "service_role";



GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";



GRANT ALL ON TABLE "public"."daily_production_items" TO "anon";
GRANT ALL ON TABLE "public"."daily_production_items" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_production_items" TO "service_role";



GRANT ALL ON TABLE "public"."daily_production_unit_locations" TO "service_role";



GRANT ALL ON TABLE "public"."daily_production_units" TO "service_role";



GRANT ALL ON TABLE "public"."daily_report_audit_events" TO "service_role";



GRANT ALL ON TABLE "public"."daily_report_jsas" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_report_jsas" TO "service_role";



GRANT ALL ON TABLE "public"."daily_report_units" TO "anon";
GRANT ALL ON TABLE "public"."daily_report_units" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_report_units" TO "service_role";



GRANT ALL ON TABLE "public"."daily_reports" TO "anon";
GRANT ALL ON TABLE "public"."daily_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_reports" TO "service_role";



GRANT ALL ON TABLE "public"."employees" TO "anon";
GRANT ALL ON TABLE "public"."employees" TO "authenticated";
GRANT ALL ON TABLE "public"."employees" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."job_leader_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."job_leader_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."job_package_authorized_units" TO "service_role";



GRANT ALL ON TABLE "public"."job_package_work_points" TO "service_role";



GRANT ALL ON TABLE "public"."job_packages" TO "service_role";



GRANT ALL ON TABLE "public"."jobs" TO "anon";
GRANT ALL ON TABLE "public"."jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."jobs" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."price_book_items" TO "anon";
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."price_book_items" TO "authenticated";
GRANT ALL ON TABLE "public"."price_book_items" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("company_id") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("price_book_id") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("item_code") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("item_name") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("description") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("unit_of_measure") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("category") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("extra_data") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("active") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT SELECT("updated_at") ON TABLE "public"."price_book_items" TO "authenticated";



GRANT ALL ON TABLE "public"."price_books" TO "anon";
GRANT ALL ON TABLE "public"."price_books" TO "authenticated";
GRANT ALL ON TABLE "public"."price_books" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."report_units" TO "anon";
GRANT ALL ON TABLE "public"."report_units" TO "authenticated";
GRANT ALL ON TABLE "public"."report_units" TO "service_role";



GRANT ALL ON TABLE "public"."storm_mode_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."unit_prices" TO "anon";
GRANT ALL ON TABLE "public"."unit_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."unit_prices" TO "service_role";



GRANT ALL ON TABLE "public"."work_points" TO "anon";
GRANT ALL ON TABLE "public"."work_points" TO "authenticated";
GRANT ALL ON TABLE "public"."work_points" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







