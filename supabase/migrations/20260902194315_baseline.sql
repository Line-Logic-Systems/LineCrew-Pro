-- LineCrew Pro production schema baseline
-- Generated from project ldgkyxuozbozgkvwzadg with PostgreSQL 17 pg_dump --schema-only.
-- Supabase-managed schemas are not recreated; only public plus LineCrew-owned Auth/Storage objects are included.
--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: accept_team_invitation(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.accept_team_invitation(p_token_hash text, p_user_name text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  invitation public.team_invitations%rowtype;
  authenticated_email text;
  normalized_name text := btrim(coalesce(p_user_name, ''));
  v_role text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in before accepting an invitation.';
  end if;
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid invitation link.';
  end if;
  if length(normalized_name) < 2 or length(normalized_name) > 120 then
    raise exception using errcode = '22023', message = 'Enter your full name.';
  end if;
  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '23505', message = 'This account already belongs to a company.';
  end if;

  select lower(email) into authenticated_email from auth.users where id = auth.uid();
  select * into invitation
  from public.team_invitations
  where token_hash = lower(p_token_hash)
    and accepted_at is null
    and expires_at > now()
  for update;

  if invitation.id is null then
    raise exception using errcode = 'P0002', message = 'This invitation is invalid, expired, or already used.';
  end if;
  if authenticated_email is null or authenticated_email <> lower(invitation.email) then
    raise exception using errcode = '42501', message = 'Sign in with the email address that received this invitation.';
  end if;

  v_role := lower(coalesce(invitation.intended_role, 'foreman'));
  if v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode = '22023', message = 'Invalid invitation role.';
  end if;

  insert into public.profiles (id, company_id, full_name, role, active)
  values (auth.uid(), invitation.company_id, normalized_name, v_role, true);

  update public.team_invitations
  set accepted_at = now(), accepted_by = auth.uid()
  where id = invitation.id;
end;
$_$;


--
-- Name: activate_finalized_utility_packet_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activate_finalized_utility_packet_revision() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.status = 'imported' and old.status is distinct from new.status then
    update public.job_packages package
    set status = 'active', updated_at = now()
    where package.id = new.job_package_id
      and package.company_id = new.company_id
      and package.status is distinct from 'active';
  end if;
  return new;
end;
$$;


--
-- Name: add_daily_report_unit(uuid, text, text, text, numeric, numeric, numeric, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_daily_report_unit(p_report_id uuid, p_work_point text, p_unit_code text, p_description text DEFAULT NULL::text, p_installed_qty numeric DEFAULT 0, p_retired_qty numeric DEFAULT 0, p_install_unit_price numeric DEFAULT NULL::numeric, p_retire_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_create_price_book(text, text, text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_create_price_book(p_name text, p_customer_name text, p_utility_name text, p_effective_date date) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_delete_price_book(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_price_book(p_price_book_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_delete_unit_price(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_unit_price(p_unit_price_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_import_timekeeping_roster(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_import_timekeeping_roster(p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_row jsonb;
  v_employee_number text;
  v_full_name text;
  v_classification text;
  v_default_crew text;
  v_existing_id uuid;
  v_inserted integer := 0;
  v_updated integer := 0;
begin
  select p.company_id, lower(coalesce(p.role, '')) into v_company_id, v_role
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_role not in ('admin','owner') then
    raise exception using errcode='42501', message='Only a company Owner or Admin can import the employee roster.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode='22023', message='Roster rows must be an array.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_employee_number := nullif(btrim(coalesce(v_row->>'employee_number','')), '');
    v_full_name := nullif(btrim(coalesce(v_row->>'full_name','')), '');
    v_classification := nullif(btrim(coalesce(v_row->>'classification','')), '');
    v_default_crew := nullif(btrim(coalesce(v_row->>'default_crew_name','')), '');
    if v_full_name is null then continue; end if;

    v_existing_id := null;
    if v_employee_number is not null then
      select e.id into v_existing_id from public.timekeeping_employees e
      where e.company_id = v_company_id
        and lower(coalesce(e.employee_number,'')) = lower(v_employee_number)
      limit 1;
    end if;
    if v_existing_id is null then
      select e.id into v_existing_id from public.timekeeping_employees e
      where e.company_id = v_company_id and lower(e.full_name) = lower(v_full_name)
      limit 1;
    end if;

    if v_existing_id is null then
      insert into public.timekeeping_employees(
        company_id, employee_number, full_name, classification, default_crew_name, active, created_by
      ) values (
        v_company_id, v_employee_number, v_full_name, v_classification, v_default_crew, true, auth.uid()
      );
      v_inserted := v_inserted + 1;
    else
      update public.timekeeping_employees
      set employee_number = coalesce(v_employee_number, employee_number), full_name = v_full_name,
          classification = coalesce(v_classification, classification),
          default_crew_name = coalesce(v_default_crew, default_crew_name), active = true, updated_at = now()
      where id = v_existing_id;
      v_updated := v_updated + 1;
    end if;
  end loop;
  return jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
end;
$$;


--
-- Name: admin_save_unit_price(uuid, text, text, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save_unit_price(p_price_book_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_update_company_settings(boolean, numeric, text, text, text, text, boolean, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_company_settings(p_adjustment_enabled boolean, p_adjustment_percent numeric, p_adjustment_label text, p_primary_color text, p_secondary_color text, p_logo_url text, p_gf_can_edit_reports boolean, p_gf_can_delete_reports boolean, p_location_label text, p_job_label text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_update_timekeeping_entry(uuid, uuid, time without time zone, time without time zone, integer, numeric, numeric, boolean, text, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_timekeeping_entry(p_daily_report_id uuid, p_employee_id uuid, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_regular_hours numeric, p_overtime_hours numeric, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_profile public.profiles%rowtype;
  v_entry public.timekeeping_entries%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_elapsed_minutes numeric;
  v_worked_hours numeric;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Not authenticated.';
  end if;
  select * into v_profile from public.profiles p where p.id = auth.uid();
  if v_profile.id is null or coalesce(v_profile.active,true) is not true or lower(coalesce(v_profile.role,'')) not in ('owner','admin') then
    raise exception using errcode='42501', message='Only an active Owner or Admin can edit submitted time.';
  end if;
  if p_lunch_minutes is null or p_lunch_minutes < 0 or p_lunch_minutes > 720 then
    raise exception using errcode='22023', message='Lunch must be between 0 and 720 minutes.';
  end if;
  if (p_start_time is null) <> (p_stop_time is null) then
    raise exception using errcode='22023', message='Enter both Start and Stop, or leave both blank.';
  end if;
  select e.* into v_entry
  from public.timekeeping_entries e
  join public.daily_reports r on r.id=e.daily_report_id and r.company_id=e.company_id
  where e.company_id=v_profile.company_id and e.daily_report_id=p_daily_report_id and e.employee_id=p_employee_id
  for update;
  if v_entry.id is null then
    raise exception using errcode='P0002', message='Time entry was not found in your company.';
  end if;
  if p_start_time is not null then
    v_elapsed_minutes := extract(epoch from (p_stop_time - p_start_time)) / 60.0;
    if v_elapsed_minutes < 0 then v_elapsed_minutes := v_elapsed_minutes + 1440; end if;
    v_elapsed_minutes := v_elapsed_minutes - p_lunch_minutes;
    if v_elapsed_minutes < 0 then
      raise exception using errcode='22023', message='Lunch cannot exceed the elapsed shift time.';
    end if;
    v_worked_hours := round((v_elapsed_minutes / 60.0)::numeric, 2);
  else
    v_worked_hours := greatest(0, least(24, coalesce(p_regular_hours,0) + coalesce(p_overtime_hours,0)));
  end if;
  if v_worked_hours > 24 then
    raise exception using errcode='22023', message='Worked hours cannot exceed 24 hours.';
  end if;
  v_before := jsonb_build_object('start_time',v_entry.start_time,'stop_time',v_entry.stop_time,'lunch_minutes',v_entry.lunch_minutes,'regular_hours',v_entry.regular_hours,'overtime_hours',v_entry.overtime_hours,'per_diem',v_entry.per_diem,'equipment_used',v_entry.equipment_used,'equipment_not_used',v_entry.equipment_not_used);
  update public.timekeeping_entries e
  set start_time=p_start_time, stop_time=p_stop_time, lunch_minutes=p_lunch_minutes,
      regular_hours=v_worked_hours, overtime_hours=0,
      per_diem=coalesce(p_per_diem,false),
      equipment_used=case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
      equipment_not_used=coalesce(p_equipment_not_used,false), updated_by=auth.uid(), updated_at=now()
  where e.id=v_entry.id;
  perform public.recalculate_timekeeping_employee_week(p_daily_report_id,p_employee_id);
  select e.* into v_entry from public.timekeeping_entries e where e.id=v_entry.id;
  v_after := jsonb_build_object('start_time',v_entry.start_time,'stop_time',v_entry.stop_time,'lunch_minutes',v_entry.lunch_minutes,'regular_hours',v_entry.regular_hours,'overtime_hours',v_entry.overtime_hours,'per_diem',v_entry.per_diem,'equipment_used',v_entry.equipment_used,'equipment_not_used',v_entry.equipment_not_used);
  insert into public.timekeeping_edit_audit(company_id,timekeeping_entry_id,daily_report_id,employee_id,work_date,edited_by,reason,before_values,after_values)
  values (v_entry.company_id,v_entry.id,v_entry.daily_report_id,v_entry.employee_id,v_entry.work_date,auth.uid(),nullif(btrim(coalesce(p_reason,'')),''),v_before,v_after);
end;
$$;


--
-- Name: admin_update_unit_price(uuid, text, text, numeric, numeric, numeric, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_unit_price(p_unit_price_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric, p_active boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: admin_update_user(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_user(target_user_id uuid, new_role text, new_active boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: approve_daily_report(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.approve_daily_report(p_report_id uuid, p_review_notes text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_status text;
  v_report_creator uuid;
  v_report_foreman uuid;
  v_require_gf boolean;
  v_redline_count bigint;
  v_existing_notes text;
  v_new_note text;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can approve reports.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;

  select report.company_id, lower(coalesce(report.status, 'draft')),
         report.created_by, report.foreman_id, report.review_notes
  into v_report_company_id, v_report_status, v_report_creator,
       v_report_foreman, v_existing_notes
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

  if auth.uid() = v_report_creator or auth.uid() = v_report_foreman then
    raise exception using errcode = '42501',
      message = 'A Daily Report must be approved by someone other than its author or Foreman.';
  end if;

  select company.require_gf_redline_approval
  into v_require_gf
  from public.companies company
  where company.id = v_company_id;

  select count(*)
  into v_redline_count
  from public.get_daily_report_unit_locations_v2(p_report_id) location
  where location.authorization_status = 'redline';

  v_new_note := nullif(btrim(coalesce(p_review_notes, '')), '');

  if coalesce(v_require_gf, false) and v_redline_count > 0 and
     v_role in ('admin', 'owner', 'superintendent') and v_new_note is null then
    raise exception using errcode = '22023',
      message = 'Enter an override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set status = 'approved',
      review_notes = case
        when v_new_note is null then v_existing_notes
        when nullif(btrim(coalesce(v_existing_notes, '')), '') is null then v_new_note
        else btrim(v_existing_notes) || E'\n\nGF APPROVAL:\n' || v_new_note
      end,
      redline_override_by = case
        when coalesce(v_require_gf, false) and v_redline_count > 0 and
             v_role in ('admin', 'owner', 'superintendent') then auth.uid()
        else null
      end,
      redline_override_reason = case
        when coalesce(v_require_gf, false) and v_redline_count > 0 and
             v_role in ('admin', 'owner', 'superintendent') then v_new_note
        else null
      end,
      redline_override_at = case
        when coalesce(v_require_gf, false) and v_redline_count > 0 and
             v_role in ('admin', 'owner', 'superintendent') then now()
        else null
      end
  where report.id = p_report_id and report.company_id = v_company_id;
end;
$$;


--
-- Name: archive_timekeeping_segment_on_report_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.archive_timekeeping_segment_on_report_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if old.daily_report_id is distinct from new.daily_report_id
     and old.company_id = new.company_id
     and old.employee_id = new.employee_id
     and old.work_date = new.work_date
     and old.job_id = new.job_id then
    insert into public.timekeeping_entry_history(
      source_entry_id,company_id,employee_id,daily_report_id,job_id,work_date,crew_name,
      regular_hours,overtime_hours,storm_work,notes,created_by,updated_by,created_at,updated_at,
      start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used
    ) values (
      old.id,old.company_id,old.employee_id,old.daily_report_id,old.job_id,old.work_date,old.crew_name,
      old.regular_hours,old.overtime_hours,old.storm_work,old.notes,old.created_by,old.updated_by,old.created_at,old.updated_at,
      old.start_time,old.stop_time,old.lunch_minutes,old.per_diem,old.equipment_used,old.equipment_not_used
    );
  end if;
  return new;
end;
$$;


--
-- Name: assign_job_package_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_job_package_revision() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_prior public.job_packages%rowtype;
begin
  select * into v_prior from public.job_packages package
  where package.company_id=new.company_id and package.job_id=new.job_id
  order by package.revision_number desc,package.created_at desc limit 1 for update;
  if v_prior.id is null then
    new.revision_number:=1;
    new.supersedes_package_id:=null;
  else
    new.revision_number:=v_prior.revision_number+1;
    new.supersedes_package_id:=v_prior.id;
  end if;
  return new;
end;
$$;


--
-- Name: audit_returned_unit_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_returned_unit_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r public.daily_reports%rowtype;
  v_item_code text;
  v_actor_name text;
  v_actor_role text;
  v_note text;
begin
  select * into r
  from public.daily_reports
  where id = coalesce(new.daily_report_id, old.daily_report_id);

  if r.id is null or lower(coalesce(r.status,'')) <> 'draft' or nullif(btrim(coalesce(r.review_notes,'')),'') is null or r.reviewed_at is null then
    return coalesce(new, old);
  end if;

  select coalesce(pbi.item_code, dpu.item_code, 'Unit')
  into v_item_code
  from public.daily_production_units dpu
  left join public.price_book_items pbi on pbi.id = dpu.price_book_item_id
  where dpu.id = coalesce(new.daily_production_unit_id, old.daily_production_unit_id);

  select coalesce(p.full_name,'Foreman'), lower(coalesce(p.role,''))
  into v_actor_name, v_actor_role
  from public.profiles p where p.id = auth.uid();

  if tg_op = 'UPDATE' and
     new.install_quantity is not distinct from old.install_quantity and
     new.retirement_quantity is not distinct from old.retirement_quantity then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_note := format('%s / %s added — installed %s, removed %s',
      coalesce(new.pole_location,'Location'), coalesce(v_item_code,'Unit'),
      coalesce(new.install_quantity,0), coalesce(new.retirement_quantity,0));
  elsif tg_op = 'DELETE' then
    v_note := format('%s / %s removed — was installed %s, removed %s',
      coalesce(old.pole_location,'Location'), coalesce(v_item_code,'Unit'),
      coalesce(old.install_quantity,0), coalesce(old.retirement_quantity,0));
  else
    v_note := format('%s / %s changed — installed %s → %s, removed %s → %s',
      coalesce(new.pole_location,old.pole_location,'Location'), coalesce(v_item_code,'Unit'),
      coalesce(old.install_quantity,0), coalesce(new.install_quantity,0),
      coalesce(old.retirement_quantity,0), coalesce(new.retirement_quantity,0));
  end if;

  insert into public.daily_report_audit_events(
    company_id,daily_report_id,event_type,actor_id,actor_name,actor_role,event_notes,created_at
  ) values (
    r.company_id,r.id,'foreman_correction',auth.uid(),v_actor_name,v_actor_role,v_note,now()
  );

  return coalesce(new, old);
end;
$$;


--
-- Name: backup_public_table_inventory(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backup_public_table_inventory() RETURNS TABLE(table_name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select c.relname::text
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
  order by c.relname;
$$;


--
-- Name: can_review_daily_reports(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_review_daily_reports() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.company_id = public.my_company_id()
      and p.active is true
      and (
        lower(p.role) in ('owner', 'admin', 'gf')
        or (
          lower(p.role) = 'superintendent'
          and public.linecrew_has_capability('production_review')
        )
      )
  );
$$;


--
-- Name: capture_all_company_crew_usage(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capture_all_company_crew_usage(p_usage_date date DEFAULT CURRENT_DATE) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company record;
  v_count integer := 0;
begin
  for v_company in select c.id from public.companies c loop
    perform public.capture_company_crew_usage(v_company.id, coalesce(p_usage_date,current_date));
    perform public.recalculate_company_crew_overage(v_company.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;


--
-- Name: FUNCTION capture_all_company_crew_usage(p_usage_date date); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.capture_all_company_crew_usage(p_usage_date date) IS 'Call once daily with service_role. Triggers capture in-day changes; this daily snapshot makes sustained over-limit use accumulate even when no crew records change.';


--
-- Name: capture_company_crew_usage(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capture_company_crew_usage(p_company_id uuid, p_usage_date date DEFAULT CURRENT_DATE) RETURNS TABLE(active_crews integer, storm_crews integer, billable_crews integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_active integer;
  v_storm integer;
  v_billable integer;
  v_storm_mode boolean;
begin
  if p_company_id is null then
    return;
  end if;

  select coalesce(c.storm_mode_enabled,false)
  into v_storm_mode
  from public.companies c
  where c.id = p_company_id;

  if not found then
    return;
  end if;

  select count(*)::integer
  into v_active
  from public.crews c
  where c.company_id = p_company_id
    and coalesce(c.active,true) = true;

  if v_storm_mode then
    select count(*)::integer
    into v_storm
    from public.crews c
    where c.company_id = p_company_id
      and coalesce(c.active,true) = true
      and c.foreman_id is not null
      and exists (
        select 1
        from public.storm_mode_assignments a
        where a.company_id = p_company_id
          and a.user_id = c.foreman_id
      );
  else
    v_storm := 0;
  end if;

  v_billable := greatest(v_active - v_storm,0);

  insert into public.company_crew_usage_daily(
    company_id, usage_date, peak_active_crews, storm_crews, peak_billable_crews, recorded_at
  ) values (
    p_company_id, coalesce(p_usage_date,current_date), v_active, v_storm, v_billable, now()
  )
  on conflict (company_id, usage_date) do update set
    peak_active_crews = greatest(public.company_crew_usage_daily.peak_active_crews, excluded.peak_active_crews),
    storm_crews = greatest(public.company_crew_usage_daily.storm_crews, excluded.storm_crews),
    peak_billable_crews = greatest(public.company_crew_usage_daily.peak_billable_crews, excluded.peak_billable_crews),
    recorded_at = now();

  return query select v_active, v_storm, v_billable;
end;
$$;


--
-- Name: capture_company_storm_toggle_usage(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capture_company_storm_toggle_usage() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  perform public.capture_company_crew_usage(new.id,current_date);
  perform public.recalculate_company_crew_overage(new.id);
  return new;
end;
$$;


--
-- Name: capture_crew_usage_from_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.capture_crew_usage_from_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_old_company uuid;
  v_new_company uuid;
begin
  v_old_company := case when tg_op in ('UPDATE','DELETE') then old.company_id else null end;
  v_new_company := case when tg_op in ('INSERT','UPDATE') then new.company_id else null end;

  if v_old_company is not null then
    perform public.capture_company_crew_usage(v_old_company,current_date);
    perform public.recalculate_company_crew_overage(v_old_company);
  end if;
  if v_new_company is not null and v_new_company is distinct from v_old_company then
    perform public.capture_company_crew_usage(v_new_company,current_date);
    perform public.recalculate_company_crew_overage(v_new_company);
  end if;
  return coalesce(new,old);
end;
$$;


--
-- Name: company_decide_support_request(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_decide_support_request(p_request_id uuid, p_approve boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text; v_request public.support_access_requests%rowtype;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  select * into v_request from public.support_access_requests where id=p_request_id and company_id=v_company for update;
  if not found or v_request.status<>'pending' then raise exception 'Pending support request not found'; end if;
  update public.support_access_requests set
    status=case when p_approve then 'approved' else 'denied' end,
    approved_by=case when p_approve then (select auth.uid()) else null end,
    approved_at=case when p_approve then now() else null end,
    expires_at=case when p_approve then now()+make_interval(mins=>v_request.requested_minutes) else null end
  where id=p_request_id;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type)
  values(p_request_id,v_company,(select auth.uid()),case when p_approve then 'access_approved' else 'access_denied' end);
end;
$$;


--
-- Name: company_list_support_requests(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_list_support_requests() RETURNS TABLE(id uuid, reason text, status text, requested_at timestamp with time zone, requested_minutes integer, approved_at timestamp with time zone, expires_at timestamp with time zone, support_name text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  update public.support_access_requests r set status='expired'
    where r.company_id=v_company and r.status='approved' and r.expires_at<=now();
  return query select r.id,r.reason,r.status,r.requested_at,r.requested_minutes,r.approved_at,r.expires_at,s.display_name
    from public.support_access_requests r join public.platform_support_users s on s.user_id=r.support_user_id
    where r.company_id=v_company order by r.requested_at desc limit 50;
end;
$$;


--
-- Name: company_revoke_support_access(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_revoke_support_access(p_request_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  update public.support_access_requests set status='revoked',revoked_by=(select auth.uid()),revoked_at=now(),expires_at=now()
    where id=p_request_id and company_id=v_company and status='approved';
  if not found then raise exception 'Active support access not found'; end if;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type)
  values(p_request_id,v_company,(select auth.uid()),'access_revoked');
end;
$$;


--
-- Name: company_support_audit_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_support_audit_history() RETURNS TABLE(event_type text, created_at timestamp with time zone, details jsonb, actor_name text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  return query select e.event_type,e.created_at,e.details,coalesce(s.display_name,p.full_name,'Company user')
    from public.support_audit_events e
    left join public.platform_support_users s on s.user_id=e.actor_id
    left join public.profiles p on p.id=e.actor_id
    where e.company_id=v_company order by e.created_at desc limit 100;
end;
$$;


--
-- Name: complete_assistant_memory(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_assistant_memory(p_memory_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: complete_team_invitation_signup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_team_invitation_signup() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  invitation public.team_invitations%rowtype;
  supplied_token_hash text := lower(coalesce(new.raw_user_meta_data ->> 'team_invitation_token_hash', ''));
  default_name text;
  v_role text;
begin
  if supplied_token_hash = '' then return new; end if;
  if supplied_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid team invitation.';
  end if;

  select * into invitation
  from public.team_invitations
  where token_hash = supplied_token_hash
    and lower(email) = lower(new.email)
    and accepted_at is null
    and expires_at > now()
  for update;

  if invitation.id is null then
    raise exception using errcode = 'P0002', message = 'This team invitation is invalid, expired, or belongs to another email address.';
  end if;

  default_name := btrim(coalesce(invitation.intended_full_name, ''));
  if length(default_name) < 2 then
    default_name := initcap(btrim(regexp_replace(split_part(new.email, '@', 1), '[^[:alnum:]]+', ' ', 'g')));
  end if;
  if length(default_name) < 2 then default_name := 'New User'; end if;

  v_role := lower(coalesce(invitation.intended_role, 'foreman'));
  if v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode = '22023', message = 'Invalid team invitation role.';
  end if;

  insert into public.profiles (id, company_id, full_name, role, active)
  values (new.id, invitation.company_id, left(default_name, 120), v_role, true);

  update public.team_invitations
  set accepted_at = now(), accepted_by = new.id
  where id = invitation.id;
  return new;
end;
$_$;


--
-- Name: create_and_stage_utility_packet_import(uuid, text, text, text, text, text, text, numeric, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_and_stage_utility_packet_import(p_job_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_company_id uuid;
  v_existing_package_id uuid;
  v_existing_import_id uuid;
  v_existing_package_status text;
  v_existing_import_status text;
  v_package_id uuid;
  v_import_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to add utility job packages.';
  end if;

  if lower(btrim(coalesce(p_source_sha256, ''))) !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023',
      message = 'The packet file fingerprint is invalid.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  join public.jobs job
    on job.id = p_job_id
   and job.company_id = profile.company_id
   and job.active is true
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where profile.id = auth.uid()
    and profile.active is true
  for update of job;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Select an active job tied to an active company contract.';
  end if;

  select package.id,
    packet_import.id,
    package.status,
    packet_import.status
  into v_existing_package_id,
    v_existing_import_id,
    v_existing_package_status,
    v_existing_import_status
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  where packet_import.company_id = v_company_id
    and package.job_id = p_job_id
    and packet_import.source_sha256 = lower(btrim(p_source_sha256))
  order by packet_import.created_at desc, packet_import.id desc
  limit 1
  for update of packet_import, package;

  if v_existing_import_id is not null then
    if v_existing_package_status = 'draft'
       and v_existing_import_status = 'review' then
      return jsonb_build_object(
        'package_id', v_existing_package_id,
        'import_id', v_existing_import_id,
        'resumed', true
      );
    end if;

    raise exception using
      errcode = '23505',
      message = 'This exact packet file is already attached to this job.';
  end if;

  v_package_id := public.create_job_package_from_file(
    p_job_id,
    p_source_filename,
    p_detected_work_order
  );
  v_import_id := public.stage_utility_packet_import(
    v_package_id,
    p_provider_key,
    p_format_key,
    p_profile_version,
    p_source_filename,
    p_source_sha256,
    p_detected_work_order,
    p_extraction_confidence,
    p_summary,
    p_rows
  );

  return jsonb_build_object(
    'package_id', v_package_id,
    'import_id', v_import_id,
    'resumed', false
  );
end;
$_$;


--
-- Name: create_assistant_memory(text, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_assistant_memory(p_memory_type text, p_title text, p_instruction text, p_trigger_type text, p_job_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: create_billing_credit_batch(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_billing_credit_batch(p_paid_batch_id uuid, p_reason text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text; v_active boolean; v_source public.billing_export_batches%rowtype;
  v_id uuid:=gen_random_uuid(); v_number text; v_sequence integer;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin') then
    raise exception using errcode='42501',message='Only Admin or Owner can create a billing adjustment.';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception using errcode='22023',message='A billing-adjustment reason is required.';
  end if;

  select * into v_source from public.billing_export_batches b
    where b.id=p_paid_batch_id and b.company_id=v_company
      and b.status='paid' and b.billing_type<>'credit' for update;
  if v_source.id is null then
    raise exception using errcode='23514',message='Choose a paid original billing batch.';
  end if;
  if exists(select 1 from public.billing_export_batches b
    where b.parent_batch_id=v_source.id and b.billing_type='credit' and b.status<>'void') then
    raise exception using errcode='23505',message='An active billing adjustment already exists for this paid batch.';
  end if;

  select coalesce(max(b.billing_sequence),0)+1 into v_sequence
  from public.billing_export_batches b
  where b.company_id=v_company and b.job_id=v_source.job_id;
  v_number:='CREDIT-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(v_id::text,'-',''),1,6));

  insert into public.billing_export_batches(id,company_id,job_id,batch_number,date_from,date_to,
    include_redlines,status,authorized_line_count,redline_line_count,total_value,notes,created_by,
    billing_type,billing_sequence,correction_reason,parent_batch_id)
  values(v_id,v_company,v_source.job_id,v_number,v_source.date_from,v_source.date_to,
    v_source.include_redlines,'draft',v_source.authorized_line_count,v_source.redline_line_count,
    -abs(v_source.total_value),btrim(p_reason),auth.uid(),'credit',v_sequence,btrim(p_reason),v_source.id);

  insert into public.billing_export_lines(company_id,billing_batch_id,job_id,daily_report_id,
    production_location_id,report_date,foreman_name,crew_name,work_point,price_book_item_id,
    unit_code,unit_name,unit_description,work_type,quantity,unit_price,extended_value,
    authorization_status,active)
  select l.company_id,v_id,l.job_id,l.daily_report_id,l.production_location_id,l.report_date,
    l.foreman_name,l.crew_name,l.work_point,l.price_book_item_id,l.unit_code,l.unit_name,
    l.unit_description,l.work_type,l.quantity,-abs(l.unit_price),-abs(l.extended_value),
    l.authorization_status,false
  from public.billing_export_lines l
  where l.billing_batch_id=v_source.id and l.company_id=v_company;

  -- Release the original production actions from the active uniqueness lock.
  -- The immutable source and adjustment rows remain available for audit/export.
  update public.billing_export_lines
  set active=false
  where billing_batch_id=v_source.id and company_id=v_company;

  return v_id;
end;
$$;


--
-- Name: create_billing_export_batch(uuid, date, date, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_billing_export_batch(p_job_id uuid, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_include_redlines boolean DEFAULT false, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid; v_role text; v_active boolean;
  v_batch_id uuid := gen_random_uuid(); v_batch_number text; v_inserted integer;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active Admin, Owner or Superintendent can create billing exports.';
  end if;
  if v_role = 'superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode = '42501',
      message = 'This Superintendent needs Reporting and Actual Pricing permissions for billing exports.';
  end if;
  if p_date_from is not null and p_date_to is not null and p_date_from > p_date_to then
    raise exception using errcode = '22023', message = 'From Date cannot be after Through Date.';
  end if;
  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002', message = 'Job was not found in your company.';
  end if;

  v_batch_number := 'BILL-' || to_char(current_date, 'YYYYMMDD') || '-' ||
    upper(substr(replace(v_batch_id::text, '-', ''), 1, 6));
  insert into public.billing_export_batches(
    id, company_id, job_id, batch_number, date_from, date_to,
    include_redlines, notes, created_by
  ) values (
    v_batch_id, v_company_id, p_job_id, v_batch_number, p_date_from, p_date_to,
    coalesce(p_include_redlines, false), nullif(btrim(coalesce(p_notes, '')), ''), auth.uid()
  );

  with eligible as (
    select report.id daily_report_id, report.work_date report_date,
      report.foreman_name, report.crew_name,
      location.location_line_id production_location_id, location.price_book_item_id,
      location.pole_location work_point, location.item_code unit_code,
      location.item_name unit_name, location.description unit_description,
      location.install_quantity, location.transfer_quantity, location.retirement_quantity,
      location.actual_install_price, unit.actual_transfer_price,
      location.actual_retirement_price, location.authorization_status
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    join public.daily_production_unit_locations source
      on source.id = location.location_line_id and source.company_id = report.company_id
    join public.daily_production_units unit
      on unit.id = source.daily_production_unit_id and unit.company_id = source.company_id
    where report.company_id = v_company_id and report.job_id = p_job_id
      and lower(coalesce(report.status, '')) = 'approved'
      and (p_date_from is null or report.work_date >= p_date_from)
      and (p_date_to is null or report.work_date <= p_date_to)
      and location.authorization_status in ('authorized', 'redline')
      and (location.authorization_status = 'authorized' or coalesce(p_include_redlines, false))
  ), actions as (
    select eligible.*, 'INSTALL'::text work_type,
      eligible.install_quantity quantity, eligible.actual_install_price unit_price
    from eligible where eligible.install_quantity > 0
    union all
    select eligible.*, 'TRANSFER'::text,
      eligible.transfer_quantity, eligible.actual_transfer_price
    from eligible where eligible.transfer_quantity > 0
    union all
    select eligible.*, 'REMOVE'::text,
      eligible.retirement_quantity, eligible.actual_retirement_price
    from eligible where eligible.retirement_quantity > 0
  )
  insert into public.billing_export_lines(
    company_id, billing_batch_id, job_id, daily_report_id,
    production_location_id, report_date, foreman_name, crew_name, work_point,
    price_book_item_id, unit_code, unit_name, unit_description, work_type,
    quantity, unit_price, extended_value, authorization_status
  )
  select v_company_id, v_batch_id, p_job_id, action.daily_report_id,
    action.production_location_id, action.report_date, action.foreman_name,
    action.crew_name, action.work_point, action.price_book_item_id,
    action.unit_code, action.unit_name, action.unit_description, action.work_type,
    action.quantity, coalesce(action.unit_price, 0),
    round(action.quantity * coalesce(action.unit_price, 0), 2),
    action.authorization_status
  from actions action
  where not exists (
    select 1 from public.billing_export_lines prior
    where prior.company_id = v_company_id
      and prior.production_location_id = action.production_location_id
      and prior.work_type = action.work_type and prior.active
  );
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    delete from public.billing_export_batches where id = v_batch_id;
    raise exception using errcode = 'P0002',
      message = 'No approved, unbilled unit lines match this job and date range.';
  end if;
  update public.billing_export_batches batch set
    authorized_line_count = (select count(*) from public.billing_export_lines line
      where line.billing_batch_id = v_batch_id and line.authorization_status = 'authorized'),
    redline_line_count = (select count(*) from public.billing_export_lines line
      where line.billing_batch_id = v_batch_id and line.authorization_status = 'redline'),
    total_value = (select coalesce(sum(line.extended_value), 0)
      from public.billing_export_lines line where line.billing_batch_id = v_batch_id)
  where batch.id = v_batch_id;
  return v_batch_id;
end;
$$;


--
-- Name: create_billing_export_batch_v2(uuid, date, date, boolean, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_billing_export_batch_v2(p_job_id uuid, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_include_redlines boolean DEFAULT false, p_notes text DEFAULT NULL::text, p_is_final boolean DEFAULT false) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_batch_id uuid;
  v_sequence integer;
begin
  select profile.company_id
  into v_company_id
  from public.profiles profile
  where profile.id=auth.uid() and profile.active=true;

  if v_company_id is null then
    raise exception using errcode='42501',message='An active company profile is required.';
  end if;

  perform 1
  from public.jobs job
  where job.id=p_job_id and job.company_id=v_company_id
  for update;
  if not found then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;

  if exists (
    select 1
    from public.billing_export_batches batch
    where batch.company_id=v_company_id
      and batch.job_id=p_job_id
      and batch.billing_type='final'
      and batch.status<>'void'
  ) then
    raise exception using errcode='23514',
      message='This job already has an active Final Bill. Void it before creating another billing batch.';
  end if;

  select coalesce(max(batch.billing_sequence),0)+1
  into v_sequence
  from public.billing_export_batches batch
  where batch.company_id=v_company_id and batch.job_id=p_job_id;

  -- Approved redlines always belong in the billing batch and remain beside
  -- their work point. The checkbox only controls the extra export summary.
  v_batch_id:=public.create_billing_export_batch(
    p_job_id,p_date_from,p_date_to,true,p_notes
  );

  update public.billing_export_batches batch
  set billing_type=case when coalesce(p_is_final,false) then 'final' else 'partial' end,
      billing_sequence=v_sequence,
      include_redlines=coalesce(p_include_redlines,false)
  where batch.id=v_batch_id and batch.company_id=v_company_id;

  return v_batch_id;
end;
$$;


--
-- Name: create_billing_export_batch_v3(uuid, date, date, boolean, text, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_billing_export_batch_v3(p_job_id uuid, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_separate_redline_summary boolean DEFAULT false, p_notes text DEFAULT NULL::text, p_is_final boolean DEFAULT false, p_final_override_reason text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_rec record; v_id uuid; v_role text;
begin
  if coalesce(p_is_final, false) then
    select * into v_rec from public.get_job_billing_reconciliation(p_job_id);
    if v_rec.remaining_authorized_value > 0.01 or v_rec.awaiting_review_count > 0 or
       v_rec.draft_report_count > 0 or v_rec.pending_packet_count > 0 then
      if nullif(btrim(coalesce(p_final_override_reason, '')), '') is null then
        raise exception using errcode = '23514', message =
          'Final Bill has unresolved work or reports. Enter an override reason to continue.';
      end if;
      select lower(coalesce(p.role, '')) into v_role
      from public.profiles p where p.id = auth.uid() and p.active;
      if v_role <> 'owner' then
        raise exception using errcode = '42501', message =
          'Only the Company Owner can override unresolved Final Bill blockers.';
      end if;
    end if;
  end if;
  v_id := public.create_billing_export_batch_v2(
    p_job_id, p_date_from, p_date_to, p_separate_redline_summary, p_notes, p_is_final
  );
  if p_is_final then
    update public.billing_export_batches set
      final_override_reason = nullif(btrim(coalesce(p_final_override_reason, '')), ''),
      updated_at = now(), updated_by = auth.uid()
    where id = v_id;
  end if;
  return v_id;
end;
$$;


--
-- Name: create_company(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_company(company_name text, admin_name text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: create_contract_job(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_contract_job(p_contract_id uuid, p_job_number text, p_job_name text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
  v_job_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
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


--
-- Name: create_daily_report(uuid, date, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_daily_report(p_job_id uuid, p_work_date date, p_regular_hours numeric DEFAULT 0, p_overtime_hours numeric DEFAULT 0, p_crew_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_report_id uuid;
  v_foreman_name text;
  v_role text;
  v_contract_id uuid;
  v_price_book_id uuid;
begin
  select profile.company_id, profile.full_name,
    lower(coalesce(profile.role, ''))
  into v_company_id, v_foreman_name, v_role
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role <> 'foreman' then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman profile is required.';
  end if;

  select job.contract_id, job.price_book_id
  into v_contract_id, v_price_book_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
    and public.linecrew_foreman_has_job_assignment(job.id);

  if v_contract_id is null then
    raise exception 'Active job not found';
  end if;

  if v_price_book_id is not null and not exists (
    select 1
    from public.price_books book
    where book.id = v_price_book_id
      and book.company_id = v_company_id
      and book.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'The job Price Book does not belong to this company and contract.';
  end if;

  insert into public.daily_reports (
    company_id, job_id, work_date, foreman_id, created_by, foreman_name,
    crew_name, regular_hours, overtime_hours, notes, price_book_id
  ) values (
    v_company_id, p_job_id, coalesce(p_work_date, current_date), auth.uid(),
    auth.uid(), v_foreman_name, nullif(trim(p_crew_name), ''),
    coalesce(p_regular_hours, 0), coalesce(p_overtime_hours, 0),
    nullif(trim(p_notes), ''), v_price_book_id
  )
  returning id into v_report_id;

  return v_report_id;
end;
$$;


--
-- Name: create_job(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_job(p_job_number text, p_job_name text, p_customer_name text DEFAULT NULL::text, p_utility_name text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: create_job_package(uuid, text, text, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_job_package(p_job_id uuid, p_package_name text, p_package_number text DEFAULT NULL::text, p_received_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_package_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to add utility job packages.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
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
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
  for update of job;

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


--
-- Name: create_job_package_from_file(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_job_package_from_file(p_job_id uuid, p_source_filename text, p_detected_reference text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_package_id uuid;
  v_name text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin, General Foreman, or authorized Superintendent can add job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  select job.contract_id
  into v_contract_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
  for update of job;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Select an active job tied to an active company contract.';
  end if;

  if length(trim(coalesce(p_source_filename, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'A packet filename is required.';
  end if;

  v_name := regexp_replace(trim(p_source_filename), '\.[^.]+$', '');

  insert into public.job_packages (
    company_id, job_id, contract_id, package_name, package_number,
    source_filename, status, created_by
  ) values (
    v_company_id,
    p_job_id,
    v_contract_id,
    v_name,
    case
      when nullif(trim(coalesce(p_detected_reference, '')), '') is not null
       and not exists (
         select 1
         from public.job_packages existing
         where existing.company_id = v_company_id
           and existing.job_id = p_job_id
           and lower(trim(existing.package_number)) =
               lower(trim(p_detected_reference))
       ) then trim(p_detected_reference)
      else null
    end,
    trim(p_source_filename),
    'draft',
    auth.uid()
  )
  returning id into v_package_id;

  return v_package_id;
end;
$_$;


--
-- Name: create_job_package_work_point(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_job_package_work_point(p_package_id uuid, p_work_point_code text, p_description text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
  v_work_point_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
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


--
-- Name: create_standalone_jsa(uuid, date, text, text, text, text, text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_standalone_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text DEFAULT NULL::text, p_special_equipment text DEFAULT NULL::text, p_foreman_acknowledged boolean DEFAULT false) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  if v_company_id is null
     or v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to complete a JSA.';
  end if;

  if v_role = 'superintendent'
     and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and coalesce(j.active, true) is true
      and (
        v_role <> 'foreman'
        or public.linecrew_foreman_has_job_assignment(j.id)
      )
  ) then
    raise exception using errcode = 'P0002',
      message = 'An active assigned job was not found for your company.';
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


--
-- Name: create_standalone_jsa_offline(uuid, uuid, date, text, text, text, text, text, text, text, text, text, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_standalone_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_existing_id uuid;
  v_existing_creator uuid;
  v_jsa_id uuid;
begin
  if p_client_submission_id is null then
    raise exception using errcode='22023', message='A client submission ID is required.';
  end if;

  select p.company_id into v_company_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;

  if v_company_id is null then
    raise exception using errcode='42501', message='An active company profile is required.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_company_id::text || ':' || p_client_submission_id::text, 0)
  );

  select j.id,j.created_by into v_existing_id,v_existing_creator
  from public.daily_report_jsas j
  where j.company_id=v_company_id and j.client_submission_id=p_client_submission_id;

  if v_existing_id is not null then
    if v_existing_creator <> (select auth.uid()) then
      raise exception using errcode='42501', message='This submission ID belongs to another user.';
    end if;
    return v_existing_id;
  end if;

  v_jsa_id := public.create_standalone_jsa_v2(
    p_job_id,
    p_work_date,
    p_crew_name,
    p_job_briefing,
    p_hazards,
    p_controls,
    p_ppe,
    p_emergency_plan,
    p_crew_members,
    p_weather_conditions,
    p_special_equipment,
    p_foreman_acknowledged,
    p_details
  );

  update public.daily_report_jsas
  set client_submission_id=p_client_submission_id
  where id=v_jsa_id and company_id=v_company_id and created_by=(select auth.uid());

  return v_jsa_id;
end;
$$;


--
-- Name: create_standalone_jsa_v2(uuid, date, text, text, text, text, text, text, text, text, text, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_standalone_jsa_v2(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_method text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role,'')), c.jsa_method
    into v_company_id, v_role, v_method
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid() and p.active is true;

  if v_company_id is null or v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode='42501', message='You are not allowed to complete a JSA.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501', message='Safety Records permission is disabled for this Superintendent.';
  end if;
  if v_method not in ('digital','both') then
    raise exception using errcode='42501', message='Digital JSAs are disabled in Company Settings.';
  end if;
  if not exists(
    select 1 from public.jobs j
    where j.id=p_job_id and j.company_id=v_company_id and coalesce(j.active,true)=true
  ) then
    raise exception using errcode='P0002', message='An active job was not found for your company.';
  end if;
  if p_work_date is null or length(trim(coalesce(p_crew_name,'')))=0 or
     length(trim(coalesce(p_job_briefing,'')))=0 or length(trim(coalesce(p_hazards,'')))=0 or
     length(trim(coalesce(p_controls,'')))=0 or length(trim(coalesce(p_ppe,'')))=0 or
     length(trim(coalesce(p_emergency_plan,'')))=0 or length(trim(coalesce(p_crew_members,'')))=0 then
    raise exception using errcode='22023', message='All required JSA fields must be completed.';
  end if;
  if not coalesce(p_foreman_acknowledged,false) then
    raise exception using errcode='22023', message='The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas(
    company_id,daily_report_id,job_id,created_by,work_date,crew_name,
    job_briefing,hazards,controls,ppe,emergency_plan,weather_conditions,
    special_equipment,crew_members,foreman_acknowledged,acknowledged_at,
    updated_at,jsa_source,details
  ) values(
    v_company_id,null,p_job_id,auth.uid(),p_work_date,trim(p_crew_name),
    trim(p_job_briefing),trim(p_hazards),trim(p_controls),trim(p_ppe),
    trim(p_emergency_plan),nullif(trim(coalesce(p_weather_conditions,'')),''),
    nullif(trim(coalesce(p_special_equipment,'')),''),trim(p_crew_members),true,
    now(),now(),'digital',coalesce(p_details,'{}'::jsonb)
  ) returning id into v_jsa_id;
  return v_jsa_id;
end;
$$;


--
-- Name: create_team_invitation(text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_team_invitation(p_email text, p_token_hash text, p_expires_at timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  actor public.profiles%rowtype;
  normalized_email text := lower(btrim(coalesce(p_email, '')));
  invitation_id uuid;
begin
  select * into actor
  from public.profiles
  where id = auth.uid();

  if actor.id is null or actor.active is not true then
    raise exception using errcode = '42501', message = 'Active company access required.';
  end if;

  if lower(actor.role) not in ('owner', 'admin') and not (
    lower(actor.role) = 'superintendent' and
    coalesce((actor.role_permissions ->> 'team_management')::boolean, true)
  ) then
    raise exception using errcode = '42501', message = 'Team invitation access denied.';
  end if;

  if normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
     length(normalized_email) > 254 then
    raise exception using errcode = '22023', message = 'Enter a valid email address.';
  end if;

  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid invitation token.';
  end if;

  if p_expires_at <= now() + interval '5 minutes' or
     p_expires_at > now() + interval '7 days' then
    raise exception using errcode = '22023', message = 'Invalid invitation expiration.';
  end if;

  delete from public.team_invitations
  where company_id = actor.company_id
    and lower(email) = normalized_email
    and accepted_at is null;

  insert into public.team_invitations (
    company_id,
    email,
    token_hash,
    invited_by,
    expires_at
  ) values (
    actor.company_id,
    normalized_email,
    p_token_hash,
    actor.id,
    p_expires_at
  )
  returning id into invitation_id;

  return invitation_id;
end;
$_$;


--
-- Name: create_uploaded_company_jsa(uuid, date, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_uploaded_company_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$ declare v_company_id uuid; v_role text; v_method text; v_jsa_id uuid; begin select p.company_id,lower(coalesce(p.role,'')),c.jsa_method into v_company_id,v_role,v_method from public.profiles p join public.companies c on c.id=p.company_id where p.id=auth.uid() and p.active is true; if v_company_id is null or v_role not in ('foreman','gf','superintendent','admin','owner') then raise exception using errcode='42501',message='An active company member is required.'; end if; if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then raise exception using errcode='42501',message='Safety Records permission is disabled for this Superintendent.'; end if; if v_method not in ('upload','both') then raise exception using errcode='42501',message='Uploaded company JSAs are disabled in Company Settings.'; end if; if p_work_date is null or length(trim(coalesce(p_crew_name,'')))=0 then raise exception using errcode='22023',message='Work date and crew name are required.'; end if; if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company_id and j.active is true) then raise exception using errcode='P0002',message='An active job was not found for your company.'; end if; insert into public.daily_report_jsas(company_id,daily_report_id,job_id,created_by,work_date,crew_name,job_briefing,hazards,controls,ppe,emergency_plan,crew_members,foreman_acknowledged,jsa_source,upload_notes,updated_at) values(v_company_id,null,p_job_id,auth.uid(),p_work_date,trim(p_crew_name),'See uploaded company JSA','See uploaded company JSA','See uploaded company JSA','See uploaded company JSA','See uploaded company JSA','See uploaded company JSA',false,'upload',nullif(trim(coalesce(p_notes,'')),''),now()) returning id into v_jsa_id; return v_jsa_id; end; $$;


--
-- Name: create_uploaded_company_jsa_offline(uuid, uuid, date, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_uploaded_company_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_existing_id uuid;
  v_existing_creator uuid;
  v_jsa_id uuid;
begin
  if p_client_submission_id is null then
    raise exception using errcode='22023', message='A client submission ID is required.';
  end if;

  select p.company_id into v_company_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;

  if v_company_id is null then
    raise exception using errcode='42501', message='An active company profile is required.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_company_id::text || ':' || p_client_submission_id::text, 0)
  );

  select j.id,j.created_by into v_existing_id,v_existing_creator
  from public.daily_report_jsas j
  where j.company_id=v_company_id and j.client_submission_id=p_client_submission_id;

  if v_existing_id is not null then
    if v_existing_creator <> (select auth.uid()) then
      raise exception using errcode='42501', message='This submission ID belongs to another user.';
    end if;
    return v_existing_id;
  end if;

  v_jsa_id := public.create_uploaded_company_jsa(
    p_job_id,
    p_work_date,
    p_crew_name,
    p_notes
  );

  update public.daily_report_jsas
  set client_submission_id=p_client_submission_id
  where id=v_jsa_id and company_id=v_company_id and created_by=(select auth.uid());

  return v_jsa_id;
end;
$$;


--
-- Name: current_training_access(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_training_access() RETURNS TABLE(company_id uuid, role text, subscription_status text, can_train boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select p.company_id, lower(coalesce(p.role,'')), c.subscription_status,
    (coalesce(p.active,true) is true and (
      c.subscription_status = 'internal'
      or (c.subscription_status in ('trial','active')
          and (c.subscription_expires_at is null or c.subscription_expires_at > now()))
    ))
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid();
$$;


--
-- Name: current_user_has_active_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_has_active_profile() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and active is true
  );
$$;


--
-- Name: delete_billing_export_attachment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_billing_export_attachment(p_attachment_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_path text;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode='42501',message='Billing attachment access is required.';
  end if;
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  delete from public.billing_export_attachments a where a.id=p_attachment_id and a.company_id=v_company
    returning a.storage_path into v_path;
  if v_path is null then raise exception using errcode='P0002',message='Attachment was not found.'; end if;
  return v_path;
end;
$$;


--
-- Name: delete_daily_report_attachment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_daily_report_attachment(p_attachment_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_profile public.profiles%rowtype; v_attachment public.daily_report_attachments%rowtype;
begin
 select * into v_profile from public.profiles p where p.id=auth.uid() and p.active is true;
 if v_profile.id is null then raise exception using errcode='42501',message='An active company profile is required.'; end if;
 if lower(coalesce(v_profile.role,''))='superintendent' and not public.linecrew_has_capability('production_review') then raise exception using errcode='42501',message='This Superintendent does not have production review permission.'; end if;
 select * into v_attachment from public.daily_report_attachments attachment where attachment.id=p_attachment_id and attachment.company_id=v_profile.company_id;
 if v_attachment.id is null then raise exception using errcode='P0002',message='Attachment not found for your company.'; end if;
 if v_attachment.uploaded_by<>auth.uid() and lower(coalesce(v_profile.role,'')) not in ('admin','gf','owner','superintendent') then raise exception using errcode='42501',message='Only the uploader or company leadership may delete this attachment.'; end if;
 delete from public.daily_report_attachments where id=v_attachment.id; return v_attachment.storage_path;
end; $$;


--
-- Name: delete_daily_report_unit(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_daily_report_unit(p_unit_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: delete_daily_report_unit(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_creator uuid;
  v_report_status text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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


--
-- Name: delete_daily_report_unit_location(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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


--
-- Name: delete_draft_daily_report(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_draft_daily_report(p_report_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501', message = 'An active company profile is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501', message = 'This Superintendent does not have production review permission.';
  end if;

  if v_role not in ('owner', 'admin', 'superintendent', 'foreman') then
    raise exception using errcode = '42501', message = 'You do not have permission to delete draft Daily Reports.';
  end if;

  if not exists (
    select 1 from public.daily_reports report
    where report.id = p_report_id
      and report.company_id = v_company_id
      and lower(coalesce(report.status, 'draft')) = 'draft'
      and report.submitted_at is null
      and report.reviewed_at is null
      and (v_role in ('owner', 'admin', 'superintendent')
        or (v_role = 'foreman' and report.foreman_id = auth.uid()))
  ) then
    raise exception using errcode = 'P0002', message = 'Only a never-submitted draft can be deleted.';
  end if;

  perform set_config('linecrew.allow_never_submitted_draft_cleanup', 'on', true);

  delete from public.timekeeping_entries entry
  where entry.daily_report_id = p_report_id and entry.company_id = v_company_id;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft'
    and report.submitted_at is null
    and report.reviewed_at is null;
end;
$$;


--
-- Name: delete_job(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_job(p_job_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;
  if lower(coalesce(public.my_role(), '')) not in ('owner', 'admin') then
    raise exception using errcode = '42501',
      message = 'Only the Company Owner or Admin can delete jobs.';
  end if;
  delete from public.jobs
  where id = p_job_id and company_id = public.my_company_id();
  if not found then
    raise exception using errcode = 'P0002', message = 'Job not found.';
  end if;
end;
$$;


--
-- Name: delete_job_package(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_job_package(p_package_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
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


--
-- Name: delete_job_package_authorized_unit(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_job_package_authorized_unit(p_authorized_unit_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
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


--
-- Name: delete_job_package_work_point(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_job_package_work_point(p_work_point_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
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


--
-- Name: delete_uploaded_company_jsa(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_uploaded_company_jsa(p_jsa_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$ declare v_company_id uuid; v_role text; v_creator uuid; begin select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role from public.profiles p where p.id=auth.uid() and p.active is true; select j.created_by into v_creator from public.daily_report_jsas j where j.id=p_jsa_id and j.company_id=v_company_id and j.jsa_source='upload'; if v_creator is null then raise exception using errcode='P0002',message='Uploaded JSA not found.'; end if; if v_creator<>auth.uid() and v_role not in ('owner','admin','gf') and not(v_role='superintendent' and public.linecrew_has_capability('safety_records')) then raise exception using errcode='42501',message='You cannot delete this uploaded JSA.'; end if; delete from public.daily_report_jsas where id=p_jsa_id and company_id=v_company_id; end; $$;


--
-- Name: delete_void_billing_export_batch(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_void_billing_export_batch(p_batch_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
  into v_company_id,v_role,v_active
  from public.profiles profile
  where profile.id=auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner') then
    raise exception using errcode='42501',
      message='Only an active Admin or Owner can delete a voided billing batch.';
  end if;

  delete from public.billing_export_batches batch
  where batch.id=p_batch_id
    and batch.company_id=v_company_id
    and batch.status='void';

  if not found then
    raise exception using errcode='P0002',
      message='Voided billing batch was not found in your company.';
  end if;
end;
$$;


--
-- Name: enforce_active_crew_plan_limit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_active_crew_plan_limit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_plan text;
  v_limit integer;
  v_active_crews integer;
begin
  if coalesce(new.active, true) = false then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and coalesce(old.active, true) = true
     and old.company_id = new.company_id then
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.company_id::text, 487921)
  );

  select lower(cs.plan_code),
         coalesce(cs.included_crew_limit, public.plan_crew_limit(cs.plan_code))
    into v_plan, v_limit
  from public.company_subscriptions cs
  where cs.company_id = new.company_id;

  if v_plan is null then
    raise exception 'This company does not have a subscription plan. Contact LineCrew Pro support.';
  end if;

  -- Custom/41+ plans remain support-managed and may intentionally have no cap.
  if v_plan = 'custom' and v_limit is null then
    return new;
  end if;

  if v_limit is null or v_limit < 1 then
    raise exception 'This company does not have a valid crew limit. Contact LineCrew Pro support.';
  end if;

  select count(*)::integer
    into v_active_crews
  from public.crews c
  where c.company_id = new.company_id
    and coalesce(c.active, true) = true
    and c.id is distinct from new.id;

  if v_active_crews >= v_limit then
    raise exception '% includes up to % active crews. Deactivate an existing crew or upgrade the company plan before activating another crew.',
      initcap(v_plan), v_limit;
  end if;

  return new;
end;
$$;


--
-- Name: FUNCTION enforce_active_crew_plan_limit(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.enforce_active_crew_plan_limit() IS 'Keeps historical inactive crews but blocks a standard paid plan from exceeding its server-side active crew limit.';


--
-- Name: enforce_active_job_for_daily_unit_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_active_job_for_daily_unit_mutation() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_report_id uuid;
begin
  v_report_id := case when tg_op = 'DELETE' then old.daily_report_id else new.daily_report_id end;

  if tg_op = 'DELETE'
     and current_setting('linecrew.allow_never_submitted_draft_cleanup', true) = 'on'
     and exists (
       select 1 from public.daily_reports r
       where r.id = v_report_id
         and lower(coalesce(r.status, 'draft')) = 'draft'
         and r.submitted_at is null
         and r.reviewed_at is null
     ) then
    return old;
  end if;

  if not exists (
    select 1
    from public.daily_reports r
    join public.jobs j on j.id = r.job_id and j.company_id = r.company_id
    where r.id = v_report_id
      and j.active is true
  ) then
    raise exception using errcode = '23514',
      message = 'Units cannot be changed after the parent job is closed.';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;


--
-- Name: enforce_draft_job_package_unit_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_draft_job_package_unit_mutation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_old_package_id uuid;
  v_new_package_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    v_old_package_id := old.job_package_id;
    select package.status
    into v_status
    from public.job_packages package
    where package.id = v_old_package_id
    for update;

    if found and v_status is distinct from 'draft' then
      raise exception using
        errcode = '23514',
        message = 'Active job-jacket revisions are read-only. Upload a new revision.';
    elsif not found and tg_op <> 'DELETE' then
      raise exception using
        errcode = 'P0002',
        message = 'The job-jacket package was not found.';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_new_package_id := new.job_package_id;
    v_status := null;
    select package.status
    into v_status
    from public.job_packages package
    where package.id = v_new_package_id
    for update;

    if not found then
      raise exception using
        errcode = 'P0002',
        message = 'The job-jacket package was not found.';
    elsif v_status is distinct from 'draft' then
      raise exception using
        errcode = '23514',
        message = 'Active job-jacket revisions are read-only. Upload a new revision.';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;


--
-- Name: enforce_foreman_assigned_job(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_foreman_assigned_job() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_role text;
  v_active boolean;
  v_company_id uuid;
begin
  if auth.uid() is null then
    return new;
  end if;

  select lower(coalesce(profile.role, '')), profile.active, profile.company_id
  into v_role, v_active, v_company_id
  from public.profiles profile
  where profile.id = auth.uid();

  if v_active is not true then
    raise exception using errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  if v_role = 'foreman' and (
    new.company_id is distinct from v_company_id
    or not public.linecrew_foreman_has_job_assignment(new.job_id)
  ) then
    raise exception using errcode = '42501',
      message = 'This job is not assigned to you.';
  end if;

  return new;
end;
$$;


--
-- Name: enforce_linecrew_company_access(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_linecrew_company_access() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_profile_active boolean;
  v_role text;
  v_is_support boolean;
  v_has_profile boolean;
  v_subscription_found boolean;
  v_status text;
  v_access_enabled boolean;
  v_access_override boolean;
  v_trial_ends_at timestamptz;
  v_past_due_since timestamptz;
  v_effective_access boolean;
  v_request_path text := coalesce(current_setting('request.path', true), '');
  v_aal text := coalesce((select auth.jwt() ->> 'aal'), 'aal1');
begin
  if auth.uid() is null then return; end if;

  select exists (
    select 1
    from public.platform_support_users support_user
    where support_user.user_id = auth.uid()
      and support_user.active is true
  ) into v_is_support;

  select
    coalesce(profile.active, true),
    lower(coalesce(profile.role, '')),
    lower(coalesce(subscription.status, '')),
    coalesce(subscription.access_enabled, false),
    subscription.access_override,
    subscription.trial_ends_at,
    subscription.past_due_since,
    subscription.company_id is not null
  into
    v_profile_active,
    v_role,
    v_status,
    v_access_enabled,
    v_access_override,
    v_trial_ends_at,
    v_past_due_since,
    v_subscription_found
  from public.profiles profile
  left join public.company_subscriptions subscription
    on subscription.company_id = profile.company_id
  where profile.id = auth.uid();
  v_has_profile := found;

  -- Brand-new authenticated users must be able to create their profile/company.
  if not v_has_profile and not v_is_support then return; end if;

  if v_has_profile and v_profile_active is not true then
    raise exception using errcode = '42501',
      message = 'LineCrew profile access is inactive.';
  end if;

  -- MFA bootstrap must remain reachable even when company access is inactive.
  if v_request_path = '/rpc/linecrew_mfa_bootstrap_identity' then return; end if;

  if (v_is_support or v_role in ('owner', 'admin')) and v_aal <> 'aal2' then
    raise exception using errcode = '42501',
      message = 'Authenticator verification is required for privileged access.',
      hint = 'Complete the LineCrew Pro authenticator challenge and retry.';
  end if;

  -- The billing summary is the sole Data API recovery surface for a blocked
  -- company. Its SECURITY DEFINER body independently requires Owner/Admin.
  if v_request_path = '/rpc/my_company_billing_summary' then return; end if;

  if v_has_profile then
    if v_access_override is not null then
      v_effective_access := v_access_override;
    else
      v_effective_access := v_subscription_found
        and v_access_enabled
        and (
          v_status = 'active'
          or (
            v_status = 'trialing'
            and v_trial_ends_at is not null
            and v_trial_ends_at > now()
          )
          or (
            v_status = 'past_due'
            and v_past_due_since is not null
            and v_past_due_since > now() - interval '7 days'
          )
        );
    end if;

    if v_effective_access is not true then
      raise exception using errcode = '42501',
        message = 'LineCrew company access is inactive.';
    end if;
  end if;
end;
$$;


--
-- Name: ensure_company_subscription(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_company_subscription() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  insert into public.company_subscriptions (
    company_id,
    plan_code,
    monthly_price_cents,
    status,
    access_enabled,
    provider,
    included_crew_limit,
    trial_ends_at
  ) values (
    new.id,
    'pilot',
    0,
    'trialing',
    true,
    'manual',
    5,
    now() + interval '14 days'
  )
  on conflict (company_id) do nothing;
  return new;
end;
$$;


--
-- Name: finalize_job_package_spreadsheet_import(uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_job_package_spreadsheet_import(p_package_id uuid, p_rows jsonb, p_source_filename text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_result jsonb;
  v_package_status text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  perform 1
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  where package.id = p_package_id
    and package.company_id = v_company_id
    and package.status = 'draft'
    and job.active is true
  for update of package, job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Upload a new job-jacket revision; only a draft package can be imported.';
  end if;

  delete from public.job_package_authorized_units authorized
  where authorized.company_id = v_company_id
    and authorized.job_package_id = p_package_id;

  delete from public.job_package_work_points point
  where point.company_id = v_company_id
    and point.job_package_id = p_package_id;

  v_result := public.import_job_package_units(
    p_package_id,
    p_rows,
    p_source_filename
  );

  select package.status
  into v_package_status
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_package_status is distinct from 'active' then
    raise exception using
      errcode = '23514',
      message = 'The spreadsheet imported but the utility package did not activate.';
  end if;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'package_status', 'active',
    'status', 'active'
  );
end;
$$;


--
-- Name: finalize_utility_packet_import(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_utility_packet_import(p_import_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_package_id uuid;
  v_source_filename text;
  v_company_id uuid;
  v_job_id uuid;
  v_contract_id uuid;
  v_job_price_book_id uuid;
  v_price_book_id uuid;
  v_rows jsonb;
  v_package_status text;
  v_imported_rows integer;
  v_unmatched_count integer;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  -- Match the resumable staging lock order even for cached clients that still
  -- call this lower-level finalizer directly: job first, then import/package.
  perform 1
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found, is not editable, or was already finalized.';
  end if;

  select packet_import.job_package_id,
    packet_import.source_filename,
    packet_import.company_id,
    package.job_id,
    package.contract_id,
    job.price_book_id
  into v_package_id,
    v_source_filename,
    v_company_id,
    v_job_id,
    v_contract_id,
    v_job_price_book_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
   and job.active is true
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of packet_import, package, job;

  if v_package_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found, is not editable, or was already finalized.';
  end if;

  v_price_book_id := public.linecrew_resolve_job_price_book(
    v_company_id,
    v_job_id,
    v_contract_id
  );

  if v_price_book_id is null then
    if v_job_price_book_id is not null then
      raise exception using
        errcode = '22023',
        message = 'The job selected Price Book is not active for this contract.';
    else
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book is available for this job contract.';
    end if;
  end if;

  perform 1
  from public.price_books book
  where book.id = v_price_book_id
    and book.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'The selected job Price Book is no longer active.';
  end if;

  update public.jobs job
  set price_book_id = v_price_book_id
  where job.id = v_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'The job closed while its utility packet was finalizing.';
  end if;

  update public.daily_reports report
  set price_book_id = v_price_book_id
  where report.company_id = v_company_id
    and report.job_id = v_job_id
    and report.price_book_id is null
    and lower(coalesce(report.status, 'draft')) = 'draft';

  if exists (
    select 1
    from public.utility_packet_import_rows row_item
    where row_item.import_id = p_import_id
      and row_item.include_in_import
      and nullif(btrim(row_item.contractor_unit_code), '') is null
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every included production row must have a Contractor Unit. Exclude material-only rows or correct the mapping.';
  end if;

  with matches as materialized (
    select *
    from public.linecrew_utility_packet_import_matches(p_import_id)
  ), included as materialized (
    select row_item.*,
      matches.price_book_item_id matched_price_book_item_id,
      matches.canonical_unit_code matched_unit_code
    from public.utility_packet_import_rows row_item
    left join matches
      on matches.row_id = row_item.id
    where row_item.import_id = p_import_id
      and row_item.include_in_import
      and row_item.contractor_unit_code is not null
  ), match_summary as materialized (
    select count(*) filter (
      where included.matched_price_book_item_id is null
    )::integer unmatched_count
    from included
  ), grouped as materialized (
    select min(btrim(included.work_point_code)) work_point_code,
      max(included.work_point_description) work_point_description,
      included.matched_price_book_item_id price_book_item_id,
      included.matched_unit_code canonical_unit_code,
      sum(
        case when lower(included.work_type) = 'install'
          then included.estimated_quantity else 0 end
      ) install_quantity,
      sum(
        case when lower(included.work_type) = 'transfer'
          then included.estimated_quantity else 0 end
      ) transfer_quantity,
      sum(
        case when lower(included.work_type) = 'remove'
          then included.estimated_quantity else 0 end
      ) retirement_quantity
    from included
    where included.matched_price_book_item_id is not null
    group by
      public.normalize_work_point_key(included.work_point_code),
      included.matched_price_book_item_id,
      included.matched_unit_code
  ), aggregated as materialized (
    select jsonb_agg(
      jsonb_build_object(
        'work_point_code', grouped.work_point_code,
        'work_point_description', grouped.work_point_description,
        'price_book_item_id', grouped.price_book_item_id,
        'unit_code', grouped.canonical_unit_code,
        'install_quantity', grouped.install_quantity,
        'transfer_quantity', grouped.transfer_quantity,
        'retirement_quantity', grouped.retirement_quantity
      )
      order by grouped.work_point_code, grouped.canonical_unit_code
    ) rows
    from grouped
  )
  select match_summary.unmatched_count,
    aggregated.rows
  into v_unmatched_count,
    v_rows
  from match_summary
  cross join aggregated;

  if coalesce(v_unmatched_count, 0) > 0 then
    raise exception using
      errcode = 'P0002',
      message = 'One or more Contractor Units were not found in the selected job Price Book. Correct the unmatched rows before importing.';
  end if;

  if v_rows is null or jsonb_array_length(v_rows) = 0 then
    raise exception using
      errcode = '22023',
      message = 'No reviewed Contractor Unit rows are selected for import.';
  end if;

  -- Preserve the original canonical work-point behavior without relying on
  -- the table's older lower(trim()) key. A jacket may spell the same location
  -- as "Pole 0020", "WP-20" or "20".
  with packet_rows as materialized (
    select public.normalize_work_point_key(value->>'work_point_code') point_key,
      min(btrim(value->>'work_point_code')) work_point_code,
      max(nullif(btrim(coalesce(value->>'work_point_description', '')), ''))
        work_point_description
    from jsonb_array_elements(v_rows)
    group by public.normalize_work_point_key(value->>'work_point_code')
  )
  insert into public.job_package_work_points (
    company_id, job_package_id, job_id, work_point_code, description,
    created_by
  )
  select v_company_id,
    v_package_id,
    v_job_id,
    packet_row.work_point_code,
    packet_row.work_point_description,
    auth.uid()
  from packet_rows packet_row
  on conflict (
    job_package_id,
    (public.normalize_work_point_key(work_point_code))
  ) do update
  set description = coalesce(
        public.job_package_work_points.description,
        excluded.description
      ),
      updated_at = now();

  with packet_rows as materialized (
    select value,
      public.normalize_work_point_key(value->>'work_point_code') point_key
    from jsonb_array_elements(v_rows)
  )
  insert into public.job_package_authorized_units (
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_transfer_quantity,
    authorized_retirement_quantity, created_by
  )
  select v_company_id,
    v_package_id,
    work_point.id,
    (packet_row.value->>'price_book_item_id')::uuid,
    packet_row.value->>'unit_code',
    (packet_row.value->>'install_quantity')::numeric,
    (packet_row.value->>'transfer_quantity')::numeric,
    (packet_row.value->>'retirement_quantity')::numeric,
    auth.uid()
  from packet_rows packet_row
  join public.job_package_work_points work_point
    on work_point.company_id = v_company_id
   and work_point.job_package_id = v_package_id
   and public.normalize_work_point_key(work_point.work_point_code) =
       packet_row.point_key
  on conflict (work_point_id, price_book_item_id) do update
  set authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_transfer_quantity = excluded.authorized_transfer_quantity,
      authorized_retirement_quantity =
        excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

  get diagnostics v_imported_rows = row_count;

  update public.job_packages package
  set source_filename = v_source_filename,
      updated_at = now()
  where package.id = v_package_id
    and package.company_id = v_company_id;

  v_package_status := public.set_job_package_status(v_package_id, 'active');

  update public.utility_packet_imports packet_import
  set status = 'imported',
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where packet_import.id = p_import_id
    and packet_import.company_id = v_company_id
    and packet_import.status = 'review';

  if not found then
    raise exception using
      errcode = '23514',
      message = 'The packet review changed before finalization completed.';
  end if;

  return jsonb_build_object(
    'imported_rows', v_imported_rows,
    'source_rows', (
      select count(*)
      from public.utility_packet_import_rows row_item
      where row_item.import_id = p_import_id
    ),
    'material_only_rows', (
      select count(*)
      from public.utility_packet_import_rows row_item
      where row_item.import_id = p_import_id
        and row_item.contractor_unit_code is null
    ),
    'consolidated_rows', v_imported_rows,
    'package_status', v_package_status,
    'status', v_package_status,
    'price_book_id', v_price_book_id
  );
end;
$$;


--
-- Name: finalize_utility_packet_import_review(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_utility_packet_import_review(p_import_id uuid, p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_saved jsonb;
  v_finalized jsonb;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  -- Use the same job -> import/package lock order as resumable staging. This
  -- prevents a same-file retry from deadlocking a confirmation in progress.
  perform 1
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found or is no longer editable.';
  end if;

  v_saved := public.update_utility_packet_import_rows_bulk(
    p_import_id,
    p_rows
  );
  v_finalized := public.finalize_utility_packet_import(p_import_id);

  return coalesce(v_finalized, '{}'::jsonb) || jsonb_build_object(
    'updated_rows', coalesce((v_saved->>'updated_rows')::integer, 0)
  );
end;
$$;


--
-- Name: get_assignable_job_leaders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_assignable_job_leaders() RETURNS TABLE(member_id uuid, full_name text, member_role text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to manage job assignments.';
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


--
-- Name: get_billing_export_attachments(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_billing_export_attachments(p_batch_id uuid) RETURNS TABLE(id uuid, storage_path text, original_filename text, mime_type text, file_size_bytes bigint, caption text, uploaded_by uuid, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode='42501',message='Billing attachment access is required.';
  end if;
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  if not exists(select 1 from public.billing_export_batches b where b.id=p_batch_id and b.company_id=v_company) then
    raise exception using errcode='P0002',message='Billing batch was not found.';
  end if;
  return query select a.id,a.storage_path,a.original_filename,a.mime_type,a.file_size_bytes,
    a.caption,a.uploaded_by,a.created_at from public.billing_export_attachments a
  where a.company_id=v_company and a.billing_batch_id=p_batch_id order by a.created_at;
end;
$$;


--
-- Name: get_billing_export_batch_lines(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_billing_export_batch_lines(p_batch_id uuid) RETURNS TABLE(line_id uuid, batch_number text, job_number text, job_name text, customer_name text, utility_name text, report_date date, foreman_name text, crew_name text, work_point text, unit_code text, unit_name text, unit_description text, work_type text, quantity numeric, unit_price numeric, extended_value numeric, authorization_status text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  return query
  select l.id,b.batch_number,j.job_number,j.job_name,j.customer_name,j.utility_name,
    l.report_date,l.foreman_name,l.crew_name,l.work_point,l.unit_code,l.unit_name,
    l.unit_description,l.work_type,l.quantity,l.unit_price,l.extended_value,
    l.authorization_status
  from public.billing_export_lines l
  join public.billing_export_batches b on b.id=l.billing_batch_id and b.company_id=l.company_id
  join public.jobs j on j.id=l.job_id and j.company_id=l.company_id
  where l.company_id=v_company_id and l.billing_batch_id=p_batch_id
  order by case when l.authorization_status='authorized' then 0 else 1 end,
    l.report_date,l.work_point,l.unit_code,l.work_type;
end;
$$;


--
-- Name: get_billing_export_batches(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_billing_export_batches() RETURNS TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  return query
  select b.id,b.batch_number,b.job_id,j.job_number,j.job_name,b.date_from,b.date_to,
    b.include_redlines,b.status,b.authorized_line_count,b.redline_line_count,b.total_value,
    b.notes,p.full_name,b.created_at,b.exported_at,b.submitted_at,b.paid_at,b.voided_at
  from public.billing_export_batches b
  join public.jobs j on j.id=b.job_id and j.company_id=b.company_id
  left join public.profiles p on p.id=b.created_by
  where b.company_id=v_company_id
  order by b.created_at desc;
end;
$$;


--
-- Name: get_billing_export_batches_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_billing_export_batches_v2() RETURNS TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, billing_type text, billing_sequence integer, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
  into v_company_id,v_role,v_active
  from public.profiles profile where profile.id=auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',
      message='Reporting and Actual Pricing permissions are required.';
  end if;

  return query
  select batch.id,batch.batch_number,batch.job_id,job.job_number,job.job_name,
    batch.date_from,batch.date_to,batch.include_redlines,batch.status,
    batch.billing_type,batch.billing_sequence,
    batch.authorized_line_count,batch.redline_line_count,batch.total_value,
    batch.notes,creator.full_name,batch.created_at,batch.exported_at,
    batch.submitted_at,batch.paid_at,batch.voided_at
  from public.billing_export_batches batch
  join public.jobs job on job.id=batch.job_id and job.company_id=batch.company_id
  left join public.profiles creator on creator.id=batch.created_by
  where batch.company_id=v_company_id
  order by batch.created_at desc;
end;
$$;


--
-- Name: get_billing_export_batches_v3(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_billing_export_batches_v3() RETURNS TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, billing_type text, billing_sequence integer, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, utility_invoice_number text, payment_reference text, correction_reason text, final_override_reason text, parent_batch_id uuid, parent_batch_number text, attachment_count bigint, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  return query select b.id,b.batch_number,b.job_id,j.job_number,j.job_name,b.date_from,b.date_to,
    b.include_redlines,b.status,b.billing_type,b.billing_sequence,b.authorized_line_count,
    b.redline_line_count,b.total_value,b.notes,b.utility_invoice_number,b.payment_reference,
    b.correction_reason,b.final_override_reason,b.parent_batch_id,parent.batch_number,
    (select count(*) from public.billing_export_attachments a where a.billing_batch_id=b.id),
    creator.full_name,b.created_at,b.exported_at,b.submitted_at,b.paid_at,b.voided_at
  from public.billing_export_batches b join public.jobs j on j.id=b.job_id and j.company_id=b.company_id
  left join public.billing_export_batches parent on parent.id=b.parent_batch_id
  left join public.profiles creator on creator.id=b.created_by
  where b.company_id=v_company order by b.created_at desc;
end;
$$;


--
-- Name: get_billing_export_batches_v4(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_billing_export_batches_v4(p_archive_filter text DEFAULT 'active'::text) RETURNS TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, billing_type text, billing_sequence integer, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, utility_invoice_number text, payment_reference text, correction_reason text, final_override_reason text, parent_batch_id uuid, parent_batch_number text, attachment_count bigint, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone, archived_at timestamp with time zone, archived_by_name text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text; v_active boolean; v_filter text;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;

  v_filter:=lower(btrim(coalesce(p_archive_filter,'active')));
  if v_filter not in ('active','archived','all') then
    raise exception using errcode='22023',message='Invalid billing archive filter.';
  end if;
  if v_role not in ('owner','admin') and v_filter<>'active' then
    raise exception using errcode='42501',message='Only Admin or Owner can view archived billing batches.';
  end if;

  return query
  select b.id,b.batch_number,b.job_id,j.job_number,j.job_name,b.date_from,b.date_to,
    b.include_redlines,b.status,b.billing_type,b.billing_sequence,b.authorized_line_count,
    b.redline_line_count,b.total_value,b.notes,b.utility_invoice_number,b.payment_reference,
    b.correction_reason,b.final_override_reason,b.parent_batch_id,parent.batch_number,
    (select count(*) from public.billing_export_attachments a where a.billing_batch_id=b.id),
    creator.full_name,b.created_at,b.exported_at,b.submitted_at,b.paid_at,b.voided_at,
    b.archived_at,archiver.full_name
  from public.billing_export_batches b
  join public.jobs j on j.id=b.job_id and j.company_id=b.company_id
  left join public.billing_export_batches parent on parent.id=b.parent_batch_id
  left join public.profiles creator on creator.id=b.created_by
  left join public.profiles archiver on archiver.id=b.archived_by
  where b.company_id=v_company
    and (
      (v_filter='active' and b.archived_at is null)
      or (v_filter='archived' and b.archived_at is not null)
      or v_filter='all'
    )
  order by b.created_at desc;
end;
$$;


--
-- Name: get_company_general_foremen(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_company_general_foremen() RETURNS TABLE(id uuid, full_name text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','gf','superintendent') then
    raise exception using errcode='42501', message='Company leadership access is required.';
  end if;

  return query
  select p.id, coalesce(nullif(trim(p.full_name),''),'General Foreman')
  from public.profiles p
  where p.company_id = v_company_id
    and p.active is true
    and lower(coalesce(p.role,'')) = 'gf'
  order by coalesce(nullif(trim(p.full_name),''),'General Foreman');
end;
$$;


--
-- Name: get_company_jsas(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_company_jsas() RETURNS TABLE(id uuid, daily_report_id uuid, job_id uuid, job_number text, job_name text, work_date date, crew_name text, weather_conditions text, job_briefing text, hazards text, controls text, ppe text, emergency_plan text, crew_members text, special_equipment text, foreman_name text, acknowledged_at timestamp with time zone, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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
      v_role in ('gf', 'admin', 'owner', 'superintendent')
      or safety.created_by = auth.uid()
    )
  order by safety.work_date desc, safety.created_at desc;
end;
$$;


--
-- Name: get_company_jsas_scoped(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_company_jsas_scoped(p_show_all boolean DEFAULT false) RETURNS TABLE(id uuid, daily_report_id uuid, job_id uuid, job_number text, job_name text, work_date date, crew_name text, weather_conditions text, job_briefing text, hazards text, controls text, ppe text, emergency_plan text, crew_members text, special_equipment text, foreman_name text, acknowledged_at timestamp with time zone, created_at timestamp with time zone, foreman_id uuid, details jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_has_assignments boolean := false;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active
  from public.profiles p
  where p.id=(select auth.uid());

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501', message='You are not allowed to view JSAs.';
  end if;

  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501', message='This Superintendent does not have safety records permission.';
  end if;

  if v_role='gf' then
    select exists(
      select 1 from public.gf_foreman_assignments a
      where a.company_id=v_company_id and a.gf_id=(select auth.uid())
    ) into v_has_assignments;
  end if;

  return query
  select safety.id,
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
         coalesce(nullif(trim(profile.full_name),''),'Foreman'),
         safety.acknowledged_at,
         safety.created_at,
         safety.created_by,
         coalesce(safety.details,'{}'::jsonb)
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id=safety.job_id and job.company_id=safety.company_id
  left join public.profiles profile
    on profile.id=safety.created_by and profile.company_id=safety.company_id
  where safety.company_id=v_company_id
    and coalesce(safety.jsa_source,'digital')='digital'
    and (
      (v_role='foreman' and safety.created_by=(select auth.uid()))
      or v_role in ('admin','owner','superintendent')
      or (
        v_role='gf' and (
          coalesce(p_show_all,false)
          or not v_has_assignments
          or exists(
            select 1 from public.gf_foreman_assignments a
            where a.company_id=v_company_id
              and a.gf_id=(select auth.uid())
              and a.foreman_id=safety.created_by
          )
        )
      )
    )
  order by safety.work_date desc,safety.created_at desc;
end;
$$;


--
-- Name: get_company_jsas_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_company_jsas_v2() RETURNS TABLE(id uuid, daily_report_id uuid, job_id uuid, job_number text, job_name text, work_date date, crew_name text, weather_conditions text, job_briefing text, hazards text, controls text, ppe text, emergency_plan text, crew_members text, special_equipment text, foreman_name text, acknowledged_at timestamp with time zone, created_at timestamp with time zone, details jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id,lower(coalesce(p.role,''))
    into v_company_id,v_role
  from public.profiles p
  where p.id=auth.uid() and p.active is true;

  if v_company_id is null or v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode='42501',message='You are not allowed to view JSAs.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501',message='Safety Records permission is disabled for this Superintendent.';
  end if;

  return query
  select safety.id,safety.daily_report_id,safety.job_id,job.job_number,job.job_name,
    safety.work_date,safety.crew_name,safety.weather_conditions,safety.job_briefing,
    safety.hazards,safety.controls,safety.ppe,safety.emergency_plan,safety.crew_members,
    safety.special_equipment,coalesce(nullif(trim(profile.full_name),''),'Foreman') as foreman_name,
    safety.acknowledged_at,safety.created_at,coalesce(safety.details,'{}'::jsonb)
  from public.daily_report_jsas safety
  join public.jobs job on job.id=safety.job_id and job.company_id=safety.company_id
  left join public.profiles profile on profile.id=safety.created_by and profile.company_id=safety.company_id
  where safety.company_id=v_company_id
    and coalesce(safety.jsa_source,'digital')='digital'
    and (v_role in ('gf','superintendent','admin','owner') or safety.created_by=auth.uid())
  order by safety.work_date desc,safety.created_at desc;
end;
$$;


--
-- Name: get_complete_job_billing_export_details_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_complete_job_billing_export_details_v1(p_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_lines jsonb;
  v_attachments jsonb;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode = '42501',
      message = 'Billing export access is required.';
  end if;

  select p.company_id
  into v_company_id
  from public.profiles p
  where p.id = auth.uid()
    and p.active = true;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'batch_id', batch.id,
        'line_id', line.id,
        'batch_number', batch.batch_number,
        'job_number', job.job_number,
        'job_name', job.job_name,
        'customer_name', job.customer_name,
        'utility_name', job.utility_name,
        'report_date', line.report_date,
        'foreman_name', line.foreman_name,
        'crew_name', line.crew_name,
        'work_point', line.work_point,
        'unit_code', line.unit_code,
        'unit_name', line.unit_name,
        'unit_description', line.unit_description,
        'work_type', line.work_type,
        'quantity', line.quantity,
        'unit_price', line.unit_price,
        'extended_value', line.extended_value,
        'authorization_status', line.authorization_status
      )
      order by batch.created_at, batch.id,
        case when line.authorization_status = 'authorized' then 0 else 1 end,
        line.report_date, line.work_point, line.unit_code, line.work_type, line.id
    ),
    '[]'::jsonb
  )
  into v_lines
  from public.billing_export_batches batch
  join public.billing_export_lines line
    on line.billing_batch_id = batch.id
   and line.company_id = batch.company_id
  join public.jobs job
    on job.id = line.job_id
   and job.company_id = line.company_id
  where batch.company_id = v_company_id
    and batch.job_id = p_job_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'batch_id', attachment.billing_batch_id,
        'id', attachment.id,
        'storage_path', attachment.storage_path,
        'original_filename', attachment.original_filename,
        'mime_type', attachment.mime_type,
        'file_size_bytes', attachment.file_size_bytes,
        'caption', attachment.caption,
        'uploaded_by', attachment.uploaded_by,
        'created_at', attachment.created_at
      )
      order by batch.created_at, batch.id, attachment.created_at, attachment.id
    ),
    '[]'::jsonb
  )
  into v_attachments
  from public.billing_export_batches batch
  join public.billing_export_attachments attachment
    on attachment.billing_batch_id = batch.id
   and attachment.company_id = batch.company_id
  where batch.company_id = v_company_id
    and batch.job_id = p_job_id;

  return jsonb_build_object('lines', v_lines, 'attachments', v_attachments);
end;
$$;


--
-- Name: get_completed_job_export_details_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_completed_job_export_details_v1(p_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_units jsonb;
  v_audit jsonb;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('owner', 'admin', 'superintendent', 'gf') then
    raise exception using errcode = '42501',
      message = 'Completed job access is required.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and j.active = false
  ) then
    raise exception using errcode = 'P0002',
      message = 'Completed job was not found in your company.';
  end if;

  select coalesce(
    jsonb_agg(
      to_jsonb(unit_row) || jsonb_build_object(
        'report_id', report.id,
        'work_date', report.work_date,
        'foreman_name', report.foreman_name,
        'crew_name', report.crew_name
      )
      order by report.work_date, report.id, unit_row.pole_location, unit_row.item_code,
        unit_row.location_line_id
    ),
    '[]'::jsonb
  )
  into v_units
  from public.daily_reports report
  cross join lateral public.get_daily_report_unit_locations_v2(report.id) unit_row
  where report.company_id = v_company_id
    and report.job_id = p_job_id;

  select coalesce(
    jsonb_agg(
      to_jsonb(audit_row) || jsonb_build_object(
        'report_id', report.id,
        'work_date', report.work_date
      )
      order by report.work_date, report.id, audit_row.event_at desc, audit_row.event_id desc
    ),
    '[]'::jsonb
  )
  into v_audit
  from public.daily_reports report
  cross join lateral public.get_daily_report_audit_history(report.id) audit_row
  where report.company_id = v_company_id
    and report.job_id = p_job_id;

  return jsonb_build_object('units', v_units, 'audit', v_audit);
end;
$$;


--
-- Name: get_contract_field_settings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_contract_field_settings() RETURNS TABLE(contract_id uuid, field_value_percent numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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

  if v_company_id is null or v_profile_active is not true or not (
    v_role in ('admin', 'owner')
    or (
      v_role = 'superintendent'
      and public.linecrew_has_capability('customers_contracts')
    )
  ) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view Field Value settings.';
  end if;

  return query
  select s.contract_id, s.field_value_percent
  from public.contract_field_settings s
  where s.company_id = v_company_id;
end;
$$;


--
-- Name: get_daily_report_audit_history(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_audit_history(p_report_id uuid) RETURNS TABLE(event_id uuid, event_type text, actor_name text, actor_role text, event_notes text, event_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_created_by uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
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
     (v_role not in ('admin', 'gf', 'owner', 'superintendent') and v_created_by <> auth.uid()) then
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


--
-- Name: get_daily_report_authorization_summaries(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_authorization_summaries() RETURNS TABLE(report_id uuid, unit_entry_count bigint, authorized_count bigint, pending_packet_count bigint, redline_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_role_permissions jsonb;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active,
         coalesce(profile.role_permissions, '{}'::jsonb)
  into v_company_id, v_role, v_active, v_role_permissions
  from public.profiles profile where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'owner', 'gf', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can view production summaries.';
  end if;
  if v_role = 'superintendent' and
     not public.linecrew_has_capability('production_review') and
     not public.linecrew_has_capability('reporting') then
    raise exception using errcode = '42501',
      message = 'Production visibility is disabled for this Superintendent.';
  end if;

  return query
  select report.id, count(location.location_line_id),
    count(*) filter (where location.authorization_status = 'authorized'),
    count(*) filter (where location.authorization_status = 'pending_packet'),
    count(*) filter (where location.authorization_status = 'redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations_v2(report.id) location on true
  where report.company_id = v_company_id
  group by report.id;
end;
$$;


--
-- Name: get_daily_report_jsa(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_jsa(p_report_id uuid) RETURNS TABLE(id uuid, daily_report_id uuid, job_briefing text, hazards text, controls text, ppe text, emergency_plan text, crew_members text, special_equipment text, foreman_acknowledged boolean, acknowledged_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select j.id, j.daily_report_id, j.job_briefing, j.hazards, j.controls,
         j.ppe, j.emergency_plan, j.crew_members, j.special_equipment,
         j.foreman_acknowledged, j.acknowledged_at, j.updated_at
  from public.daily_report_jsas j
  join public.profiles p
    on p.id = auth.uid()
   and p.active is true
   and p.company_id = j.company_id
  join public.daily_reports dr
    on dr.id = j.daily_report_id
   and dr.company_id = j.company_id
  where j.daily_report_id = p_report_id
    and (
      lower(coalesce(p.role, '')) in ('admin', 'gf', 'owner')
      or (
        lower(coalesce(p.role, '')) = 'superintendent'
        and public.linecrew_has_capability('safety_records')
      )
      or dr.created_by = auth.uid()
    );
$$;


--
-- Name: get_daily_report_unit_authorized_action(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_unit_authorized_action(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) RETURNS TABLE(preferred_work_type text, authorized_install_quantity numeric, authorized_transfer_quantity numeric, authorized_retirement_quantity numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_job_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode='42501',message='An active production profile is required.';
  end if;

  select r.company_id,r.created_by,r.job_id
  into v_report_company_id,v_report_creator,v_job_id
  from public.daily_reports r where r.id=p_report_id;

  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002',message='Daily report was not found in your company.';
  end if;
  if v_role='foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode='42501',message='Foremen can view unit authorization only on their own reports.';
  end if;

  return query
  with quantities as (
    select
      coalesce(sum(a.authorized_install_quantity),0)::numeric install_qty,
      coalesce(sum(a.authorized_transfer_quantity),0)::numeric transfer_qty,
      coalesce(sum(a.authorized_retirement_quantity),0)::numeric retirement_qty
    from public.job_packages p
    join public.job_package_work_points w
      on w.job_package_id=p.id and w.company_id=p.company_id
    join public.job_package_authorized_units a
      on a.work_point_id=w.id and a.company_id=w.company_id
    where p.company_id=v_company_id and p.job_id=v_job_id and p.status='active'
      and public.normalize_work_point_key(w.work_point_code)=
          public.normalize_work_point_key(p_pole_location)
      and a.price_book_item_id=p_price_book_item_id
  )
  select case
      when q.transfer_qty>0 and q.install_qty=0 and q.retirement_qty=0 then 'transfer'
      when q.retirement_qty>0 and q.install_qty=0 and q.transfer_qty=0 then 'retirement'
      when q.install_qty>0 and q.transfer_qty=0 and q.retirement_qty=0 then 'install'
      else null
    end,
    q.install_qty,q.transfer_qty,q.retirement_qty
  from quantities q;
end;
$$;


--
-- Name: get_daily_report_unit_catalog(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_unit_catalog(p_report_id uuid) RETURNS TABLE(price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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

  v_can_see_actual := public.linecrew_has_capability('actual_pricing');

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


--
-- Name: get_daily_report_unit_catalog_visible(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_unit_catalog_visible(p_report_id uuid) RETURNS TABLE(price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select item.price_book_item_id, item.item_code, item.item_name,
    item.description, item.unit_of_measure, item.category,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.install_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.retirement_price else null end,
    item.actual_install_price, item.actual_retirement_price,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_install_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_retirement_price else null end,
    item.has_adjustment, item.install_quantity, item.retirement_quantity,
    item.actual_line_value,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_line_value else null end,
    case
      when public.linecrew_has_capability('actual_pricing') then item.actual_line_value
      when public.linecrew_has_capability('field_pricing') then item.adjusted_line_value
      else null
    end
  from public.get_daily_report_unit_catalog(p_report_id) item;
$$;


--
-- Name: get_daily_report_unit_locations(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_unit_locations(p_report_id uuid) RETURNS TABLE(location_line_id uuid, price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, pole_location text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric, authorization_status text, authorization_note text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
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

  v_can_see_actual := v_role in ('admin', 'gf', 'owner') or
    (v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing'));

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
    round(location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2),
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
           production.reported_retirement > auth_summary.authorized_retirement then 'redline'
      else 'authorized'
    end,
    case
      when package_summary.package_count = 0
        then 'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when auth_summary.authorized_unit_count = 0
        then 'This unit is not authorized at this pole or work point in the active utility job packet.'
      when production.reported_install > auth_summary.authorized_install or
           production.reported_retirement > auth_summary.authorized_retirement
        then 'Reported quantity exceeds the active utility-authorized quantity at this pole or work point.'
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
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
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
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
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


--
-- Name: get_daily_report_unit_locations_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_unit_locations_v2(p_report_id uuid) RETURNS TABLE(location_line_id uuid, price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, pole_location text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, transfer_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric, authorization_status text, authorization_note text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_job_id uuid;
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using
      errcode = '42501',
      message = 'An active production profile is required.';
  end if;

  select report.company_id, report.created_by, report.job_id
  into v_report_company_id, v_report_creator, v_report_job_id
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  v_can_see_actual := public.linecrew_has_capability('actual_pricing');

  return query
  select location.id, unit.price_book_item_id, unit.item_code, unit.item_name,
    unit.description, unit.unit_of_measure, unit.category, location.pole_location,
    case
      when v_can_see_actual then unit.actual_install_price
      else unit.adjusted_install_price
    end,
    case
      when v_can_see_actual then unit.actual_retirement_price
      else unit.adjusted_retirement_price
    end,
    case when v_can_see_actual then unit.actual_install_price else null end,
    case when v_can_see_actual then unit.actual_retirement_price else null end,
    unit.adjusted_install_price,
    unit.adjusted_retirement_price,
    unit.has_adjustment,
    location.install_quantity,
    location.transfer_quantity,
    location.retirement_quantity,
    case when v_can_see_actual then round(
      location.install_quantity * unit.actual_install_price +
      location.transfer_quantity * unit.actual_transfer_price +
      location.retirement_quantity * unit.actual_retirement_price,
      2
    ) else null end,
    round(
      location.install_quantity * unit.adjusted_install_price +
      location.transfer_quantity * unit.adjusted_transfer_price +
      location.retirement_quantity * unit.adjusted_retirement_price,
      2
    ),
    case when v_can_see_actual then round(
      location.install_quantity * unit.actual_install_price +
      location.transfer_quantity * unit.actual_transfer_price +
      location.retirement_quantity * unit.actual_retirement_price,
      2
    ) else round(
      location.install_quantity * unit.adjusted_install_price +
      location.transfer_quantity * unit.adjusted_transfer_price +
      location.retirement_quantity * unit.adjusted_retirement_price,
      2
    ) end,
    case
      when packages.package_count = 0 then 'pending_packet'
      when authorizations.authorized_unit_count = 0 then 'redline'
      when production.reported_install > authorizations.authorized_install or
           production.reported_transfer > authorizations.authorized_transfer or
           production.reported_retirement > authorizations.authorized_retirement
        then 'redline'
      else 'authorized'
    end,
    case
      when packages.package_count = 0 then
        'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when authorizations.authorized_unit_count = 0 then
        'This unit is not authorized at this pole or work point in the active utility job packet.'
      when production.reported_install > authorizations.authorized_install or
           production.reported_transfer > authorizations.authorized_transfer or
           production.reported_retirement > authorizations.authorized_retirement
        then 'Reported quantity exceeds the active utility-authorized quantity at this pole or work point.'
      else null
    end
  from public.daily_production_unit_locations location
  join public.daily_production_units unit
    on unit.id = location.daily_production_unit_id
   and unit.company_id = location.company_id
   and unit.daily_report_id = location.daily_report_id
   and unit.price_book_item_id = location.price_book_item_id
  cross join lateral (
    select count(*)::integer package_count
    from public.job_packages package
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
  ) packages
  cross join lateral (
    select count(authorized.id)::integer authorized_unit_count,
      coalesce(sum(authorized.authorized_install_quantity), 0) authorized_install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0) authorized_transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0) authorized_retirement
    from public.job_packages package
    join public.job_package_work_points work_point
      on work_point.job_package_id = package.id
     and work_point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = work_point.id
     and authorized.company_id = work_point.company_id
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
      and public.normalize_work_point_key(work_point.work_point_code) =
          public.normalize_work_point_key(location.pole_location)
      and authorized.price_book_item_id = location.price_book_item_id
  ) authorizations
  cross join lateral (
    select
      coalesce(sum(other.install_quantity), 0) reported_install,
      coalesce(sum(other.transfer_quantity), 0) reported_transfer,
      coalesce(sum(other.retirement_quantity), 0) reported_retirement
    from public.daily_production_unit_locations other
    join public.daily_reports report
      on report.id = other.daily_report_id
     and report.company_id = other.company_id
    where other.company_id = v_company_id
      and report.job_id = v_report_job_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
      and other.price_book_item_id = location.price_book_item_id
      and public.normalize_work_point_key(other.pole_location) =
          public.normalize_work_point_key(location.pole_location)
  ) production
  where location.daily_report_id = p_report_id
    and location.company_id = v_company_id
  order by location.pole_location_key, unit.item_code;
end;
$$;


--
-- Name: get_daily_report_unit_locations_visible_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_unit_locations_visible_v2(p_report_id uuid) RETURNS TABLE(location_line_id uuid, price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, pole_location text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, transfer_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric, authorization_status text, authorization_note text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select item.location_line_id, item.price_book_item_id, item.item_code,
    item.item_name, item.description, item.unit_of_measure, item.category,
    item.pole_location,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.install_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.retirement_price else null end,
    item.actual_install_price, item.actual_retirement_price,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_install_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_retirement_price else null end,
    item.has_adjustment, item.install_quantity, item.transfer_quantity,
    item.retirement_quantity, item.actual_line_value,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_line_value else null end,
    case
      when public.linecrew_has_capability('actual_pricing') then item.actual_line_value
      when public.linecrew_has_capability('field_pricing') then item.adjusted_line_value
      else null
    end,
    item.authorization_status, item.authorization_note
  from public.get_daily_report_unit_locations_v2(p_report_id) item;
$$;


--
-- Name: get_daily_report_value_summaries(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_report_value_summaries() RETURNS TABLE(report_id uuid, unit_line_count bigint, actual_total numeric, adjusted_total numeric, visible_total numeric, has_adjustment boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_can_see_actual boolean;
  v_can_see_field boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using
      errcode = '42501',
      message = 'An active company production profile is required.';
  end if;

  v_can_see_actual := public.linecrew_has_capability('actual_pricing');
  v_can_see_field := public.linecrew_has_capability('field_pricing');

  return query
  select report.id, count(unit.id),
    case when v_can_see_actual then coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.actual_install_price +
      coalesce(location.transfer_quantity, 0) * unit.actual_transfer_price +
      unit.retirement_quantity * unit.actual_retirement_price
    ), 0) else null end,
    case when v_can_see_field then coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.adjusted_install_price +
      coalesce(location.transfer_quantity, 0) * unit.adjusted_transfer_price +
      unit.retirement_quantity * unit.adjusted_retirement_price
    ), 0) else null end,
    case
      when v_can_see_actual then coalesce(sum(
        greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.actual_install_price +
        coalesce(location.transfer_quantity, 0) * unit.actual_transfer_price +
        unit.retirement_quantity * unit.actual_retirement_price
      ), 0)
      when v_can_see_field then coalesce(sum(
        greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.adjusted_install_price +
        coalesce(location.transfer_quantity, 0) * unit.adjusted_transfer_price +
        unit.retirement_quantity * unit.adjusted_retirement_price
      ), 0)
      else null
    end,
    coalesce(bool_or(unit.has_adjustment), false)
  from public.daily_reports report
  left join public.daily_production_units unit
    on unit.daily_report_id = report.id
   and unit.company_id = report.company_id
  left join lateral (
    select sum(detail.transfer_quantity) transfer_quantity
    from public.daily_production_unit_locations detail
    where detail.daily_production_unit_id = unit.id
      and detail.company_id = unit.company_id
  ) location on true
  where report.company_id = v_company_id
    and (
      v_role in ('admin','owner','gf','superintendent') or
      report.created_by = auth.uid()
    )
  group by report.id;
end;
$$;


--
-- Name: get_daily_unit_usage_memory(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_unit_usage_memory(p_report_id uuid) RETURNS TABLE(item_code text, use_count bigint, last_used timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_contract_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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


--
-- Name: get_gf_crew_assignment_roster(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_gf_crew_assignment_roster() RETURNS TABLE(foreman_id uuid, foreman_name text, gf_id uuid, gf_name text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','gf','superintendent') then
    raise exception using errcode='42501', message='Company leadership access is required.';
  end if;

  return query
  select f.id,
         coalesce(nullif(trim(f.full_name),''),'Foreman'),
         a.gf_id,
         coalesce(nullif(trim(g.full_name),''),'General Foreman')
  from public.profiles f
  left join public.gf_foreman_assignments a
    on a.company_id = v_company_id
   and a.foreman_id = f.id
  left join public.profiles g
    on g.id = a.gf_id
   and g.company_id = v_company_id
  where f.company_id = v_company_id
    and f.active is true
    and lower(coalesce(f.role,'')) = 'foreman'
  order by coalesce(nullif(trim(f.full_name),''),'Foreman');
end;
$$;


--
-- Name: get_job_assignment_history(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_assignment_history(p_job_id uuid) RETURNS TABLE(action text, member_name text, actor_name text, event_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to view assignment history.';
  end if;

  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  return query
  select event.action, event.member_name, event.actor_name, event.created_at
  from public.job_assignment_audit_events event
  where event.company_id = v_company_id
    and event.job_id = p_job_id
  order by event.created_at desc, event.id desc;
end;
$$;


--
-- Name: get_job_billing_reconciliation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_billing_reconciliation(p_job_id uuid) RETURNS TABLE(job_id uuid, authorized_value numeric, approved_value numeric, remaining_authorized_value numeric, billed_value numeric, credit_value numeric, net_billed_value numeric, approved_unbilled_value numeric, awaiting_review_count bigint, draft_report_count bigint, pending_packet_count bigint, redline_count bigint, active_batch_count bigint, final_bill_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using errcode = '42501', message = 'Billing access is required.';
  end if;
  if v_role = 'superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode = '42501',
      message = 'Reporting and Actual Pricing permissions are required.';
  end if;
  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002', message = 'Job was not found in your company.';
  end if;

  return query
  with progress as (
    select * from public.get_job_progress_dashboard() dashboard
    where dashboard.job_id = p_job_id
  ), eligible as (
    select location.location_line_id production_location_id,
      location.install_quantity, location.transfer_quantity, location.retirement_quantity,
      location.actual_install_price, unit.actual_transfer_price,
      location.actual_retirement_price
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    join public.daily_production_unit_locations source
      on source.id = location.location_line_id and source.company_id = report.company_id
    join public.daily_production_units unit
      on unit.id = source.daily_production_unit_id and unit.company_id = source.company_id
    where report.company_id = v_company_id and report.job_id = p_job_id
      and lower(coalesce(report.status, '')) = 'approved'
      and location.authorization_status in ('authorized', 'redline')
  ), actions as (
    select eligible.production_location_id, 'INSTALL'::text work_type,
      round(eligible.install_quantity * coalesce(eligible.actual_install_price, 0), 2) value
    from eligible where eligible.install_quantity > 0
    union all
    select eligible.production_location_id, 'TRANSFER'::text,
      round(eligible.transfer_quantity * coalesce(eligible.actual_transfer_price, 0), 2)
    from eligible where eligible.transfer_quantity > 0
    union all
    select eligible.production_location_id, 'REMOVE'::text,
      round(eligible.retirement_quantity * coalesce(eligible.actual_retirement_price, 0), 2)
    from eligible where eligible.retirement_quantity > 0
  ), approved as (
    select coalesce(sum(action.value), 0) approved_total,
      coalesce(sum(action.value) filter (where not exists (
        select 1 from public.billing_export_lines line
        where line.company_id = v_company_id
          and line.production_location_id = action.production_location_id
          and line.work_type = action.work_type and line.active
      )), 0) approved_unbilled
    from actions action
  ), batches as (
    select coalesce(sum(case
        when batch.status not in ('void', 'draft') and batch.billing_type <> 'credit'
        then batch.total_value else 0 end), 0) billed,
      coalesce(sum(case
        when batch.status not in ('void', 'draft') and batch.billing_type = 'credit'
        then batch.total_value else 0 end), 0) credits,
      count(*) filter (where batch.status not in ('void', 'draft')) active_batches,
      count(*) filter (where batch.status not in ('void', 'draft')
        and batch.billing_type = 'final') finals
    from public.billing_export_batches batch
    where batch.company_id = v_company_id and batch.job_id = p_job_id
  ), reports as (
    select count(*) filter (where lower(coalesce(report.status, '')) = 'submitted') awaiting,
      count(*) filter (where lower(coalesce(report.status, '')) in ('draft', 'returned')) drafts
    from public.daily_reports report
    where report.company_id = v_company_id and report.job_id = p_job_id and not report.archived
  )
  select p_job_id, coalesce(progress.authorized_value, 0), approved.approved_total,
    greatest(coalesce(progress.remaining_value, 0), 0), batches.billed,
    abs(batches.credits), batches.billed + batches.credits,
    approved.approved_unbilled, reports.awaiting, reports.drafts,
    coalesce(progress.pending_packet_count, 0), coalesce(progress.redline_count, 0),
    batches.active_batches, batches.finals
  from progress cross join approved cross join batches cross join reports;
end;
$$;


--
-- Name: get_job_closeout_history(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_closeout_history(p_job_id uuid) RETURNS TABLE(id uuid, action text, reason text, blockers jsonb, actor_id uuid, actor_name text, actor_role text, occurred_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: get_job_leader_assignments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_leader_assignments() RETURNS TABLE(job_id uuid, member_id uuid, full_name text, member_role text, assigned_by_name text, assigned_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (
       v_role = 'superintendent'
       and not public.linecrew_has_capability('jobs')
       and not public.linecrew_has_capability('reporting')
     ) then
    raise exception using errcode = '42501',
      message = 'Jobs or Reporting permission is required to view job assignments.';
  end if;

  return query
  select
    assignment.job_id,
    assignment.member_id,
    coalesce(nullif(trim(member.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(member.role, 'foreman'))::text,
    coalesce(nullif(trim(actor.full_name), ''), 'Unknown Team Member')::text,
    assignment.created_at
  from public.job_leader_assignments assignment
  join public.jobs job
    on job.id = assignment.job_id
   and job.company_id = assignment.company_id
  join public.profiles member
    on member.id = assignment.member_id
   and member.company_id = assignment.company_id
  left join public.profiles actor
    on actor.id = assignment.assigned_by
   and actor.company_id = assignment.company_id
  where assignment.company_id = v_company_id
  order by lower(coalesce(member.full_name, ''));
end;
$$;


--
-- Name: get_job_package_revision_delta(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_package_revision_delta(p_package_id uuid) RETURNS TABLE(work_point text, unit_code text, prior_install numeric, new_install numeric, install_change numeric, prior_remove numeric, new_remove numeric, remove_change numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_prior uuid;
begin
  select p.company_id into v_company
  from public.profiles p
  where p.id=auth.uid() and p.active;

  if v_company is null then
    raise exception using errcode='42501',message='Company access is required.';
  end if;

  select package.supersedes_package_id into v_prior
  from public.job_packages package
  where package.id=p_package_id and package.company_id=v_company;

  if not found then
    raise exception using errcode='P0002',message='Job package was not found.';
  end if;

  return query with old_units as (
    select wp.work_point_code wp,u.unit_code,sum(u.authorized_install_quantity) install,
      sum(u.authorized_retirement_quantity) remove_qty
    from public.job_package_authorized_units u
    join public.job_package_work_points wp on wp.id=u.work_point_id
    where u.job_package_id=v_prior
      and u.company_id=v_company
      and wp.company_id=v_company
    group by wp.work_point_code,u.unit_code
  ), new_units as (
    select wp.work_point_code wp,u.unit_code,sum(u.authorized_install_quantity) install,
      sum(u.authorized_retirement_quantity) remove_qty
    from public.job_package_authorized_units u
    join public.job_package_work_points wp on wp.id=u.work_point_id
    where u.job_package_id=p_package_id
      and u.company_id=v_company
      and wp.company_id=v_company
    group by wp.work_point_code,u.unit_code
  ) select coalesce(n.wp,o.wp),coalesce(n.unit_code,o.unit_code),coalesce(o.install,0),
    coalesce(n.install,0),coalesce(n.install,0)-coalesce(o.install,0),coalesce(o.remove_qty,0),
    coalesce(n.remove_qty,0),coalesce(n.remove_qty,0)-coalesce(o.remove_qty,0)
  from old_units o full join new_units n on n.wp=o.wp and n.unit_code=o.unit_code
  where coalesce(n.install,0)<>coalesce(o.install,0)
    or coalesce(n.remove_qty,0)<>coalesce(o.remove_qty,0)
  order by coalesce(n.wp,o.wp),coalesce(n.unit_code,o.unit_code);
end;
$$;


--
-- Name: get_job_package_revision_delta_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_package_revision_delta_v2(p_package_id uuid) RETURNS TABLE(work_point text, unit_code text, prior_install numeric, new_install numeric, install_change numeric, prior_transfer numeric, new_transfer numeric, transfer_change numeric, prior_remove numeric, new_remove numeric, remove_change numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_prior_package_id uuid;
begin
  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'Company access is required.';
  end if;

  select package.supersedes_package_id
  into v_prior_package_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Job package was not found.';
  end if;

  return query
  with old_units as (
    select
      public.normalize_work_point_key(point.work_point_code) as point_key,
      min(point.work_point_code) as display_point,
      lower(btrim(authorized.unit_code)) as unit_key,
      min(authorized.unit_code) as display_unit_code,
      coalesce(sum(authorized.authorized_install_quantity), 0)::numeric as install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0)::numeric as transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0)::numeric as remove_qty
    from public.job_package_authorized_units authorized
    join public.job_package_work_points point
      on point.id = authorized.work_point_id
     and point.company_id = authorized.company_id
     and point.job_package_id = authorized.job_package_id
    where authorized.job_package_id = v_prior_package_id
      and authorized.company_id = v_company_id
    group by
      public.normalize_work_point_key(point.work_point_code),
      lower(btrim(authorized.unit_code))
  ), new_units as (
    select
      public.normalize_work_point_key(point.work_point_code) as point_key,
      min(point.work_point_code) as display_point,
      lower(btrim(authorized.unit_code)) as unit_key,
      min(authorized.unit_code) as display_unit_code,
      coalesce(sum(authorized.authorized_install_quantity), 0)::numeric as install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0)::numeric as transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0)::numeric as remove_qty
    from public.job_package_authorized_units authorized
    join public.job_package_work_points point
      on point.id = authorized.work_point_id
     and point.company_id = authorized.company_id
     and point.job_package_id = authorized.job_package_id
    where authorized.job_package_id = p_package_id
      and authorized.company_id = v_company_id
    group by
      public.normalize_work_point_key(point.work_point_code),
      lower(btrim(authorized.unit_code))
  )
  select
    coalesce(new_unit.display_point, old_unit.display_point),
    coalesce(new_unit.display_unit_code, old_unit.display_unit_code),
    coalesce(old_unit.install, 0),
    coalesce(new_unit.install, 0),
    coalesce(new_unit.install, 0) - coalesce(old_unit.install, 0),
    coalesce(old_unit.transfer, 0),
    coalesce(new_unit.transfer, 0),
    coalesce(new_unit.transfer, 0) - coalesce(old_unit.transfer, 0),
    coalesce(old_unit.remove_qty, 0),
    coalesce(new_unit.remove_qty, 0),
    coalesce(new_unit.remove_qty, 0) - coalesce(old_unit.remove_qty, 0)
  from old_units old_unit
  full join new_units new_unit
    on new_unit.point_key = old_unit.point_key
   and new_unit.unit_key = old_unit.unit_key
  where coalesce(new_unit.install, 0) <> coalesce(old_unit.install, 0)
     or coalesce(new_unit.transfer, 0) <> coalesce(old_unit.transfer, 0)
     or coalesce(new_unit.remove_qty, 0) <> coalesce(old_unit.remove_qty, 0)
  order by
    coalesce(new_unit.point_key, old_unit.point_key),
    coalesce(new_unit.display_unit_code, old_unit.display_unit_code);
end;
$$;


--
-- Name: get_job_package_work_points(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_package_work_points(p_package_id uuid) RETURNS TABLE(work_point_id uuid, work_point_code text, work_point_description text, authorized_unit_id uuid, unit_code text, unit_name text, unit_description text, authorized_install_quantity numeric, authorized_retirement_quantity numeric, reported_install_quantity numeric, reported_retirement_quantity numeric, approved_install_quantity numeric, approved_retirement_quantity numeric, authorized_value numeric, reported_value numeric, approved_value numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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

  if v_company_id is null or not v_active or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only active company leadership can view package progress.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select work_point.id, work_point.work_point_code, work_point.description,
    authorized.id, authorized.unit_code, item.item_name, item.description,
    coalesce(
      authorized.authorized_install_quantity +
      authorized.authorized_transfer_quantity,
      0
    ),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install + production.reported_transfer, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install + production.approved_transfer, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_transfer_quantity * item.transfer_price +
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.reported_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.reported_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.reported_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.approved_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.approved_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.approved_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
      0
    )
  from public.job_package_work_points work_point
  left join public.job_package_authorized_units authorized
    on authorized.work_point_id = work_point.id
   and authorized.company_id = work_point.company_id
  left join public.price_book_items item
    on item.id = authorized.price_book_item_id
   and item.company_id = authorized.company_id
  left join lateral (
    select
      coalesce(sum(location.install_quantity), 0) reported_install,
      coalesce(sum(location.transfer_quantity), 0) reported_transfer,
      coalesce(sum(location.retirement_quantity), 0) reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_install,
      coalesce(sum(location.transfer_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_transfer,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(work_point.work_point_code)
      and location.price_book_item_id = authorized.price_book_item_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
  ) production on authorized.id is not null
  where work_point.job_package_id = p_package_id
    and work_point.company_id = v_company_id
  order by work_point.work_point_key, authorized.unit_code;
end;
$$;


--
-- Name: get_job_package_work_points_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_package_work_points_v2(p_package_id uuid) RETURNS TABLE(work_point_id uuid, work_point_code text, work_point_description text, authorized_unit_id uuid, unit_code text, unit_name text, unit_description text, authorized_install_quantity numeric, authorized_transfer_quantity numeric, authorized_retirement_quantity numeric, reported_install_quantity numeric, reported_transfer_quantity numeric, reported_retirement_quantity numeric, approved_install_quantity numeric, approved_transfer_quantity numeric, approved_retirement_quantity numeric, authorized_value numeric, reported_value numeric, approved_value numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_job_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view package progress.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select point.id, point.work_point_code, point.description,
    authorized.id, authorized.unit_code, item.item_name, item.description,
    coalesce(authorized.authorized_install_quantity, 0),
    coalesce(authorized.authorized_transfer_quantity, 0),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install, 0),
    coalesce(production.reported_transfer, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install, 0),
    coalesce(production.approved_transfer, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_transfer_quantity * item.transfer_price +
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.reported_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.reported_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.reported_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.approved_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.approved_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.approved_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
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
      coalesce(sum(location.install_quantity), 0) reported_install,
      coalesce(sum(location.transfer_quantity), 0) reported_transfer,
      coalesce(sum(location.retirement_quantity), 0) reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_install,
      coalesce(sum(location.transfer_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_transfer,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and location.price_book_item_id = authorized.price_book_item_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
  ) production on authorized.id is not null
  where point.job_package_id = p_package_id
    and point.company_id = v_company_id
  order by point.work_point_key, authorized.unit_code;
end;
$$;


--
-- Name: get_job_packages(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_packages(p_job_id uuid DEFAULT NULL::uuid) RETURNS TABLE(id uuid, job_id uuid, contract_id uuid, package_name text, package_number text, received_date date, source_filename text, notes text, status text, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
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


--
-- Name: get_job_packages_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_packages_v2(p_job_id uuid DEFAULT NULL::uuid) RETURNS TABLE(id uuid, job_id uuid, contract_id uuid, package_name text, package_number text, received_date date, source_filename text, notes text, status text, revision_number integer, supersedes_package_id uuid, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
  into v_company, v_role
  from public.profiles p
  where p.id = auth.uid() and p.active;

  if v_company is null or
     v_role not in ('owner', 'admin', 'gf', 'superintendent', 'foreman') then
    raise exception using errcode = '42501', message = 'Company access is required.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('job_packages') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have job package permission.';
  end if;
  if p_job_id is not null and not exists (
    select 1 from public.jobs j
    where j.id = p_job_id and j.company_id = v_company
      and (v_role <> 'foreman' or public.linecrew_foreman_has_job_assignment(j.id))
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found or is not assigned to this Foreman.';
  end if;

  return query
  select package.id, package.job_id, package.contract_id, package.package_name,
    package.package_number, package.received_date, package.source_filename,
    package.notes, package.status, package.revision_number,
    package.supersedes_package_id, package.created_at, package.updated_at
  from public.job_packages package
  where package.company_id = v_company
    and (p_job_id is null or package.job_id = p_job_id)
    and (v_role <> 'foreman' or public.linecrew_foreman_has_job_assignment(package.job_id))
  order by package.job_id, package.revision_number desc;
end;
$$;


--
-- Name: get_job_progress_dashboard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_job_progress_dashboard() RETURNS TABLE(job_id uuid, package_count bigint, work_point_count bigint, authorized_value numeric, reported_value numeric, approved_value numeric, remaining_value numeric, reported_percent numeric, approved_percent numeric, report_count bigint, redline_count bigint, pending_packet_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only active company leadership can view job progress.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('reporting') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have reporting permission.';
  end if;

  return query
  with package_totals as (
    select
      package.job_id,
      count(distinct package.id)::bigint package_count,
      count(distinct progress.work_point_id)::bigint work_point_count,
      coalesce(sum(progress.authorized_value), 0)::numeric authorized_value,
      coalesce(sum(progress.reported_value), 0)::numeric reported_value,
      coalesce(sum(progress.approved_value), 0)::numeric approved_value
    from public.job_packages package
    left join lateral
      public.get_job_package_work_points(package.id) progress on true
    where package.company_id = v_company_id
      and package.status = 'active'
    group by package.job_id
  ), report_totals as (
    select
      report.job_id,
      count(distinct report.id)::bigint report_count
    from public.daily_reports report
    where report.company_id = v_company_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
    group by report.job_id
  ), exception_totals as (
    select report.job_id,
      count(*) filter (
        where location.authorization_status = 'redline'
      )::bigint redline_count,
      count(*) filter (
        where location.authorization_status = 'pending_packet'
      )::bigint pending_packet_count
    from public.daily_reports report
    cross join lateral
      public.get_daily_report_unit_locations_v2(report.id) location
    where report.company_id = v_company_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
    group by report.job_id
  )
  select
    job.id,
    coalesce(package.package_count, 0),
    coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0),
    coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(
      coalesce(package.authorized_value, 0) -
      coalesce(package.reported_value, 0),
      0
    ),
    case
      when coalesce(package.authorized_value, 0) > 0 then round(
        least(package.reported_value / package.authorized_value * 100, 100),
        1
      )
      else 0
    end,
    case
      when coalesce(package.authorized_value, 0) > 0 then round(
        least(package.approved_value / package.authorized_value * 100, 100),
        1
      )
      else 0
    end,
    coalesce(report.report_count, 0),
    coalesce(exception.redline_count, 0),
    coalesce(exception.pending_packet_count, 0)
  from public.jobs job
  left join package_totals package
    on package.job_id = job.id
  left join report_totals report
    on report.job_id = job.id
  left join exception_totals exception
    on exception.job_id = job.id
  where job.company_id = v_company_id
  order by job.active desc, job.created_at desc;
end;
$$;


--
-- Name: get_jsa_upload_attachments(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_jsa_upload_attachments(p_jsa_id uuid) RETURNS TABLE(id uuid, storage_path text, original_filename text, mime_type text, file_size_bytes bigint, page_order integer, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$ declare v_company_id uuid; v_role text; v_creator uuid; begin select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role from public.profiles p where p.id=auth.uid() and p.active is true; select j.created_by into v_creator from public.daily_report_jsas j where j.id=p_jsa_id and j.company_id=v_company_id and j.jsa_source='upload'; if v_creator is null then raise exception using errcode='P0002',message='Uploaded JSA not found.'; end if; if v_role='foreman' and v_creator<>auth.uid() then raise exception using errcode='42501',message='Foremen can view only their own uploaded JSAs.'; end if; if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then raise exception using errcode='42501',message='Safety Records permission is disabled for this Superintendent.'; end if; return query select a.id,a.storage_path,a.original_filename,a.mime_type,a.file_size_bytes,a.page_order,a.created_at from public.jsa_upload_attachments a where a.company_id=v_company_id and a.jsa_id=p_jsa_id order by a.page_order,a.created_at; end; $$;


--
-- Name: get_pending_utility_packet_import_for_package(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_pending_utility_packet_import_for_package(p_package_id uuid) RETURNS TABLE(import_id uuid, provider_key text, format_key text, profile_version text, source_filename text, detected_work_order text, extraction_confidence numeric, extraction_summary jsonb)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select packet_import.id, packet_import.provider_key, packet_import.format_key,
    packet_import.profile_version, packet_import.source_filename,
    packet_import.detected_work_order, packet_import.extraction_confidence,
    packet_import.extraction_summary
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  where packet_import.job_package_id = p_package_id
    and packet_import.status = 'review'
    and (
      lower(coalesce(profile.role,'')) in ('owner','admin','gf')
      or (
        lower(coalesce(profile.role,'')) = 'superintendent'
        and public.linecrew_has_capability('job_packages')
      )
    )
  order by packet_import.created_at desc
  limit 1;
$$;


--
-- Name: get_price_book_items_for_user(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_price_book_items_for_user(p_price_book_id uuid) RETURNS TABLE(id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text, description text, install_price numeric, transfer_price numeric, retirement_price numeric, unit_of_measure text, category text, extra_data jsonb, active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, actual_install_price numeric, actual_transfer_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_transfer_price numeric, adjusted_retirement_price numeric, has_adjustment boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501',
      message = 'An active company profile is required.';
  end if;
  if v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Your role cannot view contract unit values.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('price_books') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
  if not exists (
    select 1 from public.price_books book
    where book.id = p_price_book_id and book.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;

  v_can_see_actual := public.linecrew_has_capability('actual_pricing');

  return query
  select item.id, item.company_id, item.price_book_id, item.item_code,
    item.item_name, item.description,
    case when v_can_see_actual then item.install_price
      else round(item.install_price * coalesce(setting.field_value_percent, 100) / 100, 2) end,
    case when v_can_see_actual then item.transfer_price
      else round(item.transfer_price * coalesce(setting.field_value_percent, 100) / 100, 2) end,
    case when v_can_see_actual then item.retirement_price
      else round(item.retirement_price * coalesce(setting.field_value_percent, 100) / 100, 2) end,
    item.unit_of_measure, item.category, item.extra_data, item.active,
    item.created_at, item.updated_at,
    case when v_can_see_actual then item.install_price else null end,
    case when v_can_see_actual then item.transfer_price else null end,
    case when v_can_see_actual then item.retirement_price else null end,
    round(item.install_price * coalesce(setting.field_value_percent, 100) / 100, 2),
    round(item.transfer_price * coalesce(setting.field_value_percent, 100) / 100, 2),
    round(item.retirement_price * coalesce(setting.field_value_percent, 100) / 100, 2),
    setting.field_value_percent is not null
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id and book.company_id = item.company_id
  left join public.contract_field_settings setting
    on setting.contract_id = book.contract_id and setting.company_id = item.company_id
  where item.price_book_id = p_price_book_id and item.company_id = v_company_id
  order by item.active desc, item.item_code;
end;
$$;


--
-- Name: get_price_book_items_visible(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_price_book_items_visible(p_price_book_id uuid) RETURNS TABLE(id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text, description text, install_price numeric, transfer_price numeric, retirement_price numeric, unit_of_measure text, category text, extra_data jsonb, active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, actual_install_price numeric, actual_transfer_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_transfer_price numeric, adjusted_retirement_price numeric, has_adjustment boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select item.id, item.company_id, item.price_book_id, item.item_code,
    item.item_name, item.description,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.install_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.transfer_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.retirement_price else null end,
    item.unit_of_measure, item.category, item.extra_data, item.active,
    item.created_at, item.updated_at,
    item.actual_install_price, item.actual_transfer_price,
    item.actual_retirement_price,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_install_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_transfer_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_retirement_price else null end,
    item.has_adjustment
  from public.get_price_book_items_for_user(p_price_book_id) item;
$$;


--
-- Name: get_remaining_job_units_for_field(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_remaining_job_units_for_field(p_job_id uuid) RETURNS TABLE(package_id uuid, package_name text, work_point_id uuid, work_point_code text, work_point_description text, authorized_unit_id uuid, unit_code text, unit_name text, unit_description text, work_type text, authorized_quantity numeric, draft_quantity numeric, submitted_quantity numeric, approved_quantity numeric, remaining_quantity numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using
      errcode = '42501',
      message = 'An active company field or leadership profile is required.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job package permission.';
  end if;

  if not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
      and job.active is true
      and (
        v_role <> 'foreman'
        or public.linecrew_foreman_has_job_assignment(job.id)
      )
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Active job was not found or is not assigned to this Foreman.';
  end if;

  return query
  with authorized_rows as (
    select
      package.id as package_id,
      package.package_name,
      point.id as work_point_id,
      point.work_point_code,
      point.description as work_point_description,
      authorized.id as authorized_unit_id,
      authorized.price_book_item_id,
      authorized.unit_code,
      item.item_name as unit_name,
      item.description as unit_description,
      work.work_type,
      work.authorized_quantity
    from public.job_packages package
    join public.job_package_work_points point
      on point.job_package_id = package.id
     and point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = point.id
     and authorized.company_id = point.company_id
    left join public.price_book_items item
      on item.id = authorized.price_book_item_id
     and item.company_id = authorized.company_id
    cross join lateral (
      values
        ('install'::text, coalesce(authorized.authorized_install_quantity, 0)),
        ('transfer'::text, coalesce(authorized.authorized_transfer_quantity, 0)),
        ('remove'::text, coalesce(authorized.authorized_retirement_quantity, 0))
    ) work(work_type, authorized_quantity)
    where package.company_id = v_company_id
      and package.job_id = p_job_id
      and package.status = 'active'
      and work.authorized_quantity > 0
  ), usage as (
    select
      authorized.authorized_unit_id,
      authorized.work_type,
      coalesce(sum(
        case
          when lower(coalesce(report.status, 'draft')) = 'draft'
          then case authorized.work_type
            when 'install' then location.install_quantity
            when 'transfer' then location.transfer_quantity
            else location.retirement_quantity
          end
          else 0
        end
      ), 0)::numeric as draft_quantity,
      coalesce(sum(
        case when lower(coalesce(report.status, '')) = 'submitted'
          then case authorized.work_type
            when 'install' then location.install_quantity
            when 'transfer' then location.transfer_quantity
            else location.retirement_quantity
          end
          else 0
        end
      ), 0)::numeric as submitted_quantity,
      coalesce(sum(
        case when lower(coalesce(report.status, '')) = 'approved'
          then case authorized.work_type
            when 'install' then location.install_quantity
            when 'transfer' then location.transfer_quantity
            else location.retirement_quantity
          end
          else 0
        end
      ), 0)::numeric as approved_quantity
    from authorized_rows authorized
    join public.daily_production_unit_locations location
      on location.company_id = v_company_id
     and location.price_book_item_id = authorized.price_book_item_id
     and public.normalize_work_point_key(location.pole_location) =
         public.normalize_work_point_key(authorized.work_point_code)
    join public.daily_production_units line
      on line.id = location.daily_production_unit_id
     and line.company_id = location.company_id
     and line.job_id = p_job_id
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
     and report.job_id = p_job_id
     and public.linecrew_report_counts_toward_progress(
       report.status,
       report.reviewed_at,
       report.review_notes,
       report.archived
     )
    group by authorized.authorized_unit_id, authorized.work_type
  )
  select
    authorized.package_id,
    authorized.package_name,
    authorized.work_point_id,
    authorized.work_point_code,
    authorized.work_point_description,
    authorized.authorized_unit_id,
    authorized.unit_code,
    authorized.unit_name,
    authorized.unit_description,
    authorized.work_type,
    authorized.authorized_quantity,
    coalesce(usage.draft_quantity, 0),
    coalesce(usage.submitted_quantity, 0),
    coalesce(usage.approved_quantity, 0),
    greatest(
      authorized.authorized_quantity -
      coalesce(usage.draft_quantity, 0) -
      coalesce(usage.submitted_quantity, 0) -
      coalesce(usage.approved_quantity, 0),
      0
    )::numeric as remaining_quantity
  from authorized_rows authorized
  left join usage
    on usage.authorized_unit_id = authorized.authorized_unit_id
   and usage.work_type = authorized.work_type
  order by
    public.normalize_work_point_key(authorized.work_point_code),
    authorized.unit_code,
    authorized.work_type;
end;
$$;


--
-- Name: get_storm_mode_assignments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_storm_mode_assignments() RETURNS TABLE(user_id uuid, full_name text, role text, active boolean, assigned boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('admin','owner','superintendent') then
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
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin', 'owner', 'superintendent')
  order by
    case lower(coalesce(p.role, 'foreman'))
      when 'gf' then 1
      when 'foreman' then 2
      else 3
    end,
    lower(coalesce(p.full_name, ''));
end;
$$;


--
-- Name: get_uploaded_company_jsas(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_uploaded_company_jsas() RETURNS TABLE(id uuid, job_id uuid, work_date date, crew_name text, upload_notes text, created_by uuid, created_at timestamp with time zone, job_number text, job_name text, creator_name text, attachment_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$ declare v_company_id uuid; v_role text; begin select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role from public.profiles p where p.id=auth.uid() and p.active is true; if v_company_id is null then raise exception using errcode='42501',message='An active company profile is required.'; end if; if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then raise exception using errcode='42501',message='Safety Records permission is disabled for this Superintendent.'; end if; return query select j.id,j.job_id,j.work_date,j.crew_name,j.upload_notes,j.created_by,j.created_at,jobs.job_number,jobs.job_name,p.full_name,count(a.id)::bigint from public.daily_report_jsas j join public.jobs jobs on jobs.id=j.job_id and jobs.company_id=j.company_id left join public.profiles p on p.id=j.created_by and p.company_id=j.company_id left join public.jsa_upload_attachments a on a.jsa_id=j.id and a.company_id=j.company_id where j.company_id=v_company_id and j.jsa_source='upload' and (v_role<>'foreman' or j.created_by=auth.uid()) group by j.id,j.job_id,j.work_date,j.crew_name,j.upload_notes,j.created_by,j.created_at,jobs.job_number,jobs.job_name,p.full_name order by j.work_date desc,j.created_at desc; end; $$;


--
-- Name: get_utility_packet_import_review(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_utility_packet_import_review(p_import_id uuid) RETURNS TABLE(row_id uuid, source_page integer, source_row integer, work_point_code text, work_point_description text, work_type text, material_cu text, contractor_unit_code text, estimated_quantity numeric, description text, confidence numeric, include_in_import boolean, review_note text, price_book_match boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with matches as materialized (
    select *
    from public.linecrew_utility_packet_import_matches(p_import_id)
  )
  select row_item.id,
    row_item.source_page,
    row_item.source_row,
    row_item.work_point_code,
    row_item.work_point_description,
    row_item.work_type,
    row_item.material_cu,
    row_item.contractor_unit_code,
    row_item.estimated_quantity,
    row_item.description,
    row_item.confidence,
    row_item.include_in_import,
    row_item.review_note,
    matches.price_book_item_id is not null
  from public.utility_packet_import_rows row_item
  join public.utility_packet_imports packet_import
    on packet_import.id = row_item.import_id
   and packet_import.company_id = row_item.company_id
   and packet_import.status = 'review'
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  left join matches
    on matches.row_id = row_item.id
  where row_item.import_id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by row_item.source_page nulls last,
    row_item.source_row,
    row_item.id;
$$;


--
-- Name: FUNCTION get_utility_packet_import_review(p_import_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_utility_packet_import_review(p_import_id uuid) IS 'Returns every staged packet row with live Price Book matching, in a total order (source page, source row, id) so the reviewer can page through the full set without duplicating or skipping rows.';


--
-- Name: guard_timekeeping_locked_period(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_timekeeping_locked_period() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company uuid;
  v_work_date date;
  v_period record;
begin
  if tg_op='DELETE' then
    v_company:=old.company_id;
    v_work_date:=old.work_date;
  else
    v_company:=new.company_id;
    v_work_date:=new.work_date;
  end if;

  select pp.* into v_period
  from public.timekeeping_pay_periods pp
  where pp.company_id=v_company
    and v_work_date between pp.period_start and pp.period_end
    and pp.status in ('approved','locked')
  order by case pp.status when 'locked' then 0 else 1 end, pp.period_start desc
  limit 1;

  if found and v_period.status='locked' then
    raise exception using errcode='42501', message='This pay period is locked. Unlock it before changing Timekeeping.';
  end if;

  if found and v_period.status='approved' then
    update public.timekeeping_pay_periods
       set status='open', approved_by=null, approved_at=null, updated_at=now()
     where id=v_period.id;
    insert into public.timekeeping_pay_period_audit(company_id,period_start,period_end,action,actor_id,detail)
    values(v_company,v_period.period_start,v_period.period_end,'auto_reopen',auth.uid(),'Time entry changed after approval');
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


--
-- Name: import_job_package_units(uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.import_job_package_units(p_package_id uuid, p_rows jsonb, p_source_filename text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_job_id uuid;
  v_job_active boolean;
  v_existing_package_status text;
  v_job_price_book_id uuid;
  v_price_book_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_description text;
  v_unit_code text;
  v_install numeric;
  v_transfer numeric;
  v_retirement numeric;
  v_work_point_id uuid;
  v_item_id uuid;
  v_canonical_code text;
  v_imported integer := 0;
  v_package_status text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  select package.contract_id, package.job_id, job.active, package.status,
    job.price_book_id
  into v_contract_id, v_job_id, v_job_active, v_existing_package_status,
    v_job_price_book_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.active is true
  where package.id = p_package_id
    and package.company_id = v_company_id
  for update of package, job;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if v_job_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reopen the job before importing its utility package.';
  end if;

  if v_existing_package_status not in ('draft', 'active') then
    raise exception using
      errcode = '22023',
      message = 'A closed utility package cannot be imported again.';
  end if;

  v_price_book_id := public.linecrew_resolve_job_price_book(
    v_company_id,
    v_job_id,
    v_contract_id
  );

  if v_price_book_id is null then
    if v_job_price_book_id is not null then
      raise exception using
        errcode = '22023',
        message = 'The job selected Price Book is not active for this contract.';
    else
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book is available for this job contract.';
    end if;
  end if;

  perform 1
  from public.price_books book
  where book.id = v_price_book_id
    and book.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'The selected job Price Book is no longer active.';
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 2000 then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  -- Validate and lock every referenced item before the first write. This keeps
  -- validation and insertion on the same Price Book snapshot.
  for v_row, v_row_number in
    select row_item.value, row_item.ordinality::integer
    from jsonb_array_elements(p_rows) with ordinality as row_item(value, ordinality)
  loop
    v_work_point := btrim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := btrim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    if v_work_point = '' then
      raise exception using
        errcode = '22023',
        message = format('Spreadsheet row %s is missing a work point.', v_row_number);
    end if;

    if v_unit_code = '' then
      raise exception using
        errcode = '22023',
        message = format('Spreadsheet row %s is missing a unit code.', v_row_number);
    end if;

    if v_install < 0 or v_transfer < 0 or v_retirement < 0
       or v_install + v_transfer + v_retirement <= 0 then
      raise exception using
        errcode = '22023',
        message = format(
          'Spreadsheet row %s must have a nonnegative authorized quantity greater than zero.',
          v_row_number
        );
    end if;

    v_item_id := null;
    select item.id
    into v_item_id
    from public.price_book_items item
    where item.company_id = v_company_id
      and item.price_book_id = v_price_book_id
      and item.active is true
      and lower(btrim(item.item_code)) = lower(v_unit_code)
    for share;

    if v_item_id is null then
      raise exception using
        errcode = 'P0002',
        message = format(
          'Unit code "%s" was not found in the selected job Price Book.',
          v_unit_code
        );
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_work_point := btrim(v_row->>'work_point_code');
    v_description := nullif(btrim(coalesce(
      v_row->>'work_point_description', ''
    )), '');
    v_unit_code := btrim(v_row->>'unit_code');
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    v_work_point_id := null;
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
      set description = coalesce(description, v_description),
          updated_at = now()
      where id = v_work_point_id
        and company_id = v_company_id;
    end if;

    v_item_id := null;
    v_canonical_code := null;
    select item.id, item.item_code
    into v_item_id, v_canonical_code
    from public.price_book_items item
    where item.company_id = v_company_id
      and item.price_book_id = v_price_book_id
      and item.active is true
      and lower(btrim(item.item_code)) = lower(v_unit_code)
    for share;

    if v_item_id is null then
      raise exception using
        errcode = 'P0002',
        message = format(
          'Unit code "%s" is no longer available in the selected job Price Book.',
          v_unit_code
        );
    end if;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_transfer_quantity,
      authorized_retirement_quantity, created_by
    ) values (
      v_company_id, p_package_id, v_work_point_id, v_item_id, v_canonical_code,
      v_install, v_transfer, v_retirement, auth.uid()
    )
    on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_transfer_quantity = excluded.authorized_transfer_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

    v_imported := v_imported + 1;
  end loop;

  update public.jobs job
  set price_book_id = v_price_book_id
  where job.id = v_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'The job closed while its utility package was importing.';
  end if;

  update public.daily_reports report
  set price_book_id = v_price_book_id
  where report.company_id = v_company_id
    and report.job_id = v_job_id
    and report.price_book_id is null
    and lower(coalesce(report.status, 'draft')) = 'draft';

  update public.job_packages package
  set source_filename = nullif(btrim(coalesce(p_source_filename, '')), ''),
      updated_at = now()
  where package.id = p_package_id
    and package.company_id = v_company_id;

  -- This call enforces the shared status rules and fires the existing
  -- supersede_prior_job_package trigger in this transaction.
  v_package_status := public.set_job_package_status(p_package_id, 'active');

  return jsonb_build_object(
    'imported_rows', v_imported,
    'package_status', v_package_status,
    'status', v_package_status,
    'price_book_id', v_price_book_id
  );
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using
      errcode = '22023',
      message = 'One or more quantities are not valid numbers. Nothing was imported.';
end;
$$;


--
-- Name: import_price_book_items_atomic(uuid, jsonb, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.import_price_book_items_atomic(p_price_book_id uuid, p_rows jsonb, p_update_existing boolean DEFAULT false, p_source_filename text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_row jsonb;
  v_item_id uuid; v_code text; v_name text; v_description text;
  v_category text; v_uom text; v_install numeric;
  v_transfer numeric; v_retirement numeric;
  v_added integer := 0; v_updated integer := 0;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or v_active is not true
     or v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You do not have permission to import Price Book units.';
  end if;
  if v_role = 'superintendent'
     and not public.linecrew_has_capability('price_books') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have Price Books permission.';
  end if;

  perform 1 from public.price_books book
  where book.id = p_price_book_id and book.company_id = v_company_id
  for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;
  if jsonb_typeof(p_rows) <> 'array'
     or jsonb_array_length(p_rows) = 0
     or jsonb_array_length(p_rows) > 5000 then
    raise exception using errcode = '22023',
      message = 'Import between 1 and 5,000 completed pricing rows.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_rows) row_item
    group by lower(btrim(row_item->>'item_code'))
    having count(*) > 1
  ) then
    raise exception using errcode = '23505',
      message = 'The import contains duplicate Unit Codes. Nothing was saved.';
  end if;

  -- Validate every row before writing so any problem leaves the Price Book
  -- completely unchanged.
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_code := btrim(coalesce(v_row->>'item_code', ''));
    v_name := btrim(coalesce(v_row->>'item_name', ''));
    v_description := nullif(btrim(coalesce(v_row->>'description', '')), '');
    v_install := (v_row->>'install_price')::numeric;
    v_transfer := (v_row->>'transfer_price')::numeric;
    v_retirement := (v_row->>'retirement_price')::numeric;
    if v_code = '' or (v_name = '' and v_description is null) then
      raise exception using errcode = '22023',
        message = 'Every imported row needs a Unit Code and description.';
    end if;
    if v_install is null or v_transfer is null or v_retirement is null
       or v_install < 0 or v_transfer < 0 or v_retirement < 0 then
      raise exception using errcode = '22023',
        message = 'Unit prices cannot be negative.';
    end if;
    if not coalesce(p_update_existing, false) and exists (
      select 1 from public.price_book_items item
      where item.company_id = v_company_id
        and item.price_book_id = p_price_book_id
        and lower(btrim(item.item_code)) = lower(v_code)
    ) then
      raise exception using errcode = '23505',
        message = 'Unit Code ' || v_code ||
          ' already exists. Choose Update Existing Units and try again.';
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_code := btrim(v_row->>'item_code');
    v_name := btrim(coalesce(v_row->>'item_name', ''));
    v_description := nullif(btrim(coalesce(v_row->>'description', '')), '');
    v_category := nullif(btrim(coalesce(v_row->>'category', '')), '');
    v_uom := nullif(btrim(coalesce(v_row->>'unit_of_measure', '')), '');
    v_install := (v_row->>'install_price')::numeric;
    v_transfer := (v_row->>'transfer_price')::numeric;
    v_retirement := (v_row->>'retirement_price')::numeric;
    select item.id into v_item_id
    from public.price_book_items item
    where item.company_id = v_company_id
      and item.price_book_id = p_price_book_id
      and lower(btrim(item.item_code)) = lower(v_code)
    limit 1;
    if v_item_id is null then
      insert into public.price_book_items(
        company_id, price_book_id, item_code, item_name, description,
        category, unit_of_measure, install_price, transfer_price,
        retirement_price, active
      ) values (
        v_company_id, p_price_book_id, v_code,
        coalesce(nullif(v_name, ''), v_description), v_description,
        v_category, v_uom, v_install, v_transfer, v_retirement, true
      );
      v_added := v_added + 1;
    else
      update public.price_book_items
      set item_name = coalesce(nullif(v_name, ''), v_description),
          description = v_description, category = v_category,
          unit_of_measure = v_uom, install_price = v_install,
          transfer_price = v_transfer, retirement_price = v_retirement,
          updated_at = now()
      where id = v_item_id and company_id = v_company_id
        and price_book_id = p_price_book_id;
      v_updated := v_updated + 1;
    end if;
    v_item_id := null;
  end loop;

  update public.price_books
  set source_filename = coalesce(
        source_filename,
        nullif(btrim(coalesce(p_source_filename, '')), '')
      ),
      updated_at = now()
  where id = p_price_book_id and company_id = v_company_id;
  return jsonb_build_object(
    'added', v_added,
    'updated', v_updated,
    'total', v_added + v_updated
  );
exception when invalid_text_representation then
  raise exception using errcode = '22023',
    message = 'One or more prices are not valid numbers. Nothing was imported.';
end;
$$;


--
-- Name: is_current_user_in_storm_mode(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_current_user_in_storm_mode() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
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


--
-- Name: is_my_profile_suspended(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_my_profile_suspended() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and active is false
  );
$$;


--
-- Name: is_platform_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_platform_owner() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1
    from public.platform_owners po
    where po.user_id = auth.uid()
  );
$$;


--
-- Name: is_platform_support(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_platform_support() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.platform_support_users support_user
    where support_user.user_id = (select auth.uid())
      and support_user.active is true
  );
$$;


--
-- Name: join_company(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.join_company(company_code text, user_name text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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


--
-- Name: linecrew_admin_replace_company_owner(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  actor public.profiles%rowtype;
  current_owner public.profiles%rowtype;
  replacement public.profiles%rowtype;
  actor_company_id uuid;
  requested_former_role text := lower(btrim(coalesce(former_owner_role, '')));
begin
  if current_owner_id is null or replacement_admin_id is null then
    raise exception using
      errcode = '22004',
      message = 'Choose the current Owner and an active Admin to receive ownership.';
  end if;

  if current_owner_id = replacement_admin_id then
    raise exception using
      errcode = '22023',
      message = 'The replacement Owner must be a different active Admin.';
  end if;

  if requested_former_role not in ('foreman','gf','superintendent','admin') then
    raise exception using
      errcode = '22023',
      message = 'Choose Admin, Superintendent, General Foreman, or Foreman for the former Owner.';
  end if;

  if coalesce((select auth.jwt() ->> 'aal'), 'aal1') <> 'aal2' then
    raise exception using
      errcode = '42501',
      message = 'Complete authenticator verification before recovering company ownership.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(coalesce(actor.role, '')) <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin can use ownership recovery.';
  end if;

  actor_company_id := actor.company_id;

  -- Serialize all ownership and team-governance mutations for this company.
  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  -- Re-read the Admin after taking the governance lock so stale authority
  -- cannot be used if another request changed their role or access.
  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  if actor.id is null or actor.active is not true or lower(coalesce(actor.role, '')) <> 'admin' then
    raise exception using
      errcode = '40001',
      message = 'Your role or access changed while ownership recovery was starting. Refresh and try again.';
  end if;

  select *
  into current_owner
  from public.profiles
  where id = current_owner_id
    and company_id = actor_company_id
  for update;

  if current_owner.id is null or lower(coalesce(current_owner.role, '')) <> 'owner' then
    raise exception using
      errcode = '23514',
      message = 'The selected person is no longer the Owner of your company. Refresh and try again.';
  end if;

  select *
  into replacement
  from public.profiles
  where id = replacement_admin_id
    and company_id = actor_company_id
  for update;

  if replacement.id is null or replacement.active is not true or lower(coalesce(replacement.role, '')) <> 'admin' then
    raise exception using
      errcode = '23514',
      message = 'Ownership recovery requires an active Admin from your company.';
  end if;

  -- The company lock makes this temporary zero-Owner state invisible outside
  -- the transaction and avoids violating the non-deferrable unique index.
  update public.profiles
  set role = requested_former_role,
      role_permissions = '{}'::jsonb
  where id = current_owner.id
    and company_id = actor_company_id
    and lower(coalesce(role, '')) = 'owner';

  if not found then
    raise exception using
      errcode = '40001',
      message = 'Ownership changed during recovery. Refresh and try again.';
  end if;

  update public.profiles
  set role = 'owner',
      role_permissions = '{}'::jsonb
  where id = replacement.id
    and company_id = actor_company_id
    and active is true
    and lower(coalesce(role, '')) = 'admin';

  if not found then
    raise exception using
      errcode = '40001',
      message = 'The replacement Admin changed during recovery. Refresh and try again.';
  end if;

  if (
    select count(*)
    from public.profiles
    where company_id = actor_company_id
      and lower(coalesce(role, '')) = 'owner'
  ) <> 1 then
    raise exception using
      errcode = '23514',
      message = 'Ownership recovery did not leave exactly one company Owner.';
  end if;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'company_ownership_recovered_by_admin',
    'profiles',
    replacement.id,
    jsonb_build_object(
      'owner_user_id', current_owner.id,
      'owner_role', 'owner',
      'owner_active', current_owner.active,
      'replacement_user_id', replacement.id,
      'replacement_role', 'admin'
    ),
    jsonb_build_object(
      'owner_user_id', replacement.id,
      'owner_role', 'owner',
      'previous_owner_user_id', current_owner.id,
      'previous_owner_role', requested_former_role,
      'performed_by_admin_user_id', actor.id
    )
  );
end;
$$;


--
-- Name: FUNCTION linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text) IS 'MFA-protected company-scoped recovery that lets an active Admin atomically replace the current Owner and choose the former Owner role.';


--
-- Name: linecrew_can_manage_job_packages(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_can_manage_job_packages() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.active is true
      and (
        lower(coalesce(p.role,'')) in ('owner','admin','gf')
        or (
          lower(coalesce(p.role,'')) = 'superintendent'
          and public.linecrew_has_capability('job_packages')
        )
      )
  );
$$;


--
-- Name: linecrew_can_manage_jobs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_can_manage_jobs() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.active is true
      and (
        lower(coalesce(p.role,'')) in ('owner','admin','gf')
        or (
          lower(coalesce(p.role,'')) = 'superintendent'
          and public.linecrew_has_capability('jobs')
        )
      )
  );
$$;


--
-- Name: linecrew_can_manage_packet_unit_aliases(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_can_manage_packet_unit_aliases() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.profiles profile
    join public.companies company
      on company.id = profile.company_id
     and company.active is true
    where profile.id = auth.uid()
      and profile.active is true
      and lower(coalesce(profile.role, '')) in ('owner', 'admin')
  );
$$;


--
-- Name: linecrew_can_use_billing_exports_internal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_can_use_billing_exports_internal() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.active=true and (
      lower(coalesce(p.role,'')) in ('owner','admin') or
      (lower(coalesce(p.role,''))='superintendent' and
       public.linecrew_has_capability('reporting') and
       public.linecrew_has_capability('actual_pricing'))
    )
  );
$$;


--
-- Name: linecrew_claim_initial_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_claim_initial_owner() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  actor public.profiles%rowtype;
  actor_company_id uuid;
begin
  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Current active Admin access is required to claim the initial Owner role.';
  end if;

  actor_company_id := actor.company_id;

  -- Serialize every ownership mutation for this company. The unique index is
  -- the final defense, but this lock also produces a clear second-claim error.
  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'admin' then
    raise exception using
      errcode = '40001',
      message = 'Your profile changed while ownership was being assigned. Refresh and try again.';
  end if;

  if exists (
    select 1
    from public.profiles
    where company_id = actor_company_id
      and lower(coalesce(role, '')) = 'owner'
  ) then
    raise exception using
      errcode = '23505',
      message = 'This company already has an Owner. The current Owner must transfer ownership.';
  end if;

  update public.profiles
  set role = 'owner'
  where id = actor.id
    and company_id = actor_company_id
    and active is true
    and lower(coalesce(role, '')) = 'admin';

  if not found then
    raise exception using
      errcode = '40001',
      message = 'Your profile changed while ownership was being assigned. Refresh and try again.';
  end if;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'initial_owner_claimed',
    'profiles',
    actor.id,
    jsonb_build_object('role', 'admin'),
    jsonb_build_object('role', 'owner')
  );
end;
$$;


--
-- Name: FUNCTION linecrew_claim_initial_owner(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.linecrew_claim_initial_owner() IS 'Allows one active Admin to claim Owner only when the company has no Owner.';


--
-- Name: linecrew_foreman_has_job_assignment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_foreman_has_job_assignment(p_job_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select exists (
    select 1
    from public.profiles profile
    join public.job_leader_assignments assignment
      on assignment.member_id = profile.id
     and assignment.company_id = profile.company_id
    join public.jobs job
      on job.id = assignment.job_id
     and job.company_id = assignment.company_id
    where profile.id = auth.uid()
      and profile.active is true
      and lower(coalesce(profile.role, '')) = 'foreman'
      and assignment.job_id = p_job_id
  );
$$;


--
-- Name: linecrew_has_capability(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_has_capability(capability text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select case
    when capability is null or not (capability = any(array[
      'company_settings','team_management','role_management',
      'customers_contracts','price_books','jobs','job_packages',
      'production_review','reporting','storm_mode','safety_records',
      'actual_pricing','field_pricing','exports','ai_assistant'
    ]::text[])) then false
    else coalesce((
      select case
        when lower(profile.role) in ('owner','admin') then true
        when capability = 'actual_pricing' and
             lower(profile.role) in ('foreman','gf','superintendent') then
          coalesce(
            (profile.role_permissions ->> capability)::boolean,
            lower(profile.role) <> 'foreman'
          )
        when capability = 'field_pricing' and
             lower(profile.role) in ('foreman','gf','superintendent') then
          coalesce((profile.role_permissions ->> capability)::boolean, true)
        when lower(profile.role) = 'superintendent' then
          coalesce((profile.role_permissions ->> capability)::boolean, true)
        else false
      end
      from public.profiles profile
      where profile.id = auth.uid()
        and profile.active is true
    ), false)
  end;
$$;


--
-- Name: linecrew_mfa_bootstrap_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_mfa_bootstrap_identity() RETURNS TABLE(user_role text, is_support boolean, requires_mfa boolean, enforcement_active boolean, current_aal text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with identity as (
    select
      lower(coalesce(profile.role, '')) as user_role,
      exists (
        select 1
        from public.platform_support_users support_user
        where support_user.user_id = (select auth.uid())
          and support_user.active is true
      ) as is_support
    from (select 1) seed
    left join public.profiles profile
      on profile.id = (select auth.uid())
     and profile.active is true
    where (select auth.uid()) is not null
  )
  select
    identity.user_role,
    identity.is_support,
    identity.is_support or identity.user_role in ('owner', 'admin'),
    identity.is_support or identity.user_role in ('owner', 'admin'),
    coalesce((select auth.jwt() ->> 'aal'), 'aal1')
  from identity;
$$;


--
-- Name: linecrew_packet_unit_aliases_for_import(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_packet_unit_aliases_for_import(p_import_id uuid) RETURNS TABLE(packet_code text, normalized_code text, target_item_code text, target_exists boolean, updated_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select alias.packet_code,
    alias.normalized_code,
    alias.target_item_code,
    exists (
      select 1
      from public.price_book_items item
      where item.price_book_id = public.linecrew_resolve_job_price_book(
              packet_import.company_id, package.job_id, package.contract_id
            )
        and item.company_id = packet_import.company_id
        and item.active is true
        and regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g')
            = alias.normalized_target
    ),
    alias.updated_at
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.utility_packet_unit_aliases alias
    on alias.company_id = packet_import.company_id
   and alias.contract_id = package.contract_id
  where packet_import.id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by alias.packet_code;
$$;


--
-- Name: linecrew_price_book_units_for_import(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_price_book_units_for_import(p_import_id uuid) RETURNS TABLE(item_code text, item_name text, description text, install_price numeric, transfer_price numeric, retirement_price numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select item.item_code,
    item.item_name,
    item.description,
    item.install_price,
    item.transfer_price,
    item.retirement_price
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  join public.price_book_items item
    on item.price_book_id = public.linecrew_resolve_job_price_book(
         packet_import.company_id, package.job_id, package.contract_id
       )
   and item.company_id = packet_import.company_id
   and item.active is true
  where packet_import.id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by item.item_code;
$$;


--
-- Name: linecrew_privileged_mfa_satisfied(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_privileged_mfa_satisfied() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select case
    when (select auth.uid()) is null then true
    when exists (
      select 1
      from public.platform_support_users support_user
      where support_user.user_id = (select auth.uid())
        and support_user.active is true
    ) then coalesce((select auth.jwt() ->> 'aal'), 'aal1') = 'aal2'
    when exists (
      select 1
      from public.profiles profile
      where profile.id = (select auth.uid())
        and profile.active is true
        and lower(coalesce(profile.role, '')) in ('owner', 'admin')
    ) then coalesce((select auth.jwt() ->> 'aal'), 'aal1') = 'aal2'
    else true
  end;
$$;


--
-- Name: linecrew_report_counts_toward_progress(text, timestamp with time zone, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_report_counts_toward_progress(p_status text, p_reviewed_at timestamp with time zone, p_review_notes text, p_archived boolean) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path TO ''
    AS $$
  select coalesce(p_archived, false) is false
    and (
      lower(coalesce(p_status, 'draft')) in ('submitted', 'approved')
      or (
        lower(coalesce(p_status, 'draft')) = 'draft'
        and p_reviewed_at is null
        and nullif(btrim(coalesce(p_review_notes, '')), '') is null
      )
    );
$$;


--
-- Name: linecrew_resolve_job_price_book(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_resolve_job_price_book(p_company_id uuid, p_job_id uuid, p_contract_id uuid) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select case
    when job.price_book_id is not null then (
      select book.id
      from public.price_books book
      where book.id = job.price_book_id
        and book.company_id = p_company_id
        and book.contract_id = p_contract_id
        and book.active is true
    )
    else (
      select book.id
      from public.price_books book
      where book.company_id = p_company_id
        and book.contract_id = p_contract_id
        and book.active is true
      order by book.effective_start desc nulls last,
        book.updated_at desc nulls last,
        book.created_at desc,
        book.id desc
      limit 1
    )
  end
  from public.jobs job
  where job.id = p_job_id
    and job.company_id = p_company_id
    and job.contract_id = p_contract_id
    and job.active is true;
$$;


--
-- Name: linecrew_set_member_money_permissions(uuid, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_set_member_money_permissions(target_user_id uuid, can_see_actual boolean, can_see_field boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_actor_company_id uuid;
  v_actor_role text;
  v_actor_active boolean;
  v_target_role text;
  v_updated integer;
begin
  if target_user_id is null or can_see_actual is null or can_see_field is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and both money visibility choices are required.';
  end if;

  select profile.company_id, lower(coalesce(profile.role,'')), profile.active
  into v_actor_company_id, v_actor_role, v_actor_active
  from public.profiles profile
  where profile.id = auth.uid()
  for update;

  if v_actor_company_id is null or v_actor_active is not true or
     v_actor_role not in ('owner','admin') then
    raise exception using
      errcode = '42501',
      message = 'Active Owner or Admin access is required.';
  end if;

  select lower(coalesce(profile.role,''))
  into v_target_role
  from public.profiles profile
  where profile.id = target_user_id
    and profile.company_id = v_actor_company_id
  for update;

  if v_target_role is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;
  if v_target_role not in ('foreman','gf','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Money visibility can be changed only for Foremen, General Foremen and Superintendents.';
  end if;

  update public.profiles profile
  set role_permissions = coalesce(profile.role_permissions, '{}'::jsonb) ||
    jsonb_build_object(
      'actual_pricing', can_see_actual,
      'field_pricing', can_see_field
    )
  where profile.id = target_user_id
    and profile.company_id = v_actor_company_id;
  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception using
      errcode = '40001',
      message = 'Money visibility was not saved. Refresh Team and try again.';
  end if;
end;
$$;


--
-- Name: linecrew_set_member_role(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_set_member_role(target_user_id uuid, new_role text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
  actor_role text;
  target_role text;
  requested_role text := lower(btrim(coalesce(new_role, '')));
begin
  if target_user_id is null or
     requested_role not in ('foreman','gf','superintendent','admin') then
    raise exception using
      errcode = '22023',
      message = 'Choose Foreman, General Foreman, Superintendent, or Admin. Owner changes use the ownership controls.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Active company role-management access is required.';
  end if;

  actor_company_id := actor.company_id;

  if actor_role = 'superintendent' and
     coalesce((actor.role_permissions ->> 'role_management')::boolean, true) is not true then
    raise exception using
      errcode = '42501',
      message = 'Role management is disabled for this Superintendent.';
  end if;

  if target_user_id = actor.id then
    raise exception using
      errcode = '42501',
      message = 'You cannot change your own role. Use the initial Owner claim or ownership-transfer control when applicable.';
  end if;

  -- Keep role and ownership changes ordered per company and make the target's
  -- authorization state stable until this transaction commits.
  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '40001',
      message = 'Your role or access changed while the role update was starting. Refresh and try again.';
  end if;

  if actor_role = 'superintendent' and
     coalesce((actor.role_permissions ->> 'role_management')::boolean, true) is not true then
    raise exception using
      errcode = '42501',
      message = 'Role management is disabled for this Superintendent.';
  end if;

  select *
  into target
  from public.profiles
  where id = target_user_id
    and company_id = actor_company_id
  for update;

  if target.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  target_role := lower(coalesce(target.role, ''));

  if target_role = 'owner' then
    raise exception using
      errcode = '42501',
      message = 'Owner changes require the ownership-transfer control.';
  end if;

  if target.active is not true then
    raise exception using
      errcode = '23514',
      message = 'Restore this team member''s access before changing their role.';
  end if;

  if actor_role = 'admin' then
    if target_role = 'admin' then
      raise exception using
        errcode = '42501',
        message = 'Only the Owner can change an existing Admin. Admins may promote a Foreman, General Foreman, or Superintendent to Admin.';
    end if;
  end if;

  if actor_role = 'superintendent' then
    if target_role not in ('foreman','gf') or requested_role not in ('foreman','gf') then
      raise exception using
        errcode = '42501',
        message = 'A Superintendent can manage General Foreman and Foreman roles only.';
    end if;
  end if;

  if target_role = requested_role then
    return;
  end if;

  update public.profiles
  set role = requested_role,
      role_permissions = case
        when requested_role = 'superintendent' then role_permissions
        else '{}'::jsonb
      end
  where id = target.id
    and company_id = actor_company_id;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'team_member_role_changed',
    'profiles',
    target.id,
    jsonb_build_object(
      'role', target_role,
      'role_permissions', target.role_permissions
    ),
    jsonb_build_object(
      'role', requested_role,
      'role_permissions', case
        when requested_role = 'superintendent' then target.role_permissions
        else '{}'::jsonb
      end
    )
  );
end;
$$;


--
-- Name: FUNCTION linecrew_set_member_role(target_user_id uuid, new_role text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.linecrew_set_member_role(target_user_id uuid, new_role text) IS 'Company-scoped role management. Admin may promote lower roles to Admin but cannot alter an existing Admin or any Owner.';


--
-- Name: linecrew_set_packet_unit_alias(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_price_book_id uuid;
  v_normalized_code text;
  v_normalized_target text;
  v_resolved_code text;
  v_existing public.utility_packet_unit_aliases%rowtype;
  v_removing boolean;
begin
  if not public.linecrew_can_manage_packet_unit_aliases() then
    raise exception using
      errcode = '42501',
      message = 'Only an Owner or Admin can map a packet unit to the Price Book.';
  end if;

  select packet_import.company_id, package.contract_id
  into v_company_id, v_contract_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review';

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found or is no longer editable.';
  end if;

  v_normalized_code := regexp_replace(
    upper(btrim(coalesce(p_packet_code, ''))), '[^A-Z0-9]', '', 'g'
  );
  if nullif(v_normalized_code, '') is null then
    raise exception using
      errcode = '22023',
      message = 'A packet unit code is required.';
  end if;

  v_removing := nullif(btrim(coalesce(p_target_item_code, '')), '') is null;
  v_normalized_target := regexp_replace(
    upper(btrim(coalesce(p_target_item_code, ''))), '[^A-Z0-9]', '', 'g'
  );

  select alias.* into v_existing
  from public.utility_packet_unit_aliases alias
  where alias.company_id = v_company_id
    and alias.contract_id = v_contract_id
    and alias.normalized_code = v_normalized_code
  for update;

  if v_removing then
    if v_existing.id is null then
      return jsonb_build_object('mapped', false, 'removed', false);
    end if;
    delete from public.utility_packet_unit_aliases alias
    where alias.id = v_existing.id;

    insert into public.audit_log (
      company_id, user_id, action, table_name, record_id, old_data, new_data
    ) values (
      v_company_id, auth.uid(), 'packet_unit_alias_removed',
      'utility_packet_unit_aliases', v_existing.id,
      jsonb_build_object(
        'packet_code', v_existing.packet_code,
        'target_item_code', v_existing.target_item_code,
        'contract_id', v_contract_id
      ),
      null
    );
    return jsonb_build_object('mapped', false, 'removed', true);
  end if;

  if nullif(v_normalized_target, '') is null then
    raise exception using
      errcode = '22023',
      message = 'The Price Book unit code is not a usable code.';
  end if;

  -- A mapping that points at nothing would fail silently at import time, so the
  -- target is verified against the book this import actually resolves to, and
  -- the stored code is the book's own spelling rather than whatever was typed.
  select package.contract_id,
    public.linecrew_resolve_job_price_book(
      packet_import.company_id, package.job_id, package.contract_id
    )
  into v_contract_id, v_price_book_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  where packet_import.id = p_import_id;

  select item.item_code into v_resolved_code
  from public.price_book_items item
  where item.price_book_id = v_price_book_id
    and item.company_id = v_company_id
    and item.active is true
    and regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g')
        = v_normalized_target
  order by item.updated_at desc nulls last, item.id desc
  limit 1;

  if v_resolved_code is null then
    raise exception using
      errcode = 'P0002',
      message = 'That unit is not in the Price Book for this job contract.';
  end if;

  -- Mapping a code to itself would be a no-op that hides a real mismatch.
  if v_normalized_code = v_normalized_target then
    raise exception using
      errcode = '22023',
      message = 'A packet unit cannot be mapped to itself.';
  end if;

  insert into public.utility_packet_unit_aliases as alias (
    company_id, contract_id, packet_code, normalized_code,
    target_item_code, normalized_target, created_by, updated_by
  ) values (
    v_company_id, v_contract_id, btrim(p_packet_code), v_normalized_code,
    v_resolved_code, v_normalized_target, auth.uid(), auth.uid()
  )
  on conflict (company_id, contract_id, normalized_code) do update
  set packet_code = excluded.packet_code,
    target_item_code = excluded.target_item_code,
    normalized_target = excluded.normalized_target,
    updated_by = auth.uid(),
    updated_at = now();

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    v_company_id, auth.uid(), 'packet_unit_alias_set',
    'utility_packet_unit_aliases',
    (select alias.id from public.utility_packet_unit_aliases alias
      where alias.company_id = v_company_id
        and alias.contract_id = v_contract_id
        and alias.normalized_code = v_normalized_code),
    case when v_existing.id is null then null
      else jsonb_build_object('target_item_code', v_existing.target_item_code) end,
    jsonb_build_object(
      'packet_code', btrim(p_packet_code),
      'target_item_code', v_resolved_code,
      'contract_id', v_contract_id
    )
  );

  return jsonb_build_object(
    'mapped', true,
    'removed', false,
    'packet_code', btrim(p_packet_code),
    'target_item_code', v_resolved_code
  );
end;
$$;


--
-- Name: FUNCTION linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text) IS 'Maps a packet unit code to a Price Book unit for the import''s contract, or removes the mapping when the target is blank. Owner/Admin only; every change is written to audit_log.';


--
-- Name: linecrew_set_superintendent_permissions(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_set_superintendent_permissions(target_user_id uuid, permissions jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  item record;
  allowed_keys text[] := array[
    'company_settings','team_management','role_management',
    'customers_contracts','price_books','jobs','job_packages',
    'production_review','reporting','storm_mode','safety_records',
    'exports','ai_assistant'
  ];
begin
  select * into actor
  from public.profiles profile
  where profile.id = auth.uid();
  if actor.id is null or actor.active is not true or
     lower(coalesce(actor.role,'')) not in ('owner','admin') then
    raise exception using errcode = '42501',
      message = 'Active Owner or Admin access is required.';
  end if;

  select * into target
  from public.profiles profile
  where profile.id = target_user_id
    and profile.company_id = actor.company_id
  for update;
  if target.id is null then
    raise exception using errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;
  if lower(coalesce(target.role,'')) <> 'superintendent' then
    raise exception using errcode = '42501',
      message = 'Operational permission overrides apply only to Superintendents.';
  end if;

  permissions := coalesce(permissions, '{}'::jsonb);
  if jsonb_typeof(permissions) <> 'object' then
    raise exception using errcode = '22023',
      message = 'Superintendent permissions must be a JSON object.';
  end if;
  for item in select key, value from jsonb_each(permissions)
  loop
    if not (item.key = any(allowed_keys)) then
      raise exception using errcode = '22023',
        message = format('Unsupported Superintendent capability: %s', item.key);
    end if;
    if jsonb_typeof(item.value) <> 'boolean' then
      raise exception using errcode = '22023',
        message = format('Superintendent capability %s must be true or false', item.key);
    end if;
  end loop;

  update public.profiles profile
  set role_permissions = permissions || jsonb_strip_nulls(jsonb_build_object(
    'actual_pricing', target.role_permissions -> 'actual_pricing',
    'field_pricing', target.role_permissions -> 'field_pricing'
  ))
  where profile.id = target.id
    and profile.company_id = actor.company_id;
end;
$$;


--
-- Name: linecrew_transfer_company_owner(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_transfer_company_owner(target_admin_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
begin
  if target_admin_id is null or target_admin_id = auth.uid() then
    raise exception using
      errcode = '22023',
      message = 'Choose another active Admin to receive ownership.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'owner' then
    raise exception using
      errcode = '42501',
      message = 'Only the current active Owner can transfer company ownership.';
  end if;

  actor_company_id := actor.company_id;

  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  -- Re-check the actor after taking the company governance lock.
  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'owner' then
    raise exception using
      errcode = '40001',
      message = 'Ownership changed while the transfer was starting. Refresh and try again.';
  end if;

  select *
  into target
  from public.profiles
  where id = target_admin_id
    and company_id = actor_company_id
  for update;

  if target.id is null or target.active is not true or lower(target.role) <> 'admin' then
    raise exception using
      errcode = '23514',
      message = 'Ownership can be transferred only to another active Admin in your company.';
  end if;

  -- Temporarily having zero Owners is safe inside this atomic transaction and
  -- avoids violating the non-deferrable single-Owner unique index.
  update public.profiles
  set role = 'admin'
  where id = actor.id and company_id = actor_company_id;

  update public.profiles
  set role = 'owner'
  where id = target.id and company_id = actor_company_id;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'company_ownership_transferred',
    'profiles',
    target.id,
    jsonb_build_object(
      'owner_user_id', actor.id,
      'owner_role', 'owner',
      'target_user_id', target.id,
      'target_role', 'admin'
    ),
    jsonb_build_object(
      'owner_user_id', target.id,
      'owner_role', 'owner',
      'previous_owner_user_id', actor.id,
      'previous_owner_role', 'admin'
    )
  );
end;
$$;


--
-- Name: FUNCTION linecrew_transfer_company_owner(target_admin_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.linecrew_transfer_company_owner(target_admin_id uuid) IS 'Atomically transfers the company''s single Owner role to another active Admin.';


--
-- Name: linecrew_utility_packet_import_matches(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_utility_packet_import_matches(p_import_id uuid) RETURNS TABLE(row_id uuid, price_book_item_id uuid, canonical_unit_code text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with context as materialized (
    select packet_import.company_id,
      package.contract_id,
      package.job_id,
      public.linecrew_resolve_job_price_book(
        packet_import.company_id,
        package.job_id,
        package.contract_id
      ) price_book_id
    from public.utility_packet_imports packet_import
    join public.job_packages package
      on package.id = packet_import.job_package_id
     and package.company_id = packet_import.company_id
     and package.status in ('draft', 'active')
    join public.jobs job
      on job.id = package.job_id
     and job.company_id = package.company_id
     and job.contract_id = package.contract_id
     and job.active is true
    join public.contracts contract
      on contract.id = package.contract_id
     and contract.company_id = package.company_id
     and contract.active is true
    join public.profiles profile
      on profile.id = auth.uid()
     and profile.company_id = packet_import.company_id
     and profile.active is true
    join public.companies company
      on company.id = profile.company_id
     and company.active is true
    where packet_import.id = p_import_id
      and packet_import.status = 'review'
      and public.linecrew_can_manage_job_packages()
  ), source_rows as materialized (
    select row_item.id row_id,
      regexp_replace(
        upper(btrim(row_item.contractor_unit_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) base_code,
      case lower(btrim(coalesce(row_item.work_type, '')))
        when 'install' then 'I'
        when 'transfer' then 'T'
        when 'remove' then 'R'
        else ''
      end work_suffix
    from public.utility_packet_import_rows row_item
    join context
      on context.company_id = row_item.company_id
    where row_item.import_id = p_import_id
      and nullif(btrim(coalesce(row_item.contractor_unit_code, '')), '')
          is not null
      and nullif(
        regexp_replace(
          upper(btrim(row_item.contractor_unit_code)),
          '[^A-Z0-9]',
          '',
          'g'
        ),
        ''
      ) is not null
  ), source_keys as materialized (
    select distinct source_row.base_code, source_row.work_suffix
    from source_rows source_row
  ), resolved_keys as materialized (
    select source_key.base_code,
      source_key.work_suffix,
      coalesce(alias.normalized_target, source_key.base_code) effective_code
    from source_keys source_key
    cross join context
    left join public.utility_packet_unit_aliases alias
      on alias.company_id = context.company_id
     and alias.contract_id = context.contract_id
     and alias.normalized_code = source_key.base_code
  ), candidates as materialized (
    select item.id,
      item.item_code,
      item.updated_at,
      regexp_replace(
        upper(btrim(item.item_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) normalized_item_code
    from context
    join public.price_book_items item
      on item.price_book_id = context.price_book_id
     and item.company_id = context.company_id
     and item.active is true
  ), alternate_counts as materialized (
    select resolved_key.base_code,
      resolved_key.work_suffix,
      count(distinct candidate.normalized_item_code) alternate_count
    from resolved_keys resolved_key
    join candidates candidate
      on length(candidate.normalized_item_code) =
         length(resolved_key.effective_code) + 1
     and left(
       candidate.normalized_item_code,
       length(resolved_key.effective_code)
     ) = resolved_key.effective_code
    group by resolved_key.base_code, resolved_key.work_suffix
  ), eligible as materialized (
    select resolved_key.base_code,
      resolved_key.work_suffix,
      candidate.id,
      candidate.item_code,
      candidate.updated_at,
      case
        when candidate.normalized_item_code = resolved_key.effective_code then 0
        when candidate.normalized_item_code =
          resolved_key.effective_code || resolved_key.work_suffix then 1
        else 2
      end match_rank
    from resolved_keys resolved_key
    join candidates candidate
      on candidate.normalized_item_code = resolved_key.effective_code
      or candidate.normalized_item_code =
         resolved_key.effective_code || resolved_key.work_suffix
      or (
        length(candidate.normalized_item_code) =
          length(resolved_key.effective_code) + 1
        and left(
          candidate.normalized_item_code,
          length(resolved_key.effective_code)
        ) = resolved_key.effective_code
      )
    left join alternate_counts alternate
      on alternate.base_code = resolved_key.base_code
     and alternate.work_suffix = resolved_key.work_suffix
    where candidate.normalized_item_code = resolved_key.effective_code
       or candidate.normalized_item_code =
          resolved_key.effective_code || resolved_key.work_suffix
       or coalesce(alternate.alternate_count, 0) = 1
  ), best_match as materialized (
    select distinct on (eligible.base_code, eligible.work_suffix)
      eligible.base_code,
      eligible.work_suffix,
      eligible.id,
      eligible.item_code
    from eligible
    order by eligible.base_code,
      eligible.work_suffix,
      eligible.match_rank,
      eligible.updated_at desc nulls last,
      eligible.id desc
  )
  select source_row.row_id,
    best_match.id,
    best_match.item_code
  from source_rows source_row
  left join best_match
    on best_match.base_code = source_row.base_code
   and best_match.work_suffix = source_row.work_suffix;
$$;


--
-- Name: FUNCTION linecrew_utility_packet_import_matches(p_import_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.linecrew_utility_packet_import_matches(p_import_id uuid) IS 'Matches staged packet rows to the job contract Price Book, consulting any Admin-created packet unit mappings for the contract before falling back to the direct and single-alternate code matches.';


--
-- Name: linecrew_validate_jsa_source(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_validate_jsa_source() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$ declare v_method text; begin select c.jsa_method into v_method from public.companies c where c.id=new.company_id; if new.jsa_source='digital' and v_method not in ('digital','both') then raise exception using errcode='42501',message='Digital JSAs are disabled in Company Settings.'; end if; if new.jsa_source='upload' and v_method not in ('upload','both') then raise exception using errcode='42501',message='Uploaded company JSAs are disabled in Company Settings.'; end if; return new; end; $$;


--
-- Name: linecrew_validate_profile_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.linecrew_validate_profile_role() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  key text;
begin
  new.role := lower(trim(new.role));
  if new.role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception 'Unsupported LineCrew Pro role: %', new.role;
  end if;

  new.role_permissions := coalesce(new.role_permissions, '{}'::jsonb);
  if jsonb_typeof(new.role_permissions) <> 'object' then
    raise exception 'Role permissions must be a JSON object';
  end if;

  foreach key in array array['actual_pricing','field_pricing']
  loop
    if new.role_permissions ? key and
       jsonb_typeof(new.role_permissions -> key) <> 'boolean' then
      raise exception 'Money visibility permission % must be true or false', key;
    end if;
  end loop;

  if new.role in ('foreman','gf') then
    new.role_permissions := jsonb_strip_nulls(jsonb_build_object(
      'actual_pricing', new.role_permissions -> 'actual_pricing',
      'field_pricing', new.role_permissions -> 'field_pricing'
    ));
  elsif new.role in ('admin','owner') then
    new.role_permissions := '{}'::jsonb;
  end if;

  return new;
end;
$$;


--
-- Name: my_company_billing_summary(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_company_billing_summary() RETURNS TABLE(plan_code text, monthly_price_cents integer, currency text, status text, access_enabled boolean, provider text, trial_ends_at timestamp with time zone, current_period_end timestamp with time zone, cancel_at_period_end boolean, stripe_customer_linked boolean, stripe_subscription_linked boolean, included_crew_limit integer, rolling_peak_billable_crews integer, rolling_overage_crew_days integer, crew_overage_status text, recommended_plan_code text, company_name text, contact_email text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), coalesce(p.active,true)
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or not v_active or v_role not in ('owner','admin') then
    raise exception 'Company Owner or Admin access required'
      using errcode = '42501';
  end if;

  return query
  select
    cs.plan_code,
    cs.monthly_price_cents,
    cs.currency,
    cs.status,
    case
      when cs.access_override is not null then cs.access_override
      else cs.access_enabled and (
        cs.status = 'active'
        or (cs.status = 'trialing' and cs.trial_ends_at is not null and cs.trial_ends_at > now())
        or (cs.status = 'past_due' and cs.past_due_since is not null and cs.past_due_since > now() - interval '7 days')
      )
    end,
    cs.provider,
    cs.trial_ends_at,
    cs.current_period_end,
    cs.cancel_at_period_end,
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null,
    cs.included_crew_limit,
    coalesce(cs.rolling_peak_billable_crews,0),
    coalesce(cs.rolling_overage_crew_days,0),
    coalesce(cs.crew_overage_status,'within_plan'),
    coalesce(cs.recommended_plan_code,cs.plan_code),
    c.name,
    c.contact_email
  from public.companies c
  join public.company_subscriptions cs on cs.company_id = c.id
  where c.id = v_company_id;
end;
$$;


--
-- Name: my_company_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_company_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select profile.company_id
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true
  limit 1;
$$;


--
-- Name: my_company_subscription_access(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_company_subscription_access() RETURNS TABLE(company_id uuid, plan_code text, status text, access_enabled boolean, trial_ends_at timestamp with time zone, current_period_end timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
begin
  select p.company_id into v_company_id
  from public.profiles p
  where p.id = auth.uid() and coalesce(p.active, true) = true;

  if v_company_id is null then return; end if;

  return query
  select
    cs.company_id,
    cs.plan_code,
    cs.status,
    case
      when cs.access_override is not null then cs.access_override
      else cs.access_enabled and (
        cs.status = 'active'
        or (cs.status = 'trialing' and cs.trial_ends_at is not null and cs.trial_ends_at > now())
        or (cs.status = 'past_due' and cs.past_due_since is not null and cs.past_due_since > now() - interval '7 days')
      )
    end,
    cs.trial_ends_at,
    cs.current_period_end
  from public.company_subscriptions cs
  where cs.company_id = v_company_id;
end;
$$;


--
-- Name: my_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select profile.role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true
  limit 1;
$$;


--
-- Name: normalize_work_point_key(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_work_point_key(p_value text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $_$
  with normalized as (
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
    ) as key
  )
  select case
    when key ~ '^[0-9]+$' then coalesce(nullif(ltrim(key, '0'), ''), '0')
    else key
  end
  from normalized;
$_$;


--
-- Name: plan_crew_limit(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.plan_crew_limit(p_plan_code text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case lower(coalesce(p_plan_code,''))
    when 'pilot' then 5
    when 'starter' then 5
    when 'business' then 10
    when 'pro' then 20
    when 'enterprise' then 40
    else null
  end;
$$;


--
-- Name: plan_monthly_cents(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.plan_monthly_cents(p_plan_code text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case lower(coalesce(p_plan_code,''))
    when 'starter' then 49900
    when 'business' then 74900
    when 'pro' then 119900
    when 'enterprise' then 179900
    else null
  end;
$$;


--
-- Name: platform_owner_beta_applications(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_owner_beta_applications() RETURNS TABLE(application_id uuid, company_name text, contact_name text, email text, phone text, active_crew_count integer, testing_notes text, status text, submitted_at timestamp with time zone, reviewed_at timestamp with time zone, approved_company_id uuid, invite_sent_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.is_platform_owner() then
    raise exception using errcode='42501', message='Platform owner access required.';
  end if;
  return query
  select b.id, b.company_name, b.contact_name, b.email, b.phone, b.active_crew_count,
         b.testing_notes, b.status, b.submitted_at, b.reviewed_at, b.approved_company_id, b.invite_sent_at
  from public.beta_applications b
  order by case b.status when 'pending' then 0 when 'approved' then 1 else 2 end, b.submitted_at desc;
end;
$$;


--
-- Name: platform_owner_company_dashboard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_owner_company_dashboard() RETURNS TABLE(company_id uuid, company_name text, contact_email text, company_created_at timestamp with time zone, active_users bigint, active_jobs bigint, total_reports bigint, last_report_at timestamp with time zone, active_crews bigint, plan_code text, monthly_price_cents integer, subscription_status text, access_enabled boolean, access_override boolean, trial_ends_at timestamp with time zone, current_period_end timestamp with time zone, cancel_at_period_end boolean, provider text, stripe_customer_linked boolean, stripe_subscription_linked boolean, included_crew_limit integer, rolling_peak_billable_crews integer, rolling_overage_crew_days integer, crew_overage_status text, recommended_plan_code text, internal_notes text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.is_platform_owner() then
    raise exception 'Platform owner access required';
  end if;

  return query
  select
    c.id,
    c.name,
    c.contact_email,
    c.created_at,
    (select count(*) from public.profiles p where p.company_id = c.id and coalesce(p.active,true)=true),
    (select count(*) from public.jobs j where j.company_id = c.id and coalesce(j.active,true)=true),
    (select count(*) from public.daily_reports dr where dr.company_id = c.id),
    (select max(dr.created_at) from public.daily_reports dr where dr.company_id = c.id),
    (select count(*) from public.crews cr where cr.company_id = c.id and coalesce(cr.active,true)=true),
    coalesce(cs.plan_code,'pilot'),
    coalesce(cs.monthly_price_cents,0),
    coalesce(cs.status,'trialing'),
    coalesce(cs.access_override,cs.access_enabled,true),
    cs.access_override,
    cs.trial_ends_at,
    cs.current_period_end,
    coalesce(cs.cancel_at_period_end,false),
    coalesce(cs.provider,'manual'),
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null,
    cs.included_crew_limit,
    coalesce(cs.rolling_peak_billable_crews,0),
    coalesce(cs.rolling_overage_crew_days,0),
    coalesce(cs.crew_overage_status,'within_plan'),
    coalesce(cs.recommended_plan_code,cs.plan_code,'pilot'),
    cs.notes
  from public.companies c
  left join public.company_subscriptions cs on cs.company_id = c.id
  order by lower(c.name),c.created_at;
end;
$$;


--
-- Name: platform_owner_decline_beta_application(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_owner_decline_beta_application(p_application_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare app public.beta_applications%rowtype;
begin
  if not public.is_platform_owner() then raise exception using errcode='42501', message='Platform owner access required.'; end if;
  select * into app from public.beta_applications where id=p_application_id for update;
  if app.id is null then raise exception using errcode='P0002', message='Beta application not found.'; end if;
  if app.status <> 'pending' then raise exception using errcode='23514', message='Beta application has already been reviewed.'; end if;
  update public.beta_applications b set status='declined', reviewed_at=now(), reviewed_by=auth.uid() where b.id=app.id;
  insert into public.platform_owner_audit_events(actor_user_id, company_id, action, before_state, after_state)
  values(auth.uid(), null, 'beta_application_declined', to_jsonb(app), jsonb_build_object('application_id',app.id,'status','declined'));
end; $$;


--
-- Name: platform_owner_mark_beta_invite_sent(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_owner_mark_beta_invite_sent(p_application_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$ begin
  if not public.is_platform_owner() then raise exception using errcode='42501', message='Platform owner access required.'; end if;
  update public.beta_applications b set invite_sent_at=now() where b.id=p_application_id and b.status='approved';
  if not found then raise exception using errcode='P0002', message='Approved beta application not found.'; end if;
end; $$;


--
-- Name: platform_owner_prepare_beta_company(uuid, text, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_owner_prepare_beta_company(p_application_id uuid, p_token_hash text, p_invite_expires_at timestamp with time zone, p_pilot_ends_at timestamp with time zone) RETURNS TABLE(company_id uuid, applicant_email text, applicant_name text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
  app public.beta_applications%rowtype;
  v_company_id uuid;
begin
  if not public.is_platform_owner() then
    raise exception using errcode='42501', message='Platform owner access required.';
  end if;
  if coalesce(p_token_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023', message='Invalid invitation token.';
  end if;
  if p_invite_expires_at <= now() + interval '15 minutes' or p_invite_expires_at > now() + interval '7 days' then
    raise exception using errcode='22023', message='Invalid invitation expiration.';
  end if;
  if p_pilot_ends_at <= now() + interval '7 days' or p_pilot_ends_at > now() + interval '180 days' then
    raise exception using errcode='22023', message='Invalid pilot expiration.';
  end if;

  select * into app from public.beta_applications where id=p_application_id for update;
  if app.id is null then raise exception using errcode='P0002', message='Beta application not found.'; end if;
  if app.status <> 'pending' then raise exception using errcode='23514', message='Beta application has already been reviewed.'; end if;
  if exists(select 1 from public.companies c where lower(coalesce(c.contact_email,''))=lower(app.email)) then
    raise exception using errcode='23505', message='A company already exists for this contact email.';
  end if;

  insert into public.companies(name, contact_email, contact_phone, active)
  values (btrim(app.company_name), lower(btrim(app.email)), nullif(btrim(coalesce(app.phone,'')),''), true)
  returning id into v_company_id;

  update public.company_subscriptions cs
  set plan_code='pilot', monthly_price_cents=0, currency='usd', status='trialing', access_enabled=true,
      access_override=null, trial_ends_at=p_pilot_ends_at, provider='manual', notes='Approved Beta/Pilot company', updated_at=now()
  where cs.company_id=v_company_id;

  if not found then
    insert into public.company_subscriptions(company_id, plan_code, monthly_price_cents, currency, status, access_enabled, access_override, trial_ends_at, provider, notes)
    values (v_company_id, 'pilot', 0, 'usd', 'trialing', true, null, p_pilot_ends_at, 'manual', 'Approved Beta/Pilot company');
  end if;

  insert into public.team_invitations(company_id, email, token_hash, invited_by, expires_at, intended_role, intended_full_name)
  values (v_company_id, lower(btrim(app.email)), lower(p_token_hash), null, p_invite_expires_at, 'admin', left(btrim(app.contact_name),120));

  update public.beta_applications b
  set status='approved', reviewed_at=now(), reviewed_by=auth.uid(), approved_company_id=v_company_id
  where b.id=app.id;

  insert into public.platform_owner_audit_events(actor_user_id, company_id, action, before_state, after_state)
  values(auth.uid(), v_company_id, 'beta_application_approved', to_jsonb(app), jsonb_build_object('application_id',app.id,'plan_code','pilot','pilot_ends_at',p_pilot_ends_at));

  return query select v_company_id, lower(btrim(app.email)), btrim(app.contact_name);
end;
$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: company_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    plan_code text DEFAULT 'pilot'::text NOT NULL,
    monthly_price_cents integer DEFAULT 0 NOT NULL,
    currency text DEFAULT 'usd'::text NOT NULL,
    status text DEFAULT 'trialing'::text NOT NULL,
    access_enabled boolean DEFAULT true NOT NULL,
    access_override boolean,
    trial_ends_at timestamp with time zone,
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    past_due_since timestamp with time zone,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    stripe_customer_id text,
    stripe_subscription_id text,
    stripe_price_id text,
    billing_interval text,
    billing_interval_count integer,
    provider text DEFAULT 'manual'::text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    included_crew_limit integer,
    rolling_overage_crew_days integer DEFAULT 0 NOT NULL,
    crew_overage_status text DEFAULT 'within_plan'::text NOT NULL,
    crew_overage_updated_at timestamp with time zone,
    rolling_peak_billable_crews integer DEFAULT 0 NOT NULL,
    recommended_plan_code text,
    last_stripe_event_created bigint DEFAULT 0 NOT NULL,
    CONSTRAINT company_subscriptions_billing_interval_check CHECK (((billing_interval IS NULL) OR (billing_interval = ANY (ARRAY['day'::text, 'week'::text, 'month'::text, 'year'::text])))),
    CONSTRAINT company_subscriptions_billing_interval_count_check CHECK (((billing_interval_count IS NULL) OR (billing_interval_count > 0))),
    CONSTRAINT company_subscriptions_crew_overage_status_check CHECK ((crew_overage_status = ANY (ARRAY['within_plan'::text, 'grace'::text, 'upgrade_required'::text, 'custom_quote_required'::text]))),
    CONSTRAINT company_subscriptions_monthly_price_cents_check CHECK ((monthly_price_cents >= 0)),
    CONSTRAINT company_subscriptions_provider_check CHECK ((provider = ANY (ARRAY['manual'::text, 'stripe'::text]))),
    CONSTRAINT company_subscriptions_status_check CHECK ((status = ANY (ARRAY['trialing'::text, 'active'::text, 'past_due'::text, 'paused'::text, 'canceled'::text, 'incomplete'::text])))
);


--
-- Name: platform_owner_set_subscription(uuid, text, integer, text, boolean, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_owner_set_subscription(p_company_id uuid, p_plan_code text, p_monthly_price_cents integer, p_status text, p_access_override boolean DEFAULT NULL::boolean, p_trial_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_notes text DEFAULT NULL::text) RETURNS public.company_subscriptions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  result public.company_subscriptions;
  v_before jsonb;
  v_provider text;
  v_stripe_subscription_id text;
  v_existing_status text;
  v_base_access boolean;
  v_plan text;
  v_effective_price integer;
begin
  if not public.is_platform_owner() then raise exception 'Platform owner access required'; end if;
  if p_monthly_price_cents < 0 then raise exception 'Monthly price cannot be negative'; end if;
  if p_status not in ('trialing','active','past_due','paused','canceled','incomplete') then raise exception 'Invalid subscription status'; end if;
  if not exists(select 1 from public.companies c where c.id=p_company_id) then raise exception 'Company not found'; end if;

  v_plan := lower(coalesce(nullif(trim(p_plan_code),''),'custom'));
  if v_plan not in ('pilot','starter','business','pro','enterprise','custom') then
    raise exception 'Invalid plan code';
  end if;
  v_effective_price := case
    when v_plan='pilot' then 0
    when v_plan='custom' then p_monthly_price_cents
    else public.plan_monthly_cents(v_plan)
  end;

  select to_jsonb(cs),cs.provider,cs.stripe_subscription_id,cs.status
  into v_before,v_provider,v_stripe_subscription_id,v_existing_status
  from public.company_subscriptions cs where cs.company_id=p_company_id;

  v_base_access := p_status in ('trialing','active','past_due');

  if v_provider='stripe' and v_stripe_subscription_id is not null and coalesce(v_existing_status,'')<>'canceled' then
    update public.company_subscriptions cs
    set access_override=p_access_override,notes=p_notes,updated_at=now()
    where cs.company_id=p_company_id returning cs.* into result;
  else
    insert into public.company_subscriptions(
      company_id,plan_code,monthly_price_cents,status,access_enabled,access_override,trial_ends_at,notes,provider,updated_at,included_crew_limit
    ) values (
      p_company_id,v_plan,v_effective_price,p_status,v_base_access,p_access_override,p_trial_ends_at,p_notes,'manual',now(),public.plan_crew_limit(v_plan)
    )
    on conflict(company_id) do update set
      plan_code=excluded.plan_code,
      monthly_price_cents=excluded.monthly_price_cents,
      status=excluded.status,
      access_enabled=excluded.access_enabled,
      access_override=excluded.access_override,
      trial_ends_at=excluded.trial_ends_at,
      notes=excluded.notes,
      provider='manual',
      included_crew_limit=excluded.included_crew_limit,
      updated_at=now()
    returning * into result;
  end if;

  perform public.recalculate_company_crew_overage(p_company_id);
  select * into result from public.company_subscriptions cs where cs.company_id=p_company_id;

  insert into public.platform_owner_audit_events(actor_user_id,company_id,action,before_state,after_state)
  values(auth.uid(),p_company_id,'subscription_settings_updated',v_before,to_jsonb(result));
  return result;
end;
$$;


--
-- Name: prevent_duplicate_daily_report(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_duplicate_daily_report() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if coalesce(new.archived, false) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      concat_ws('|', new.company_id::text, new.job_id::text,
        new.work_date::text, new.foreman_id::text),
      0
    )
  );

  if exists (
    select 1
    from public.daily_reports existing
    where existing.company_id = new.company_id
      and existing.job_id = new.job_id
      and existing.work_date = new.work_date
      and existing.foreman_id = new.foreman_id
      and coalesce(existing.archived, false) is false
      and existing.id is distinct from new.id
  ) then
    raise exception using errcode = '23505',
      message = 'A Daily Report already exists for this Foreman, job, and work date.';
  end if;

  return new;
end;
$$;


--
-- Name: prevent_non_draft_job_package_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_non_draft_job_package_delete() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if auth.uid() is null then
    return old;
  end if;

  if old.status is distinct from 'draft' then
    raise exception using
      errcode = '23514',
      message = 'Active and closed job-jacket revisions cannot be deleted.';
  end if;
  return old;
end;
$$;


--
-- Name: protect_daily_report_unit_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_daily_report_unit_history() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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


--
-- Name: recalculate_company_crew_overage(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalculate_company_crew_overage(p_company_id uuid) RETURNS TABLE(plan_code text, included_crews integer, rolling_overage_crew_days integer, overage_status text, recommended_plan text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_plan text;
  v_limit integer;
  v_overage integer;
  v_peak integer;
  v_status text;
  v_recommended text;
begin
  select lower(coalesce(subscription.plan_code,'pilot'))
  into v_plan
  from public.company_subscriptions subscription
  where subscription.company_id = p_company_id;

  if v_plan is null then
    raise exception 'Subscription not found';
  end if;

  v_limit := public.plan_crew_limit(v_plan);

  select
    coalesce(sum(greatest(usage.peak_billable_crews - coalesce(v_limit,0), 0)),0)::integer,
    coalesce(max(usage.peak_billable_crews),0)::integer
  into v_overage, v_peak
  from public.company_crew_usage_daily usage
  where usage.company_id = p_company_id
    and usage.usage_date >= current_date - 29;

  if v_plan = 'pilot' then
    v_status := 'within_plan';
    v_recommended := 'pilot';
    v_overage := 0;
  elsif v_plan = 'custom' then
    v_status := 'within_plan';
    v_recommended := 'custom';
    v_overage := 0;
  elsif v_limit is null then
    v_status := 'custom_quote_required';
    v_recommended := 'custom';
  elsif v_peak > 40 then
    v_status := 'custom_quote_required';
    v_recommended := 'custom';
  elsif v_overage = 0 then
    v_status := 'within_plan';
    v_recommended := v_plan;
  elsif v_overage <= 6 then
    v_status := 'grace';
    v_recommended := v_plan;
  else
    v_status := 'upgrade_required';
    v_recommended := public.recommended_crew_plan(v_peak);
  end if;

  update public.company_subscriptions subscription
  set included_crew_limit = v_limit,
      rolling_overage_crew_days = v_overage,
      rolling_peak_billable_crews = v_peak,
      crew_overage_status = v_status,
      recommended_plan_code = v_recommended,
      crew_overage_updated_at = now(),
      updated_at = now()
  where subscription.company_id = p_company_id;

  return query select v_plan, v_limit, v_overage, v_status, v_recommended;
end;
$$;


--
-- Name: recalculate_timekeeping_employee_week(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalculate_timekeeping_employee_week(p_report_id uuid, p_employee_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_foreman_id uuid;
  v_work_date date;
  v_week_start_day int;
  v_week_start date;
  v_week_end date;
  v_running numeric := 0;
  v_total numeric;
  v_regular numeric;
  v_overtime numeric;
  rec record;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true
     or v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode = '42501', message = 'An active company timekeeping role is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501', message = 'This Superintendent does not have production review permission.';
  end if;

  select r.company_id, r.foreman_id, r.work_date
  into v_report_company_id, v_report_foreman_id, v_work_date
  from public.daily_reports r where r.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002', message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_foreman_id is distinct from auth.uid() then
    raise exception using errcode = '42501', message = 'Foremen can recalculate time only on their own reports.';
  end if;

  if not exists (
    select 1 from public.timekeeping_employees e
    where e.id = p_employee_id and e.company_id = v_company_id and e.active is true
  ) then
    raise exception using errcode = 'P0002', message = 'Employee was not found in your company.';
  end if;

  select coalesce(c.week_start_day,1) into v_week_start_day
  from public.companies c where c.id = v_company_id;

  v_week_start := v_work_date - (((extract(dow from v_work_date)::int - v_week_start_day + 7) % 7));
  v_week_end := v_week_start + 6;

  for rec in
    select e.id, e.daily_report_id, e.work_date,
           (coalesce(e.regular_hours,0) + coalesce(e.overtime_hours,0)) as total_hours
    from public.timekeeping_entries e
    where e.company_id = v_company_id
      and e.employee_id = p_employee_id
      and e.work_date between v_week_start and v_week_end
    order by e.work_date, e.created_at, e.id
    for update
  loop
    v_total := greatest(0, least(24, coalesce(rec.total_hours,0)));
    v_regular := least(v_total, greatest(0, 40 - v_running));
    v_overtime := greatest(0, v_total - v_regular);

    update public.timekeeping_entries
    set regular_hours = v_regular,
        overtime_hours = v_overtime,
        updated_at = now()
    where id = rec.id;

    v_running := v_running + v_total;
  end loop;

  update public.daily_reports r
  set regular_hours = totals.regular_hours,
      overtime_hours = totals.overtime_hours,
      updated_at = now()
  from (
    select e.daily_report_id,
           coalesce(sum(e.regular_hours),0) as regular_hours,
           coalesce(sum(e.overtime_hours),0) as overtime_hours
    from public.timekeeping_entries e
    where e.company_id = v_company_id
      and e.work_date between v_week_start and v_week_end
      and e.daily_report_id is not null
    group by e.daily_report_id
  ) totals
  where r.id = totals.daily_report_id
    and r.company_id = v_company_id;
end;
$$;


--
-- Name: recommended_crew_plan(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recommended_crew_plan(p_peak_crews integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case
    when coalesce(p_peak_crews,0) <= 5 then 'starter'
    when p_peak_crews <= 10 then 'business'
    when p_peak_crews <= 20 then 'pro'
    when p_peak_crews <= 40 then 'enterprise'
    else 'custom'
  end;
$$;


--
-- Name: record_app_error(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_app_error(p_area text, p_error_code text, p_page text, p_message text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_safe text;
begin
  select p.company_id into v_company from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null then return; end if;
  v_safe:=left(coalesce(p_message,'Unexpected application error'),300);
  v_safe:=regexp_replace(v_safe,'https?://[^ ]+','[url]','gi');
  v_safe:=regexp_replace(v_safe,'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}','[email]','gi');
  v_safe:=regexp_replace(v_safe,'[0-9a-f]{8}-[0-9a-f-]{27,}','[id]','gi');
  v_safe:=regexp_replace(v_safe,'(sk|sb)_[A-Za-z0-9_-]{12,}','[secret]','gi');
  insert into public.app_error_events(company_id,user_id,area,error_code,page,safe_message)
  values(v_company,(select auth.uid()),left(coalesce(nullif(trim(p_area),''),'app'),60),
    left(coalesce(nullif(trim(p_error_code),''),'operation_failed'),80),
    left(coalesce(nullif(trim(p_page),''),'unknown'),100),v_safe);
end;
$$;


--
-- Name: record_daily_report_audit_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_daily_report_audit_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_event_type text;
  v_actor_name text;
  v_actor_role text;
  v_notes text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
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


--
-- Name: register_billing_export_attachment(uuid, text, text, text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_billing_export_attachment(p_batch_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_id uuid;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode='42501',message='Billing attachment access is required.';
  end if;
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  if not exists(select 1 from public.billing_export_batches b where b.id=p_batch_id and b.company_id=v_company) then
    raise exception using errcode='P0002',message='Billing batch was not found.';
  end if;
  if split_part(p_storage_path,'/',1)<>v_company::text or split_part(p_storage_path,'/',2)<>p_batch_id::text then
    raise exception using errcode='22023',message='Invalid attachment path.';
  end if;
  insert into public.billing_export_attachments(company_id,billing_batch_id,storage_path,
    original_filename,mime_type,file_size_bytes,caption,uploaded_by)
  values(v_company,p_batch_id,p_storage_path,btrim(p_original_filename),p_mime_type,
    greatest(coalesce(p_file_size_bytes,0),0),nullif(btrim(coalesce(p_caption,'')),''),auth.uid())
  returning id into v_id; return v_id;
end;
$$;


--
-- Name: daily_report_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_report_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    daily_report_id uuid NOT NULL,
    storage_path text NOT NULL,
    original_filename text NOT NULL,
    mime_type text,
    file_size_bytes bigint DEFAULT 0 NOT NULL,
    caption text,
    uploaded_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT daily_report_attachments_file_size_bytes_check CHECK (((file_size_bytes >= 0) AND (file_size_bytes <= 15728640)))
);


--
-- Name: register_daily_report_attachment(uuid, text, text, text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_daily_report_attachment(p_report_id uuid, p_storage_path text, p_original_filename text, p_mime_type text DEFAULT NULL::text, p_file_size_bytes bigint DEFAULT 0, p_caption text DEFAULT NULL::text) RETURNS public.daily_report_attachments
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: register_jsa_upload_attachment(uuid, text, text, text, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_jsa_upload_attachment(p_jsa_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_page_order integer DEFAULT 1) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_jsa_creator uuid;
  v_jsa_source text;
  v_id uuid;
begin
  select p.company_id into v_company_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;

  select j.created_by,j.jsa_source into v_jsa_creator,v_jsa_source
  from public.daily_report_jsas j
  where j.id=p_jsa_id and j.company_id=v_company_id;

  if v_jsa_creator is null or v_jsa_source <> 'upload' then
    raise exception using errcode='P0002', message='Uploaded JSA record was not found for your company.';
  end if;
  if v_jsa_creator <> (select auth.uid()) and not exists(
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.company_id=v_company_id and p.active is true
      and (
        lower(p.role) in ('owner','admin','gf')
        or (lower(p.role)='superintendent' and public.linecrew_has_capability('safety_records'))
      )
  ) then
    raise exception using errcode='42501', message='You cannot add files to this JSA.';
  end if;
  if p_mime_type not in ('application/pdf','image/jpeg','image/png','image/heic','image/heif')
     or p_file_size_bytes <= 0 or p_file_size_bytes > 15728640 then
    raise exception using errcode='22023', message='Upload a PDF or supported image no larger than 15 MB.';
  end if;
  if p_storage_path not like (v_company_id::text || '/' || p_jsa_id::text || '/%') then
    raise exception using errcode='42501', message='Invalid JSA storage path.';
  end if;

  insert into public.jsa_upload_attachments(
    company_id,jsa_id,storage_path,original_filename,mime_type,file_size_bytes,page_order,uploaded_by
  ) values (
    v_company_id,p_jsa_id,p_storage_path,p_original_filename,p_mime_type,p_file_size_bytes,
    greatest(coalesce(p_page_order,1),1),(select auth.uid())
  )
  on conflict (jsa_id,storage_path) do update set
    original_filename=excluded.original_filename,
    mime_type=excluded.mime_type,
    file_size_bytes=excluded.file_size_bytes,
    page_order=excluded.page_order
  returning id into v_id;

  return v_id;
end;
$$;


--
-- Name: remove_assistant_memory(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_assistant_memory(p_memory_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: resolve_utility_packet_price_item(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_utility_packet_price_item(p_import_id uuid, p_contractor_unit_code text, p_work_type text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with context as (
    select packet_import.company_id,
      package.contract_id,
      package.job_id,
      regexp_replace(
        upper(btrim(p_contractor_unit_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) base_code,
      case lower(btrim(coalesce(p_work_type, '')))
        when 'install' then 'I'
        when 'transfer' then 'T'
        when 'remove' then 'R'
        else ''
      end work_suffix
    from public.utility_packet_imports packet_import
    join public.job_packages package
      on package.id = packet_import.job_package_id
     and package.company_id = packet_import.company_id
     and package.status in ('draft', 'active')
    join public.jobs job
      on job.id = package.job_id
     and job.company_id = package.company_id
     and job.contract_id = package.contract_id
     and job.active is true
    join public.contracts contract
      on contract.id = package.contract_id
     and contract.company_id = package.company_id
     and contract.active is true
    join public.profiles profile
      on profile.id = auth.uid()
     and profile.company_id = packet_import.company_id
     and profile.active is true
    join public.companies company
      on company.id = profile.company_id
     and company.active is true
    where packet_import.id = p_import_id
      and nullif(btrim(coalesce(p_contractor_unit_code, '')), '') is not null
  ), selected_book as (
    select public.linecrew_resolve_job_price_book(
      context.company_id,
      context.job_id,
      context.contract_id
    ) id
    from context
  ), candidates as (
    select item.id,
      item.updated_at item_updated_at,
      regexp_replace(
        upper(btrim(item.item_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) normalized_item_code,
      context.base_code,
      context.work_suffix
    from context
    join selected_book
      on selected_book.id is not null
    join public.price_book_items item
      on item.price_book_id = selected_book.id
     and item.company_id = context.company_id
     and item.active is true
  ), eligible as (
    select candidate.*,
      case
        when candidate.normalized_item_code = candidate.base_code then 0
        when candidate.normalized_item_code =
          candidate.base_code || candidate.work_suffix then 1
        when length(candidate.normalized_item_code) =
             length(candidate.base_code) + 1
         and left(
           candidate.normalized_item_code,
           length(candidate.base_code)
         ) = candidate.base_code
         and 1 = (
           select count(distinct alternate.normalized_item_code)
           from candidates alternate
           where length(alternate.normalized_item_code) =
                 length(candidate.base_code) + 1
             and left(
               alternate.normalized_item_code,
               length(candidate.base_code)
             ) = candidate.base_code
         ) then 2
        else 99
      end match_rank
    from candidates candidate
  )
  select eligible.id
  from eligible
  where eligible.match_rank < 99
  order by eligible.match_rank,
    eligible.item_updated_at desc nulls last,
    eligible.id desc
  limit 1;
$$;


--
-- Name: return_daily_report(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.return_daily_report(p_report_id uuid, p_review_notes text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.can_review_daily_reports() then
    raise exception 'You do not have permission to return reports';
  end if;

  if nullif(trim(p_review_notes), '') is null then
    raise exception 'Review notes are required when returning a report';
  end if;

  update public.daily_reports
  set status = 'draft',
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      review_notes = trim(p_review_notes),
      approved_by = null,
      approved_at = null,
      updated_at = now()
  where id = p_report_id
    and company_id = public.my_company_id()
    and status in ('submitted', 'approved');

  if not found then
    raise exception 'Report not found or cannot be returned';
  end if;
end;
$$;


--
-- Name: FUNCTION return_daily_report(p_report_id uuid, p_review_notes text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.return_daily_report(p_report_id uuid, p_review_notes text) IS 'Returns a submitted or approved Daily Report to draft for correction, recording the reviewer and clearing any withdrawn approval. The audit trigger records a returned event with the actor and notes.';


--
-- Name: review_daily_report(uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.review_daily_report(p_report_id uuid, p_approved boolean, p_review_notes text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
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


--
-- Name: rotate_company_join_code(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rotate_company_join_code() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_new_code text;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null
     or v_profile_active is not true
     or v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only active company leadership can generate a new company code.';
  end if;

  if v_role = 'superintendent'
     and not public.linecrew_has_capability('team_management') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have team management permission.';
  end if;

  loop
    v_new_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
    exit when not exists (
      select 1
      from public.companies c
      where upper(btrim(c.join_code)) = v_new_code
    );
  end loop;

  update public.companies c
  set join_code = v_new_code
  where c.id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'Company was not found.';
  end if;

  return v_new_code;
end;
$$;


--
-- Name: save_billing_export_batch_details(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_billing_export_batch_details(p_batch_id uuid, p_utility_invoice_number text DEFAULT NULL::text, p_payment_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  update public.billing_export_batches set
    utility_invoice_number=nullif(btrim(coalesce(p_utility_invoice_number,'')),''),
    payment_reference=nullif(btrim(coalesce(p_payment_reference,'')),''),
    notes=nullif(btrim(coalesce(p_notes,'')),''),updated_at=now(),updated_by=auth.uid()
  where id=p_batch_id and company_id=v_company;
  if not found then raise exception using errcode='P0002',message='Billing batch was not found.'; end if;
end;
$$;


--
-- Name: save_daily_report_jsa(uuid, text, text, text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_daily_report_jsa(p_report_id uuid, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_special_equipment text DEFAULT NULL::text, p_foreman_acknowledged boolean DEFAULT false) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman','gf','admin', 'owner', 'superintendent') then
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


--
-- Name: save_daily_report_unit(uuid, uuid, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid, p_install_quantity numeric, p_retirement_quantity numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
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
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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


--
-- Name: save_daily_report_unit_location(uuid, uuid, text, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_retirement_quantity numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
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
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
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


--
-- Name: save_daily_report_unit_location_v2(uuid, uuid, text, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_daily_report_unit_location_v2(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_report_company_id uuid;
  v_report_creator uuid; v_report_status text; v_location text;
  v_total_install numeric; v_total_retirement numeric;
  v_aggregate_line_id uuid; v_location_line_id uuid;
begin
  v_location:=btrim(coalesce(p_pole_location,''));
  if v_location='' then raise exception using errcode='22023',message='Enter a pole or work location.'; end if;
  if coalesce(p_install_quantity,0)<0 or coalesce(p_transfer_quantity,0)<0 or
     coalesce(p_retirement_quantity,0)<0 or
     coalesce(p_install_quantity,0)+coalesce(p_transfer_quantity,0)+coalesce(p_retirement_quantity,0)=0 then
    raise exception using errcode='22023',message='Enter an installed, transferred or removed quantity greater than zero.';
  end if;
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501',message='An active Foreman, General Foreman or Admin profile is required.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501',message='This Superintendent does not have production review permission.';
  end if;
  select r.company_id,r.created_by,lower(coalesce(r.status,'draft'))
  into v_report_company_id,v_report_creator,v_report_status
  from public.daily_reports r where r.id=p_report_id;
  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002',message='Daily report was not found in your company.';
  end if;
  if v_report_status<>'draft' then raise exception using errcode='42501',message='Units can be changed only while the report is a draft.'; end if;
  if v_role='foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode='42501',message='Foremen can change units only on their own reports.';
  end if;

  select coalesce(sum(l.install_quantity+l.transfer_quantity),0)+
           coalesce(p_install_quantity,0)+coalesce(p_transfer_quantity,0),
         coalesce(sum(l.retirement_quantity),0)+coalesce(p_retirement_quantity,0)
  into v_total_install,v_total_retirement
  from public.daily_production_unit_locations l
  where l.daily_report_id=p_report_id and l.price_book_item_id=p_price_book_item_id
    and l.company_id=v_company_id and l.pole_location_key<>lower(v_location);

  v_aggregate_line_id:=public.save_daily_report_unit(
    p_report_id,p_price_book_item_id,v_total_install,v_total_retirement
  );
  insert into public.daily_production_unit_locations(
    company_id,daily_report_id,daily_production_unit_id,price_book_item_id,pole_location,
    install_quantity,transfer_quantity,retirement_quantity,created_by,updated_at
  ) values (
    v_company_id,p_report_id,v_aggregate_line_id,p_price_book_item_id,v_location,
    coalesce(p_install_quantity,0),coalesce(p_transfer_quantity,0),
    coalesce(p_retirement_quantity,0),auth.uid(),now()
  ) on conflict (daily_report_id,price_book_item_id,pole_location_key) do update set
    daily_production_unit_id=excluded.daily_production_unit_id,pole_location=excluded.pole_location,
    install_quantity=excluded.install_quantity,transfer_quantity=excluded.transfer_quantity,
    retirement_quantity=excluded.retirement_quantity,updated_at=now()
  returning id into v_location_line_id;
  return v_location_line_id;
end; $$;


--
-- Name: save_job_package_authorized_unit(uuid, text, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_job_package_authorized_unit(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_retirement_quantity numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
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


--
-- Name: save_job_package_authorized_unit_v2(uuid, text, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_job_package_authorized_unit_v2(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid; v_package_id uuid; v_contract_id uuid;
  v_item_id uuid; v_unit_code text; v_authorized_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'You do not have permission to add authorized units.';
  end if;
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid() and profile.active is true;
  if nullif(btrim(coalesce(p_unit_code, '')), '') is null
     or coalesce(p_install_quantity, 0) < 0
     or coalesce(p_transfer_quantity, 0) < 0
     or coalesce(p_retirement_quantity, 0) < 0
     or coalesce(p_install_quantity, 0)
      + coalesce(p_transfer_quantity, 0)
      + coalesce(p_retirement_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'Unit code and an authorized quantity greater than zero are required.';
  end if;

  select point.job_package_id, package.contract_id
  into v_package_id, v_contract_id
  from public.job_package_work_points point
  join public.job_packages package
    on package.id = point.job_package_id and package.company_id = point.company_id
  where point.id = p_work_point_id and point.company_id = v_company_id;
  if v_package_id is null then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;

  select item.id, item.item_code into v_item_id, v_unit_code
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id and book.company_id = item.company_id
  where item.company_id = v_company_id
    and book.contract_id = v_contract_id and book.active is true
    and item.active is true
    and lower(btrim(item.item_code)) = lower(btrim(p_unit_code))
  order by book.effective_start desc nulls last,
    book.updated_at desc nulls last limit 1;
  if v_item_id is null then
    raise exception using errcode = 'P0002',
      message = 'That unit code was not found in an active Price Book for this contract.';
  end if;

  insert into public.job_package_authorized_units(
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_transfer_quantity,
    authorized_retirement_quantity, created_by
  ) values (
    v_company_id, v_package_id, p_work_point_id, v_item_id, v_unit_code,
    coalesce(p_install_quantity, 0), coalesce(p_transfer_quantity, 0),
    coalesce(p_retirement_quantity, 0), auth.uid()
  ) on conflict (work_point_id, price_book_item_id) do update set
    authorized_install_quantity = excluded.authorized_install_quantity,
    authorized_transfer_quantity = excluded.authorized_transfer_quantity,
    authorized_retirement_quantity = excluded.authorized_retirement_quantity,
    unit_code = excluded.unit_code, updated_at = now()
  returning id into v_authorized_id;
  return v_authorized_id;
end;
$$;


--
-- Name: set_billing_export_batch_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_billing_export_batch_status(p_batch_id uuid, p_status text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company_id uuid; v_role text; v_active boolean; v_current text; v_next text;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  v_next:=lower(btrim(coalesce(p_status,'')));
  if v_next not in ('exported','submitted','paid','void') then
    raise exception using errcode='22023',message='Invalid billing batch status.';
  end if;
  select b.status into v_current from public.billing_export_batches b
    where b.id=p_batch_id and b.company_id=v_company_id for update;
  if v_current is null then
    raise exception using errcode='P0002',message='Billing batch was not found.';
  end if;
  if v_current='void' or v_current='paid' then
    raise exception using errcode='23514',message='A paid or void billing batch cannot be changed.';
  end if;
  if v_next='void' then
    update public.billing_export_lines set active=false
      where billing_batch_id=p_batch_id and company_id=v_company_id;
  end if;
  update public.billing_export_batches set
    status=v_next,
    exported_at=case when v_next='exported' then coalesce(exported_at,now()) else exported_at end,
    submitted_at=case when v_next='submitted' then coalesce(submitted_at,now()) else submitted_at end,
    paid_at=case when v_next='paid' then coalesce(paid_at,now()) else paid_at end,
    voided_at=case when v_next='void' then coalesce(voided_at,now()) else voided_at end
  where id=p_batch_id and company_id=v_company_id;
end;
$$;


--
-- Name: set_billing_export_batch_status_v2(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_billing_export_batch_status_v2(p_batch_id uuid, p_status text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company uuid; v_role text; v_active boolean; v_current text; v_next text;
  v_billing_type text; v_parent_batch_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;

  v_next:=lower(btrim(coalesce(p_status,'')));
  select status,billing_type,parent_batch_id
    into v_current,v_billing_type,v_parent_batch_id
  from public.billing_export_batches
  where id=p_batch_id and company_id=v_company for update;
  if v_current is null then raise exception using errcode='P0002',message='Billing batch was not found.'; end if;
  if v_current in ('paid','void') then raise exception using errcode='23514',message='Paid and void batches are locked.'; end if;
  if v_next not in ('exported','submitted','paid','void') then raise exception using errcode='22023',message='Invalid status.'; end if;
  if v_next='void' and v_current='submitted' and nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception using errcode='23514',message='A correction reason is required to void a submitted batch.';
  end if;

  if v_next='void' and v_billing_type='credit' then
    if v_role not in ('owner','admin') then
      raise exception using errcode='42501',message='Only Admin or Owner can void a billing adjustment.';
    end if;
    if v_parent_batch_id is null then
      raise exception using errcode='23514',message='This billing adjustment has no source batch.';
    end if;
    if exists(
      select 1
      from public.billing_export_lines source_line
      join public.billing_export_lines rebill
        on rebill.company_id=source_line.company_id
       and rebill.production_location_id=source_line.production_location_id
       and rebill.work_type=source_line.work_type
       and rebill.active
      where source_line.company_id=v_company
        and source_line.billing_batch_id=v_parent_batch_id
        and rebill.billing_batch_id<>v_parent_batch_id
    ) then
      raise exception using errcode='23514',message=
        'These units were rebilled after the adjustment. Void the newer billing batch before voiding this adjustment.';
    end if;

    update public.billing_export_lines
    set active=true
    where company_id=v_company and billing_batch_id=v_parent_batch_id;
  end if;

  if v_next='void' then
    update public.billing_export_lines set active=false
    where billing_batch_id=p_batch_id and company_id=v_company;
  end if;

  update public.billing_export_batches set status=v_next,
    correction_reason=case when v_next='void' then nullif(btrim(coalesce(p_reason,'')),'') else correction_reason end,
    exported_at=case when v_next='exported' then coalesce(exported_at,now()) else exported_at end,
    submitted_at=case when v_next='submitted' then coalesce(submitted_at,now()) else submitted_at end,
    paid_at=case when v_next='paid' then coalesce(paid_at,now()) else paid_at end,
    voided_at=case when v_next='void' then coalesce(voided_at,now()) else voided_at end,
    updated_at=now(),updated_by=auth.uid()
  where id=p_batch_id and company_id=v_company;
end;
$$;


--
-- Name: set_company_jsa_method(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_company_jsa_method(p_method text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$ declare v_company_id uuid; v_role text; v_method text:=lower(trim(coalesce(p_method,''))); begin select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role from public.profiles p where p.id=auth.uid() and p.active is true; if v_company_id is null or v_role not in ('owner','admin') then raise exception using errcode='42501',message='Only an active Owner or Admin can change the company JSA method.'; end if; if v_method not in ('digital','upload','both') then raise exception using errcode='22023',message='JSA method must be digital, upload, or both.'; end if; update public.companies set jsa_method=v_method where id=v_company_id; return v_method; end; $$;


--
-- Name: set_company_member_active(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_company_member_active(p_member_id uuid, p_active boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
  actor_role text;
  target_role text;
begin
  if p_member_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and access status are required.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Active company leadership access is required.';
  end if;

  actor_company_id := actor.company_id;

  if p_member_id = actor.id then
    raise exception using
      errcode = '42501',
      message = 'You cannot suspend your own account.';
  end if;

  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '40001',
      message = 'Your role or access changed while the access update was starting. Refresh and try again.';
  end if;

  if actor_role = 'superintendent' and
     coalesce((actor.role_permissions ->> 'team_management')::boolean, true) is not true then
    raise exception using
      errcode = '42501',
      message = 'Team access management is disabled for this Superintendent.';
  end if;

  select *
  into target
  from public.profiles
  where id = p_member_id
    and company_id = actor_company_id
  for update;

  if target.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  target_role := lower(coalesce(target.role, ''));

  if actor_role = 'admin' and target_role in ('owner','admin') then
    raise exception using
      errcode = '42501',
      message = 'Only an Owner can change Owner or Admin account access.';
  end if;

  if actor_role = 'superintendent' and target_role not in ('foreman','gf') then
    raise exception using
      errcode = '42501',
      message = 'A Superintendent can change access for General Foremen and Foremen only.';
  end if;

  if p_active is false and target_role = 'owner' then
    raise exception using
      errcode = '23514',
      message = 'Transfer ownership before suspending the company Owner.';
  end if;

  update public.profiles
  set active = p_active
  where id = target.id
    and company_id = actor_company_id;
end;
$$;


--
-- Name: FUNCTION set_company_member_active(p_member_id uuid, p_active boolean); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.set_company_member_active(p_member_id uuid, p_active boolean) IS 'Company-scoped team access management serialized with role and ownership changes.';


--
-- Name: set_company_member_role(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_company_member_role(p_member_id uuid, p_role text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$ begin perform public.linecrew_set_member_role(p_member_id,p_role); end; $$;


--
-- Name: set_company_redline_approval_requirement(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_company_redline_approval_requirement(p_required boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can change redline approval requirements.';
  end if;

  update public.companies company
  set require_gf_redline_approval = coalesce(p_required, false)
  where company.id = v_company_id;
end;
$$;


--
-- Name: set_company_storm_mode(boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_company_storm_mode(p_enabled boolean, p_event_name text DEFAULT NULL::text) RETURNS TABLE(storm_mode_enabled boolean, storm_event_name text, storm_started_at timestamp with time zone, storm_ended_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
 select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
 if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then raise exception using errcode='42501',message='An active company Admin, Owner, or permitted Superintendent is required.'; end if;
 if v_role='superintendent' and not public.linecrew_has_capability('storm_mode') then raise exception using errcode='42501',message='This Superintendent does not have storm mode permission.'; end if;
 if coalesce(p_enabled,false) and length(trim(coalesce(p_event_name,'')))=0 then raise exception using errcode='22023',message='A storm or event name is required when Storm Mode is enabled.'; end if;
 update public.companies c set storm_mode_enabled=coalesce(p_enabled,false),storm_event_name=case when coalesce(p_enabled,false) then trim(p_event_name) else null end,storm_started_at=case when coalesce(p_enabled,false) and not c.storm_mode_enabled then now() when coalesce(p_enabled,false) then c.storm_started_at else c.storm_started_at end,storm_ended_at=case when not coalesce(p_enabled,false) and c.storm_mode_enabled then now() when coalesce(p_enabled,false) then null else c.storm_ended_at end where c.id=v_company_id;
 return query select c.storm_mode_enabled,c.storm_event_name,c.storm_started_at,c.storm_ended_at from public.companies c where c.id=v_company_id;
end; $$;


--
-- Name: set_contract_field_value_percent(uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_contract_field_value_percent(p_contract_id uuid, p_field_value_percent numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('actual_pricing') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have actual pricing permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('actual_pricing') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have actual pricing permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('actual_pricing') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have actual pricing permission.';
  end if;
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
     v_role not in ('admin','owner','superintendent') or
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


--
-- Name: set_daily_production_transfer_price_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_daily_production_transfer_price_snapshot() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_transfer_price numeric;
begin
  select item.transfer_price
  into v_transfer_price
  from public.price_book_items item
  where item.id = new.price_book_item_id
    and item.company_id = new.company_id
    and item.price_book_id = new.price_book_id;

  if v_transfer_price is null then
    raise exception using
      errcode = 'P0002',
      message = 'Transfer pricing was not found for this unit.';
  end if;

  new.actual_transfer_price := v_transfer_price;
  new.adjusted_transfer_price := round(
    v_transfer_price * coalesce(new.field_value_percent_snapshot, 100) / 100,
    2
  );
  return new;
end;
$$;


--
-- Name: set_daily_report_archived(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_daily_report_archived(p_report_id uuid, p_archived boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
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


--
-- Name: set_daily_report_context(uuid, text, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_daily_report_context(p_report_id uuid, p_weather_conditions text, p_delay_hours numeric, p_delay_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_delay_hours numeric := coalesce(p_delay_hours, 0);
  v_delay_reason text := nullif(btrim(coalesce(p_delay_reason, '')), '');
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
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
      or v_role in ('admin', 'gf', 'owner', 'superintendent')
    );

  if not found then
    raise exception using errcode = '42501',
      message = 'Only the report creator, an Admin or a General Foreman can update a draft report in their company.';
  end if;
end;
$$;


--
-- Name: set_daily_report_date(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_daily_report_date() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.report_date is null then
    new.report_date := new.work_date;
  end if;

  return new;
end;
$$;


--
-- Name: set_daily_report_storm_context(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_daily_report_storm_context(p_report_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_report_created_by uuid;
  v_enabled boolean;
  v_event_name text;
  v_assigned boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('foreman','gf','admin', 'owner', 'superintendent') then
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


--
-- Name: set_gf_crew_assignment(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_gf_crew_assignment(p_foreman_id uuid, p_gf_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_foreman_ok boolean;
  v_gf_ok boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner') then
    raise exception using errcode='42501', message='Only an Owner or Admin can assign Foreman crews to General Foremen.';
  end if;

  select exists(
    select 1 from public.profiles p
    where p.id = p_foreman_id
      and p.company_id = v_company_id
      and p.active is true
      and lower(coalesce(p.role,'')) = 'foreman'
  ) into v_foreman_ok;

  if not v_foreman_ok then
    raise exception using errcode='22023', message='The selected Foreman is not an active Foreman in your company.';
  end if;

  if p_gf_id is null then
    delete from public.gf_foreman_assignments a
    where a.company_id = v_company_id and a.foreman_id = p_foreman_id;
    return;
  end if;

  select exists(
    select 1 from public.profiles p
    where p.id = p_gf_id
      and p.company_id = v_company_id
      and p.active is true
      and lower(coalesce(p.role,'')) = 'gf'
  ) into v_gf_ok;

  if not v_gf_ok then
    raise exception using errcode='22023', message='The selected General Foreman is not active in your company.';
  end if;

  insert into public.gf_foreman_assignments(company_id,gf_id,foreman_id,created_by,updated_at)
  values(v_company_id,p_gf_id,p_foreman_id,auth.uid(),now())
  on conflict (company_id,foreman_id)
  do update set gf_id=excluded.gf_id, updated_at=now();
end;
$$;


--
-- Name: set_job_closeout(uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_job_closeout(p_job_id uuid, p_close boolean, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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


--
-- Name: set_job_leader_assignment(uuid, uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_job_leader_assignment(p_job_id uuid, p_member_id uuid, p_assigned boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_member_role text;
  v_member_name text;
  v_actor_name text;
  v_job_number text;
  v_changed boolean := false;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active,
         coalesce(nullif(trim(profile.full_name), ''), 'Unknown Team Member')
  into v_company_id, v_role, v_active, v_actor_name
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to change job assignments.';
  end if;

  select job.job_number
  into v_job_number
  from public.jobs job
  where job.id = p_job_id
    and job.company_id = v_company_id;

  if v_job_number is null then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select lower(coalesce(profile.role, 'foreman')),
         coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')
  into v_member_role, v_member_name
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
      company_id, job_id, member_id, assigned_by, created_at
    ) values (
      v_company_id, p_job_id, p_member_id, auth.uid(), now()
    )
    on conflict (job_id, member_id) do nothing;
    v_changed := found;
  else
    delete from public.job_leader_assignments assignment
    where assignment.company_id = v_company_id
      and assignment.job_id = p_job_id
      and assignment.member_id = p_member_id;
    v_changed := found;
  end if;

  if v_changed then
    insert into public.job_assignment_audit_events (
      company_id, job_id, member_id, actor_id, action,
      job_number, member_name, actor_name
    ) values (
      v_company_id, p_job_id, p_member_id, auth.uid(),
      case when coalesce(p_assigned, false) then 'assigned' else 'unassigned' end,
      v_job_number, v_member_name, v_actor_name
    );
  end if;
end;
$$;


--
-- Name: set_job_package_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_job_package_status(p_package_id uuid, p_status text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_next_status text;
  v_job_active boolean;
  v_contract_active boolean;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to change a utility package status.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  v_next_status := lower(trim(coalesce(p_status, '')));
  if v_next_status not in ('active', 'closed') then
    raise exception using
      errcode = '22023',
      message = 'A utility package can only be activated or closed.';
  end if;

  select job.active, contract.active
  into v_job_active, v_contract_active
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.id = job.contract_id
  where package.id = p_package_id
    and package.company_id = v_company_id
  for update of package, job;

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

  if v_next_status = 'active' and v_contract_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reactivate the job contract before activating this utility package.';
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


--
-- Name: set_price_book_active(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_price_book_active(p_price_book_id uuid, p_active boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_target public.price_books%rowtype;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('price_books') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('price_books') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('price_books') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
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
     lower(coalesce(v_role, '')) not in ('admin','owner','superintendent') or
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


--
-- Name: set_storm_mode_assignments(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_storm_mode_assignments(p_user_ids uuid[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_requested_count integer;
  v_valid_count integer;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('admin','owner','superintendent') then
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
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin', 'owner', 'superintendent');

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
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin', 'owner', 'superintendent')
  on conflict (company_id, user_id) do nothing;

  return v_valid_count;
end;
$$;


--
-- Name: set_void_billing_batch_archived(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_void_billing_batch_archived(p_batch_id uuid, p_archived boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_company uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
    into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin') then
    raise exception using errcode='42501',message='Only Admin or Owner can archive voided billing batches.';
  end if;

  update public.billing_export_batches b
  set archived_at=case when coalesce(p_archived,false) then coalesce(b.archived_at,now()) else null end,
      archived_by=case when coalesce(p_archived,false) then coalesce(b.archived_by,auth.uid()) else null end,
      updated_at=now(),updated_by=auth.uid()
  where b.id=p_batch_id and b.company_id=v_company and b.status='void';

  if not found then
    raise exception using errcode='P0002',message='Voided billing batch was not found in your company.';
  end if;
end;
$$;


--
-- Name: stage_utility_packet_import(uuid, text, text, text, text, text, text, numeric, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stage_utility_packet_import(p_package_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_import_id uuid;
  v_row jsonb;
  v_row_number integer := 0;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'Only an active Admin, General Foreman, or authorized Superintendent can add job packets.';
  end if;

  select p.company_id into v_company_id
  from public.job_packages p
  where p.id = p_package_id
    and p.company_id = (select profile.company_id from public.profiles profile where profile.id = auth.uid());

  if v_company_id is null then
    raise exception using errcode = 'P0002', message = 'Job packet was not found in your company.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 4000 then
    raise exception using errcode = '22023', message = 'Packet extraction must contain between 1 and 4,000 source rows.';
  end if;

  insert into public.utility_packet_imports (
    company_id, job_package_id, provider_key, format_key, profile_version,
    source_filename, source_sha256, detected_work_order, extraction_confidence,
    extraction_summary, created_by
  ) values (
    v_company_id, p_package_id, lower(trim(p_provider_key)), trim(p_format_key),
    trim(p_profile_version), trim(p_source_filename), lower(trim(p_source_sha256)),
    nullif(trim(coalesce(p_detected_work_order,'')), ''), p_extraction_confidence,
    coalesce(p_summary, '{}'::jsonb), auth.uid()
  ) returning id into v_import_id;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    insert into public.utility_packet_import_rows (
      company_id, import_id, source_page, source_row, work_point_code,
      work_point_description, work_type, material_cu, contractor_unit_code,
      estimated_quantity, description, confidence, include_in_import, review_note
    ) values (
      v_company_id, v_import_id, nullif(v_row->>'source_page','')::integer, v_row_number,
      trim(coalesce(v_row->>'work_point_code','')),
      nullif(trim(coalesce(v_row->>'work_point_description','')), ''),
      lower(trim(coalesce(v_row->>'work_type',''))),
      nullif(trim(coalesce(v_row->>'material_cu','')), ''),
      nullif(trim(coalesce(v_row->>'contractor_unit_code','')), ''),
      (v_row->>'estimated_quantity')::numeric,
      nullif(trim(coalesce(v_row->>'description','')), ''),
      nullif(v_row->>'confidence','')::numeric,
      coalesce((v_row->>'include_in_import')::boolean, true),
      nullif(trim(coalesce(v_row->>'review_note','')), '')
    );
  end loop;

  return v_import_id;
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'This exact file was already staged for this job packet.';
  when invalid_text_representation or check_violation then
    raise exception using errcode = '22023', message = 'The extracted packet contains an invalid page, work type, quantity, or confidence value.';
end;
$$;


--
-- Name: submit_daily_report(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_daily_report(p_report_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_reviewed_at timestamptz;
  v_review_notes text;
  v_corrections text;
  v_reg numeric := 0;
  v_ot numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from public.daily_production_unit_locations l
    where l.daily_report_id = p_report_id
      and l.company_id = public.my_company_id()
  ) then
    raise exception 'Add at least one unit before submitting this daily report.';
  end if;

  if not exists (
    select 1 from public.timekeeping_entries t
    where t.daily_report_id=p_report_id
      and t.company_id=public.my_company_id()
  ) then
    raise exception 'Add Crew Time for at least one employee before submitting this daily report.';
  end if;

  select coalesce(sum(t.regular_hours),0), coalesce(sum(t.overtime_hours),0)
    into v_reg, v_ot
  from public.timekeeping_entries t
  where t.daily_report_id=p_report_id
    and t.company_id=public.my_company_id();

  select reviewed_at, review_notes
  into v_reviewed_at, v_review_notes
  from public.daily_reports
  where id=p_report_id
    and company_id=public.my_company_id()
    and foreman_id=auth.uid()
    and status in ('draft','rejected');

  if not found then
    raise exception 'Report not found or cannot be submitted';
  end if;

  if v_reviewed_at is not null and nullif(btrim(coalesce(v_review_notes,'')),'') is not null then
    select string_agg('• ' || e.event_notes, E'\n' order by e.created_at)
    into v_corrections
    from public.daily_report_audit_events e
    where e.daily_report_id=p_report_id
      and e.company_id=public.my_company_id()
      and e.event_type='foreman_correction'
      and e.created_at >= v_reviewed_at;
  end if;

  update public.daily_reports
  set status='submitted',
      submitted_at=now(),
      updated_at=now(),
      regular_hours=v_reg,
      overtime_hours=v_ot,
      hours=v_reg+v_ot,
      review_notes = case
        when nullif(v_corrections,'') is not null then
          regexp_replace(coalesce(v_review_notes,''), E'\n\nFOREMAN CORRECTIONS:[\s\S]*$', '', 'g') || E'\n\nFOREMAN CORRECTIONS:\n' || v_corrections
        else v_review_notes
      end
  where id=p_report_id
    and company_id=public.my_company_id()
    and foreman_id=auth.uid()
    and status in ('draft','rejected');
end;
$_$;


--
-- Name: submit_pilot_feedback(text, integer, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_pilot_feedback(p_category text, p_rating integer, p_message text, p_page text DEFAULT 'app'::text, p_contact_ok boolean DEFAULT true) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: supersede_prior_job_package(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.supersede_prior_job_package() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.status = 'active' then
    update public.job_packages package
    set status = 'closed',
        updated_at = now()
    where package.company_id = new.company_id
      and package.job_id = new.job_id
      and package.id <> new.id
      and package.status = 'active';
  end if;

  return new;
end;
$$;


--
-- Name: support_console_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_console_identity() RETURNS TABLE(is_support boolean, company_id uuid, company_role text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select public.is_platform_support(),p.company_id,lower(p.role)
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;
$$;


--
-- Name: support_get_diagnostics(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_get_diagnostics(p_request_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_request public.support_access_requests%rowtype; v_result jsonb;
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  select * into v_request from public.support_access_requests
    where id=p_request_id and support_user_id=(select auth.uid()) and status='approved' and expires_at>now();
  if not found then raise exception 'Approved, unexpired support access is required'; end if;
  select jsonb_build_object(
    'company_id',c.id,'company_name',c.name,'access_expires_at',v_request.expires_at,
    'active_users',(select count(*) from public.profiles p where p.company_id=c.id and p.active is true),
    'suspended_users',(select count(*) from public.profiles p where p.company_id=c.id and p.active is false),
    'jobs',(select count(*) from public.jobs j where j.company_id=c.id),
    'active_jobs',(select count(*) from public.jobs j where j.company_id=c.id and j.active is true),
    'customers',(select count(*) from public.customers x where x.company_id=c.id),
    'contracts',(select count(*) from public.contracts x where x.company_id=c.id),
    'price_books',(select count(*) from public.price_books x where x.company_id=c.id),
    'daily_reports',(select count(*) from public.daily_reports x where x.company_id=c.id),
    'draft_reports',(select count(*) from public.daily_reports x where x.company_id=c.id and lower(coalesce(x.status,'draft'))='draft'),
    'submitted_reports',(select count(*) from public.daily_reports x where x.company_id=c.id and lower(coalesce(x.status,''))='submitted'),
    'latest_report_at',(select max(x.created_at) from public.daily_reports x where x.company_id=c.id),
    'latest_job_at',(select max(x.created_at) from public.jobs x where x.company_id=c.id),
    'roles',(select coalesce(jsonb_object_agg(q.role,q.total),'{}'::jsonb) from
      (select lower(coalesce(p.role,'unknown')) role,count(*) total from public.profiles p where p.company_id=c.id group by 1) q)
  ) into v_result from public.companies c where c.id=v_request.company_id;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type,details)
  values(p_request_id,v_request.company_id,(select auth.uid()),'diagnostics_viewed',jsonb_build_object('scope','aggregate_only'));
  return v_result;
end;
$$;


--
-- Name: support_get_recent_errors(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_get_recent_errors(p_request_id uuid) RETURNS TABLE(id bigint, area text, error_code text, page text, safe_message text, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_request public.support_access_requests%rowtype;
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  select * into v_request from public.support_access_requests r
    where r.id=p_request_id and r.support_user_id=(select auth.uid())
      and r.status='approved' and r.expires_at>now();
  if not found then raise exception 'Approved, unexpired support access is required'; end if;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type,details)
  values(p_request_id,v_request.company_id,(select auth.uid()),'error_log_viewed',jsonb_build_object('scope','sanitized'));
  return query select e.id,e.area,e.error_code,e.page,e.safe_message,e.created_at
    from public.app_error_events e where e.company_id=v_request.company_id
    order by e.created_at desc limit 50;
end;
$$;


--
-- Name: support_list_companies(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_list_companies() RETURNS TABLE(id uuid, name text, active_users bigint, last_activity timestamp with time zone, subscription_status text, subscription_expires_at timestamp with time zone, recent_errors bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  return query
  select c.id,c.name,
    (select count(*) from public.profiles p where p.company_id=c.id and p.active is true),
    greatest(
      coalesce((select max(j.created_at) from public.jobs j where j.company_id=c.id),c.created_at),
      coalesce((select max(r.created_at) from public.daily_reports r where r.company_id=c.id),c.created_at)
    ),c.subscription_status,c.subscription_expires_at,
    (select count(*) from public.app_error_events e where e.company_id=c.id and e.created_at>now()-interval '24 hours')
  from public.companies c order by lower(c.name);
end;
$$;


--
-- Name: support_list_my_requests(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_list_my_requests() RETURNS TABLE(id uuid, company_id uuid, company_name text, reason text, status text, requested_at timestamp with time zone, requested_minutes integer, approved_at timestamp with time zone, expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  update public.support_access_requests r set status='expired'
    where r.support_user_id=(select auth.uid()) and r.status='approved' and r.expires_at<=now();
  return query select r.id,r.company_id,c.name,r.reason,r.status,r.requested_at,r.requested_minutes,r.approved_at,r.expires_at
    from public.support_access_requests r join public.companies c on c.id=r.company_id
    where r.support_user_id=(select auth.uid()) order by r.requested_at desc limit 100;
end;
$$;


--
-- Name: support_list_pilot_command_center(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_list_pilot_command_center() RETURNS TABLE(company_id uuid, company_name text, company_active boolean, subscription_status text, subscription_expires_at timestamp with time zone, company_created_at timestamp with time zone, active_users bigint, setup_completed integer, setup_total integer, setup_missing text[], open_feedback bigint, recent_errors bigint, latest_error_area text, latest_error_code text, pending_support_approvals bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.is_platform_support() then
    raise exception using errcode = '42501', message = 'Platform support access required.';
  end if;

  return query
  with profile_counts as (
    select p.company_id,
      count(*) filter (where p.active is true)::bigint as active_users
    from public.profiles p
    group by p.company_id
  ), customer_counts as (
    select x.company_id, count(*)::bigint as active_customers
    from public.customers x
    where x.active is true
    group by x.company_id
  ), contract_counts as (
    select x.company_id, count(*)::bigint as active_contracts
    from public.contracts x
    where x.active is true
    group by x.company_id
  ), price_book_counts as (
    select x.company_id, count(*)::bigint as active_price_books
    from public.price_books x
    where x.active is true
    group by x.company_id
  ), job_counts as (
    select x.company_id, count(*)::bigint as active_jobs
    from public.jobs x
    where x.active is true
    group by x.company_id
  ), report_counts as (
    select x.company_id, count(*)::bigint as reports
    from public.daily_reports x
    group by x.company_id
  ), feedback_counts as (
    select x.company_id,
      count(*) filter (where x.resolved_at is null)::bigint as open_feedback
    from public.pilot_feedback x
    group by x.company_id
  ), support_counts as (
    select x.company_id,
      count(*) filter (where x.status = 'pending')::bigint as pending_approvals
    from public.support_access_requests x
    group by x.company_id
  ), error_counts as (
    select x.company_id, count(*)::bigint as recent_errors
    from public.app_error_events x
    where x.created_at >= now() - interval '24 hours'
    group by x.company_id
  ), latest_errors as (
    select distinct on (x.company_id)
      x.company_id, x.area, x.error_code
    from public.app_error_events x
    where x.created_at >= now() - interval '24 hours'
    order by x.company_id, x.created_at desc
  ), readiness as (
    select c.*,
      (nullif(trim(c.name), '') is not null
        and nullif(trim(c.contact_email), '') is not null
        and nullif(trim(c.contact_phone), '') is not null
        and nullif(trim(c.timezone), '') is not null) as contact_ready,
      coalesce(pc.active_users, 0) > 1 as team_ready,
      coalesce(cc.active_customers, 0) > 0 as customer_ready,
      coalesce(ct.active_contracts, 0) > 0 as contract_ready,
      coalesce(pb.active_price_books, 0) > 0 as price_book_ready,
      coalesce(jc.active_jobs, 0) > 0 as job_ready,
      coalesce(rc.reports, 0) > 0 as report_ready,
      coalesce(pc.active_users, 0) as active_user_count,
      coalesce(fc.open_feedback, 0) as open_feedback_count,
      coalesce(ec.recent_errors, 0) as recent_error_count,
      le.area as latest_area,
      le.error_code as latest_code,
      coalesce(sc.pending_approvals, 0) as pending_approval_count
    from public.companies c
    left join profile_counts pc on pc.company_id = c.id
    left join customer_counts cc on cc.company_id = c.id
    left join contract_counts ct on ct.company_id = c.id
    left join price_book_counts pb on pb.company_id = c.id
    left join job_counts jc on jc.company_id = c.id
    left join report_counts rc on rc.company_id = c.id
    left join feedback_counts fc on fc.company_id = c.id
    left join support_counts sc on sc.company_id = c.id
    left join error_counts ec on ec.company_id = c.id
    left join latest_errors le on le.company_id = c.id
  )
  select
    r.id,
    r.name,
    r.active,
    r.subscription_status,
    r.subscription_expires_at,
    r.created_at,
    r.active_user_count,
    (r.contact_ready::integer + r.team_ready::integer +
      r.customer_ready::integer + r.contract_ready::integer +
      r.price_book_ready::integer + r.job_ready::integer +
      r.report_ready::integer)::integer,
    7,
    array_remove(array[
      case when not r.contact_ready then 'Company contact' end,
      case when not r.team_ready then 'Team member' end,
      case when not r.customer_ready then 'Customer or utility' end,
      case when not r.contract_ready then 'Active contract' end,
      case when not r.price_book_ready then 'Active Price Book' end,
      case when not r.job_ready then 'Active job' end,
      case when not r.report_ready then 'First daily report' end
    ], null)::text[],
    r.open_feedback_count,
    r.recent_error_count,
    r.latest_area,
    r.latest_code,
    r.pending_approval_count
  from readiness r
  order by
    case
      when r.active is not true then 0
      when r.subscription_status in ('suspended', 'cancelled') then 0
      when r.subscription_status = 'trial'
        and r.subscription_expires_at is not null
        and r.subscription_expires_at <= now() then 0
      when r.pending_approval_count > 0 or r.recent_error_count > 0 then 1
      else 2
    end,
    r.created_at desc;
end;
$$;


--
-- Name: support_list_pilot_feedback(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_list_pilot_feedback(p_limit integer DEFAULT 100) RETURNS TABLE(id uuid, company_id uuid, company_name text, submitted_by uuid, submitted_name text, category text, rating smallint, message text, page text, contact_ok boolean, created_at timestamp with time zone, resolved_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not public.is_platform_support() then
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


--
-- Name: support_request_access(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_request_access(p_company_id uuid, p_reason text, p_minutes integer DEFAULT 30) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id uuid;
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  if not exists(select 1 from public.companies where id=p_company_id) then raise exception 'Company not found'; end if;
  if char_length(trim(coalesce(p_reason,''))) not between 10 and 500 then raise exception 'A support reason of 10 to 500 characters is required'; end if;
  if p_minutes not between 5 and 60 then raise exception 'Support access must be between 5 and 60 minutes'; end if;
  update public.support_access_requests set status='expired'
    where support_user_id=(select auth.uid()) and company_id=p_company_id
      and status='approved' and expires_at<=now();
  insert into public.support_access_requests(support_user_id,company_id,reason,requested_minutes)
  values ((select auth.uid()),p_company_id,trim(p_reason),p_minutes) returning id into v_id;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type,details)
  values(v_id,p_company_id,(select auth.uid()),'access_requested',jsonb_build_object('minutes',p_minutes));
  return v_id;
end;
$$;


--
-- Name: support_resolve_pilot_feedback(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_resolve_pilot_feedback(p_feedback_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_company_id uuid;
begin
  if not public.is_platform_support() then
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
    company_id,actor_id,event_type,details
  ) values (
    v_company_id,auth.uid(),'pilot_feedback_resolved',
    jsonb_build_object('feedback_id',p_feedback_id)
  );
end;
$$;


--
-- Name: support_set_company_access(uuid, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.support_set_company_access(p_company_id uuid, p_status text, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_status text:=lower(trim(coalesce(p_status,'')));
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  if v_status not in ('trial','active','internal','past_due','suspended','cancelled') then raise exception 'Invalid company access status'; end if;
  if v_status='trial' and p_expires_at is not null and p_expires_at<=now() then raise exception 'Trial expiration must be in the future'; end if;
  update public.companies set subscription_status=v_status,
    subscription_expires_at=case when v_status='trial' then p_expires_at else null end,
    updated_at=now()
  where id=p_company_id;
  if not found then raise exception 'Company not found'; end if;
  insert into public.support_audit_events(company_id,actor_id,event_type,details)
  values(p_company_id,(select auth.uid()),'company_access_updated',
    jsonb_build_object('status',v_status,'expires_at',p_expires_at));
end;
$$;


--
-- Name: sync_daily_report_hours_from_timekeeping(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_daily_report_hours_from_timekeeping() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_report_id uuid;
  v_reg numeric := 0;
  v_ot numeric := 0;
begin
  v_report_id := coalesce(new.daily_report_id, old.daily_report_id);
  if v_report_id is null then
    return coalesce(new, old);
  end if;

  select coalesce(sum(t.regular_hours),0), coalesce(sum(t.overtime_hours),0)
    into v_reg, v_ot
  from public.timekeeping_entries t
  where t.daily_report_id=v_report_id;

  update public.daily_reports d
     set regular_hours=v_reg,
         overtime_hours=v_ot,
         hours=v_reg+v_ot,
         updated_at=now()
   where d.id=v_report_id;

  return coalesce(new, old);
end;
$$;


--
-- Name: sync_foreman_timekeeping_employee(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_foreman_timekeeping_employee() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_role text := lower(coalesce(new.role,''));
  v_classification text;
  v_assigned_foreman_id uuid;
begin
  v_classification := case v_role
    when 'foreman' then 'Foreman'
    when 'gf' then 'General Foreman'
    when 'superintendent' then 'Superintendent'
    when 'admin' then 'Admin'
    when 'owner' then 'Owner'
    else null
  end;
  v_assigned_foreman_id := case when v_role = 'foreman' then new.id else null end;

  if v_classification is not null
     and coalesce(new.active,true) is true
     and new.company_id is not null then
    insert into public.timekeeping_employees(
      company_id, full_name, classification, active, assigned_foreman_id,
      linked_profile_id, created_by, updated_at
    ) values (
      new.company_id,
      coalesce(nullif(btrim(new.full_name),''),v_classification),
      v_classification,
      true,
      v_assigned_foreman_id,
      new.id,
      new.id,
      now()
    )
    on conflict (linked_profile_id) where linked_profile_id is not null
    do update set
      company_id = excluded.company_id,
      full_name = excluded.full_name,
      classification = excluded.classification,
      active = true,
      assigned_foreman_id = excluded.assigned_foreman_id,
      updated_at = now();
  elsif new.id is not null then
    update public.timekeeping_employees
       set active = false, updated_at = now()
     where linked_profile_id = new.id;
  end if;

  return new;
end;
$$;


--
-- Name: timekeeping_period_state(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.timekeeping_period_state(p_start date, p_end date) RETURNS TABLE(period_start date, period_end date, status text, approved_by uuid, approved_at timestamp with time zone, locked_by uuid, locked_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with me as (
    select p.company_id from public.profiles p where p.id = auth.uid() and p.active is true
  )
  select p_start,p_end,coalesce(pp.status,'open'),pp.approved_by,pp.approved_at,pp.locked_by,pp.locked_at
  from me left join public.timekeeping_pay_periods pp on pp.company_id=me.company_id and pp.period_start=p_start and pp.period_end=p_end;
$$;


--
-- Name: timekeeping_report_rows(date, date, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.timekeeping_report_rows(p_from date, p_through date, p_employee uuid DEFAULT NULL::uuid, p_job uuid DEFAULT NULL::uuid) RETURNS TABLE(employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text, regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with viewer as (
    select p.id, p.company_id, lower(coalesce(p.role,'')) as role
    from public.profiles p
    where p.id = auth.uid() and coalesce(p.active,true) is true
  ), all_rows as (
    select e.employee_id,e.daily_report_id,e.job_id,e.work_date,e.crew_name,e.regular_hours,e.overtime_hours,e.storm_work,e.notes,
           'current'::text segment_source,e.company_id,e.created_by
    from public.timekeeping_entries e
    union all
    select h.employee_id,h.daily_report_id,h.job_id,h.work_date,h.crew_name,h.regular_hours,h.overtime_hours,h.storm_work,h.notes,
           'history'::text,h.company_id,h.created_by
    from public.timekeeping_entry_history h
  )
  select r.employee_id,r.daily_report_id,r.job_id,r.work_date,r.crew_name,r.regular_hours,r.overtime_hours,r.storm_work,r.notes,r.segment_source
  from all_rows r
  join viewer v on v.company_id = r.company_id
  where r.work_date between p_from and p_through
    and (p_employee is null or r.employee_id = p_employee)
    and (p_job is null or r.job_id = p_job)
    and (
      v.role in ('gf','admin','owner')
      or (v.role='superintendent' and public.linecrew_has_capability('reporting'))
      or (v.role='foreman' and (
        r.created_by=v.id
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id=r.employee_id and te.company_id=r.company_id and te.assigned_foreman_id=v.id
        )
      ))
    )
  order by r.work_date desc, r.employee_id;
$$;


--
-- Name: timekeeping_report_rows_v2(date, date, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.timekeeping_report_rows_v2(p_from date, p_through date, p_employee uuid DEFAULT NULL::uuid, p_job uuid DEFAULT NULL::uuid) RETURNS TABLE(employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text, regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text, start_time time without time zone, stop_time time without time zone, lunch_minutes integer, per_diem boolean, equipment_used text, equipment_not_used boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  with viewer as (
    select p.id, p.company_id, lower(coalesce(p.role,'')) as role
    from public.profiles p
    where p.id=auth.uid() and coalesce(p.active,true) is true
  ), all_rows as (
    select e.employee_id,e.daily_report_id,e.job_id,e.work_date,e.crew_name,e.regular_hours,e.overtime_hours,e.storm_work,e.notes,
           'current'::text segment_source,e.company_id,e.created_by,e.start_time,e.stop_time,e.lunch_minutes,e.per_diem,e.equipment_used,e.equipment_not_used
    from public.timekeeping_entries e
    union all
    select h.employee_id,h.daily_report_id,h.job_id,h.work_date,h.crew_name,h.regular_hours,h.overtime_hours,h.storm_work,h.notes,
           'history'::text,h.company_id,h.created_by,h.start_time,h.stop_time,h.lunch_minutes,h.per_diem,h.equipment_used,h.equipment_not_used
    from public.timekeeping_entry_history h
  )
  select r.employee_id,r.daily_report_id,r.job_id,r.work_date,r.crew_name,r.regular_hours,r.overtime_hours,r.storm_work,r.notes,r.segment_source,
         r.start_time,r.stop_time,r.lunch_minutes,r.per_diem,r.equipment_used,r.equipment_not_used
  from all_rows r
  join viewer v on v.company_id=r.company_id
  where r.work_date between p_from and p_through
    and (p_employee is null or r.employee_id=p_employee)
    and (p_job is null or r.job_id=p_job)
    and (
      v.role in ('gf','admin','owner')
      or (v.role='superintendent' and public.linecrew_has_capability('reporting'))
      or (v.role='foreman' and (
        r.created_by=v.id
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id=r.employee_id and te.company_id=r.company_id and te.assigned_foreman_id=v.id
        )
      ))
    )
  order by r.work_date desc,r.employee_id;
$$;


--
-- Name: timekeeping_report_rows_v3(date, date, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.timekeeping_report_rows_v3(p_from date, p_through date, p_employee uuid DEFAULT NULL::uuid, p_job uuid DEFAULT NULL::uuid) RETURNS TABLE(entry_id uuid, employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text, regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text, start_time time without time zone, stop_time time without time zone, lunch_minutes integer, per_diem boolean, equipment_used text, equipment_not_used boolean, entry_kind text, labor_code text)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  with viewer as (
    select profile.id, profile.company_id, lower(coalesce(profile.role,'')) as role
    from public.profiles profile
    where profile.id = auth.uid() and coalesce(profile.active,true) is true
  ), all_rows as (
    select entry.id as entry_id, entry.employee_id, entry.daily_report_id, entry.job_id,
           entry.work_date, entry.crew_name, entry.regular_hours, entry.overtime_hours,
           entry.storm_work, entry.notes, 'current'::text as segment_source,
           entry.company_id, entry.created_by, entry.start_time, entry.stop_time,
           entry.lunch_minutes, entry.per_diem, entry.equipment_used,
           entry.equipment_not_used, entry.entry_kind, entry.labor_code
    from public.timekeeping_entries entry
    union all
    select history.id as entry_id, history.employee_id, history.daily_report_id,
           history.job_id, history.work_date, history.crew_name, history.regular_hours,
           history.overtime_hours, history.storm_work, history.notes,
           'history'::text as segment_source, history.company_id, history.created_by,
           history.start_time, history.stop_time, history.lunch_minutes,
           history.per_diem, history.equipment_used, history.equipment_not_used,
           'crew'::text as entry_kind, null::text as labor_code
    from public.timekeeping_entry_history history
  )
  select row.entry_id, row.employee_id, row.daily_report_id, row.job_id, row.work_date,
         row.crew_name, row.regular_hours, row.overtime_hours, row.storm_work,
         row.notes, row.segment_source, row.start_time, row.stop_time,
         row.lunch_minutes, row.per_diem, row.equipment_used,
         row.equipment_not_used, row.entry_kind, row.labor_code
  from all_rows row
  join viewer on viewer.company_id = row.company_id
  where row.work_date between p_from and p_through
    and (p_employee is null or row.employee_id = p_employee)
    and (p_job is null or row.job_id = p_job)
    and (
      viewer.role in ('gf','admin','owner')
      or (viewer.role = 'superintendent' and public.linecrew_has_capability('reporting'))
      or (row.entry_kind = 'leadership_self' and exists (
        select 1 from public.timekeeping_employees employee
        where employee.id = row.employee_id
          and employee.company_id = row.company_id
          and employee.linked_profile_id = viewer.id
      ))
      or (viewer.role = 'foreman' and (
        row.created_by = viewer.id
        or exists (
          select 1 from public.timekeeping_employees employee
          where employee.id = row.employee_id
            and employee.company_id = row.company_id
            and employee.assigned_foreman_id = viewer.id
        )
      ))
    )
  order by row.work_date desc, row.employee_id;
$$;


--
-- Name: timekeeping_set_period_status(date, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.timekeeping_set_period_status(p_start date, p_end date, p_action text) RETURNS TABLE(period_start date, period_end date, status text, approved_by uuid, approved_at timestamp with time zone, locked_by uuid, locked_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_user uuid := auth.uid(); v_company uuid; v_role text; v_active boolean; v_status text;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active into v_company,v_role,v_active from public.profiles p where p.id=v_user;
  if v_company is null or v_active is not true then raise exception using errcode='42501',message='Active company access is required.'; end if;
  if p_start is null or p_end is null or p_end < p_start then raise exception using errcode='22023',message='Choose a valid pay period.'; end if;
  if lower(coalesce(p_action,'')) not in ('approve','reopen','lock','unlock') then raise exception using errcode='22023',message='Unsupported Timekeeping pay-period action.'; end if;
  if lower(p_action) in ('approve','reopen') and v_role not in ('gf','admin','owner') then raise exception using errcode='42501',message='Only a General Foreman, Admin, or Owner can approve or reopen Timekeeping.'; end if;
  if lower(p_action) in ('lock','unlock') and v_role not in ('admin','owner') then raise exception using errcode='42501',message='Only an Admin or Owner can lock or unlock a pay period.'; end if;
  insert into public.timekeeping_pay_periods(company_id,period_start,period_end,status) values(v_company,p_start,p_end,'open') on conflict on constraint timekeeping_pay_period_company_dates_unique do nothing;
  select pp.status into v_status from public.timekeeping_pay_periods pp where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end for update;
  if lower(p_action)='approve' then
    update public.timekeeping_pay_periods pp set status='approved',approved_by=v_user,approved_at=now(),locked_by=null,locked_at=null,updated_at=now() where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  elsif lower(p_action)='reopen' then
    if v_status='locked' then raise exception using errcode='42501',message='Unlock the pay period before reopening it.'; end if;
    update public.timekeeping_pay_periods pp set status='open',approved_by=null,approved_at=null,locked_by=null,locked_at=null,updated_at=now() where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  elsif lower(p_action)='lock' then
    if v_status <> 'approved' then raise exception using errcode='22023',message='Approve the pay period before locking it.'; end if;
    update public.timekeeping_pay_periods pp set status='locked',locked_by=v_user,locked_at=now(),updated_at=now() where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  elsif lower(p_action)='unlock' then
    update public.timekeeping_pay_periods pp set status='approved',locked_by=null,locked_at=null,updated_at=now() where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  end if;
  insert into public.timekeeping_pay_period_audit(company_id,period_start,period_end,action,actor_id,detail) values(v_company,p_start,p_end,lower(p_action),v_user,'Status action from Timekeeping workspace');
  return query select pp.period_start,pp.period_end,pp.status,pp.approved_by,pp.approved_at,pp.locked_by,pp.locked_at from public.timekeeping_pay_periods pp where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
end;
$$;


--
-- Name: training_role_rank(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.training_role_rank(p_role text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case lower(coalesce(p_role,''))
    when 'owner' then 5
    when 'admin' then 4
    when 'superintendent' then 3
    when 'gf' then 2
    when 'general foreman' then 2
    when 'foreman' then 1
    else 0
  end;
$$;


--
-- Name: update_company_man_hour_rate(numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_company_man_hour_rate(p_required_rate numeric) RETURNS numeric
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_rate numeric(12,2);
begin
  select p.company_id, lower(p.role)
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  if v_company_id is null or v_role not in ('owner', 'admin') then
    raise exception 'Only an active company Owner or Admin may set the required man-hour rate.'
      using errcode = '42501';
  end if;

  if p_required_rate is null or p_required_rate = 0 then
    v_rate := null;
  elsif p_required_rate < 0.01 or p_required_rate > 1000000 then
    raise exception 'Required man-hour rate must be between 0.01 and 1,000,000.'
      using errcode = '22003';
  else
    v_rate := round(p_required_rate, 2);
  end if;

  update public.companies
  set required_man_hour_rate = v_rate
  where id = v_company_id;

  return v_rate;
end;
$$;


--
-- Name: update_company_settings(text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_company_settings(p_name text, p_contact_email text DEFAULT NULL::text, p_contact_phone text DEFAULT NULL::text, p_logo_url text DEFAULT NULL::text, p_primary_color text DEFAULT '#0b2d4d'::text, p_timezone text DEFAULT 'America/Chicago'::text) RETURNS TABLE(id uuid, name text, contact_email text, contact_phone text, logo_url text, primary_color text, timezone text, updated_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare v_company_id uuid; v_role text; v_active boolean; v_name text:=trim(coalesce(p_name,'')); v_email text:=nullif(trim(coalesce(p_contact_email,'')),''); v_phone text:=nullif(trim(coalesce(p_contact_phone,'')),''); v_logo text:=nullif(trim(coalesce(p_logo_url,'')),''); v_color text:=lower(trim(coalesce(p_primary_color,''))); v_timezone text:=trim(coalesce(p_timezone,''));
begin
 select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
 if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then raise exception using errcode='42501',message='An active company Admin, Owner, or permitted Superintendent is required.'; end if;
 if v_role='superintendent' and not public.linecrew_has_capability('company_settings') then raise exception using errcode='42501',message='This Superintendent does not have company settings permission.'; end if;
 if length(v_name)<2 or length(v_name)>120 then raise exception 'Company name must be between 2 and 120 characters.'; end if;
 if v_email is not null and (length(v_email)>254 or position('@' in v_email)<2) then raise exception 'Enter a valid company email address.'; end if;
 if v_phone is not null and length(v_phone)>40 then raise exception 'Company phone must be 40 characters or fewer.'; end if;
 if v_logo is not null and (length(v_logo)>1000 or v_logo !~* '^https://') then raise exception 'Logo URL must be a secure https:// address.'; end if;
 if v_color !~ '^#[0-9a-f]{6}$' then raise exception 'Brand color must use the format #0b2d4d.'; end if;
 if v_timezone not in ('America/Chicago','America/New_York','America/Denver','America/Los_Angeles','America/Anchorage','Pacific/Honolulu') then raise exception 'Unsupported company time zone.'; end if;
 return query update public.companies company set name=v_name,contact_email=v_email,contact_phone=v_phone,logo_url=v_logo,primary_color=v_color,timezone=v_timezone,updated_at=now() where company.id=v_company_id returning company.id,company.name,company.contact_email,company.contact_phone,company.logo_url,company.primary_color,company.timezone,company.updated_at;
end; $_$;


--
-- Name: update_company_week_start(smallint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_company_week_start(p_week_start_day smallint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if p_week_start_day is null or p_week_start_day < 0 or p_week_start_day > 6 then
    raise exception using errcode = '22023', message = 'Week start day must be Sunday through Saturday.';
  end if;

  select p.company_id, lower(coalesce(p.role,'')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('owner','admin') then
    raise exception using errcode = '42501', message = 'Only an Owner or Admin can change the company workweek.';
  end if;

  update public.companies
  set week_start_day = p_week_start_day, updated_at = now()
  where id = v_company_id;
end;
$$;


--
-- Name: update_contract_job(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_contract_job(p_job_id uuid, p_contract_id uuid, p_job_number text, p_job_name text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
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


--
-- Name: update_daily_report(uuid, uuid, date, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_daily_report(p_report_id uuid, p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_contract_id uuid;
  v_price_book_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, ''))
  into v_company_id, v_role
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role <> 'foreman' then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman profile is required.';
  end if;

  select job.contract_id, job.price_book_id
  into v_contract_id, v_price_book_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
    and public.linecrew_foreman_has_job_assignment(job.id);

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active assigned job not found.';
  end if;

  if v_price_book_id is not null and not exists (
    select 1
    from public.price_books book
    where book.id = v_price_book_id
      and book.company_id = v_company_id
      and book.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'The job Price Book does not belong to this company and contract.';
  end if;

  update public.daily_reports report
  set job_id = p_job_id,
      price_book_id = case
        when report.job_id is distinct from p_job_id then v_price_book_id
        else coalesce(report.price_book_id, v_price_book_id)
      end,
      work_date = p_work_date,
      regular_hours = coalesce(p_regular_hours, 0),
      overtime_hours = coalesce(p_overtime_hours, 0),
      crew_name = nullif(trim(p_crew_name), ''),
      notes = nullif(trim(p_notes), ''),
      updated_at = now()
  where report.id = p_report_id
    and report.company_id = v_company_id
    and report.status = 'draft'
    and report.foreman_id = auth.uid();

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Draft report not found or cannot be edited.';
  end if;
end;
$$;


--
-- Name: update_job(uuid, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_job(p_job_id uuid, p_job_number text, p_job_name text, p_customer_name text DEFAULT NULL::text, p_utility_name text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;
  if lower(coalesce(public.my_role(), '')) not in ('owner', 'admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only the Company Owner, Admin or General Foreman can update jobs.';
  end if;
  update public.jobs
  set job_number = btrim(p_job_number),
      job_name = btrim(p_job_name),
      customer_name = nullif(btrim(p_customer_name), ''),
      utility_name = nullif(btrim(p_utility_name), '')
  where id = p_job_id and company_id = public.my_company_id();
  if not found then
    raise exception using errcode = 'P0002', message = 'Job not found.';
  end if;
end;
$$;


--
-- Name: update_my_profile_name(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_my_profile_name(p_full_name text) RETURNS TABLE(id uuid, full_name text, role text, company_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_name text := btrim(coalesce(p_full_name, ''));
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;

  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception using errcode = '22023',
      message = 'Display name must be between 2 and 120 characters.';
  end if;

  perform set_config('linecrew.profile_name_sync', auth.uid()::text, true);

  return query
  update public.profiles profile
  set full_name = v_name
  where profile.id = auth.uid()
    and profile.active is true
  returning profile.id, profile.full_name, profile.role, profile.company_id;
end;
$$;


--
-- Name: update_utility_packet_import_row(uuid, text, text, text, numeric, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_utility_packet_import_row(p_row_id uuid, p_work_point_code text, p_work_type text, p_contractor_unit_code text, p_estimated_quantity numeric, p_include_in_import boolean, p_review_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_import_id uuid;
  v_work_type text := lower(btrim(coalesce(p_work_type, '')));
  v_contractor_unit_code text := nullif(
    btrim(coalesce(p_contractor_unit_code, '')),
    ''
  );
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to review job packets.';
  end if;

  if v_work_type not in ('install', 'transfer', 'remove') then
    raise exception using
      errcode = '22023',
      message = 'Work type must be Install, Transfer or Remove.';
  end if;
  if nullif(
    public.normalize_work_point_key(p_work_point_code),
    ''
  ) is null then
    raise exception using
      errcode = '22023',
      message = 'A valid work point is required.';
  end if;
  if v_contractor_unit_code is not null and nullif(
    regexp_replace(
      upper(v_contractor_unit_code),
      '[^A-Z0-9]',
      '',
      'g'
    ),
    ''
  ) is null then
    raise exception using
      errcode = '22023',
      message = 'Enter a Contractor Unit containing a letter or number.';
  end if;
  if coalesce(p_estimated_quantity, 0) <= 0 then
    raise exception using
      errcode = '22023',
      message = 'Estimated quantity must be greater than zero.';
  end if;

  select row_item.company_id, row_item.import_id
  into v_company_id, v_import_id
  from public.utility_packet_import_rows row_item
  join public.utility_packet_imports packet_import
    on packet_import.id = row_item.import_id
   and packet_import.company_id = row_item.company_id
   and packet_import.status = 'review'
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = row_item.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where row_item.id = p_row_id
  for update of packet_import, package;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Review row was not found or is no longer editable.';
  end if;

  update public.utility_packet_import_rows row_item
  set work_point_code = btrim(p_work_point_code),
      work_type = v_work_type,
      contractor_unit_code = v_contractor_unit_code,
      estimated_quantity = p_estimated_quantity,
      include_in_import = coalesce(p_include_in_import, false),
      review_note = nullif(btrim(coalesce(p_review_note, '')), '')
  where row_item.id = p_row_id
    and row_item.import_id = v_import_id
    and row_item.company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Review row was not found or is no longer editable.';
  end if;
end;
$$;


--
-- Name: update_utility_packet_import_rows_bulk(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_utility_packet_import_rows_bulk(p_import_id uuid, p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_input_count integer;
  v_distinct_count integer;
  v_expected_count integer;
  v_updated_count integer;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to review job packets.';
  end if;

  select packet_import.company_id
  into v_company_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of packet_import, package;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found or is no longer editable.';
  end if;

  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message = 'Packet review rows must be a JSON array.';
  end if;

  v_input_count := jsonb_array_length(p_rows);
  if v_input_count < 1 or v_input_count > 4000 then
    raise exception using
      errcode = '22023',
      message = 'Review between 1 and 4,000 packet rows at a time.';
  end if;

  with input_rows as (
    select *
    from jsonb_to_recordset(p_rows) as input_row(
      row_id uuid,
      work_point_code text,
      work_type text,
      contractor_unit_code text,
      estimated_quantity numeric,
      include_in_import boolean,
      review_note text
    )
  )
  select count(distinct input_row.row_id)
  into v_distinct_count
  from input_rows input_row;

  if v_distinct_count <> v_input_count then
    raise exception using
      errcode = '22023',
      message = 'Packet review rows contain a missing or duplicate row identifier.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_rows) as input_row(
      row_id uuid,
      work_point_code text,
      work_type text,
      contractor_unit_code text,
      estimated_quantity numeric,
      include_in_import boolean,
      review_note text
    )
    where lower(btrim(coalesce(input_row.work_type, '')))
          not in ('install', 'transfer', 'remove')
       or nullif(btrim(coalesce(input_row.work_point_code, '')), '') is null
       or nullif(
         public.normalize_work_point_key(input_row.work_point_code),
         ''
       ) is null
       or (
         nullif(
           btrim(coalesce(input_row.contractor_unit_code, '')),
           ''
         ) is not null
         and nullif(
           regexp_replace(
             upper(btrim(input_row.contractor_unit_code)),
             '[^A-Z0-9]',
             '',
             'g'
           ),
           ''
         ) is null
       )
       or coalesce(input_row.estimated_quantity, 0) <= 0
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every review row needs a valid work point, work type, Contractor Unit format, and quantity greater than zero.';
  end if;

  select count(*)
  into v_expected_count
  from public.utility_packet_import_rows row_item
  where row_item.import_id = p_import_id
    and row_item.company_id = v_company_id;

  if v_expected_count <> v_input_count then
    raise exception using
      errcode = '23514',
      message = 'The packet review changed. Reopen it before saving.';
  end if;

  with input_rows as (
    select *
    from jsonb_to_recordset(p_rows) as input_row(
      row_id uuid,
      work_point_code text,
      work_type text,
      contractor_unit_code text,
      estimated_quantity numeric,
      include_in_import boolean,
      review_note text
    )
  )
  update public.utility_packet_import_rows row_item
  set work_point_code = btrim(input_row.work_point_code),
      work_type = lower(btrim(input_row.work_type)),
      contractor_unit_code = nullif(
        btrim(coalesce(input_row.contractor_unit_code, '')),
        ''
      ),
      estimated_quantity = input_row.estimated_quantity,
      include_in_import = coalesce(input_row.include_in_import, false),
      review_note = nullif(
        btrim(coalesce(input_row.review_note, '')),
        ''
      )
  from input_rows input_row
  where row_item.id = input_row.row_id
    and row_item.import_id = p_import_id
    and row_item.company_id = v_company_id;

  get diagnostics v_updated_count = row_count;
  if v_updated_count <> v_input_count then
    raise exception using
      errcode = '23514',
      message = 'One or more packet review rows changed before saving.';
  end if;

  return jsonb_build_object(
    'updated_rows', v_updated_count,
    'status', 'review'
  );
end;
$$;


--
-- Name: upsert_leadership_employee_time(uuid, uuid, date, time without time zone, time without time zone, integer, uuid, text, boolean, text, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_leadership_employee_time(p_employee_id uuid, p_entry_id uuid DEFAULT NULL::uuid, p_work_date date DEFAULT NULL::date, p_start_time time without time zone DEFAULT NULL::time without time zone, p_stop_time time without time zone DEFAULT NULL::time without time zone, p_lunch_minutes integer DEFAULT 0, p_job_id uuid DEFAULT NULL::uuid, p_labor_code text DEFAULT NULL::text, p_per_diem boolean DEFAULT false, p_equipment_used text DEFAULT NULL::text, p_equipment_not_used boolean DEFAULT false, p_notes text DEFAULT NULL::text) RETURNS TABLE(entry_id uuid, regular_hours numeric, overtime_hours numeric)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_entry_id uuid;
  v_old_work_date date;
  v_labor_code text;
  v_start_at timestamp without time zone;
  v_stop_at timestamp without time zone;
  v_worked numeric;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role,'')), coalesce(profile.active,true)
    into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('gf','admin') then
    raise exception using errcode = '42501', message = 'Only an active General Foreman or Admin can enter time for another employee.';
  end if;

  if not exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = p_employee_id
      and employee.company_id = v_company_id
      and employee.active is true
  ) then
    raise exception using errcode = 'P0002', message = 'Choose an active employee from your company.';
  end if;

  if p_work_date is null or p_start_time is null or p_stop_time is null then
    raise exception using errcode = '22023', message = 'Work Date, Start, and Stop are required.';
  end if;

  if coalesce(p_lunch_minutes,0) < 0 or coalesce(p_lunch_minutes,0) > 720 then
    raise exception using errcode = '22023', message = 'Lunch must be between 0 and 720 minutes.';
  end if;

  v_start_at := p_work_date + p_start_time;
  v_stop_at := p_work_date + p_stop_time;
  if v_stop_at <= v_start_at then
    v_stop_at := v_stop_at + interval '1 day';
  end if;
  v_worked := round(((extract(epoch from (v_stop_at - v_start_at)) / 3600.0) - (coalesce(p_lunch_minutes,0) / 60.0))::numeric,2);

  if v_worked <= 0 or v_worked > 24 then
    raise exception using errcode = '22023', message = 'Start, Stop, and Lunch must produce a shift greater than 0 and no more than 24 hours.';
  end if;

  if p_job_id is not null then
    if not exists (
      select 1 from public.jobs job
      where job.id = p_job_id and job.company_id = v_company_id and job.active is true
    ) then
      raise exception using errcode = 'P0002', message = 'Choose an active job from your company.';
    end if;
    v_labor_code := null;
  else
    v_labor_code := nullif(btrim(coalesce(p_labor_code,'')),'');
    if v_labor_code not in ('Company Overhead','Administration','Travel','Training','Other') then
      raise exception using errcode = '22023', message = 'Choose a valid overhead labor code.';
    end if;
  end if;

  if p_entry_id is not null then
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.id = p_entry_id
      and entry.company_id = v_company_id
      and entry.employee_id = p_employee_id
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null;

    if v_entry_id is null then
      raise exception using errcode = 'P0002', message = 'The employee time entry was not found.';
    end if;
  else
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.company_id = v_company_id
      and entry.employee_id = p_employee_id
      and entry.work_date = p_work_date
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null
      and (
        (p_job_id is not null and entry.job_id = p_job_id)
        or
        (p_job_id is null and entry.job_id is null and lower(entry.labor_code) = lower(v_labor_code))
      )
    limit 1;
  end if;

  if v_entry_id is null then
    insert into public.timekeeping_entries(
      company_id, employee_id, daily_report_id, job_id, work_date, crew_name,
      regular_hours, overtime_hours, storm_work, notes, created_by, updated_by,
      start_time, stop_time, lunch_minutes, per_diem, equipment_used,
      equipment_not_used, entry_kind, labor_code
    ) values (
      v_company_id, p_employee_id, null, p_job_id, p_work_date, null,
      v_worked, 0, false, nullif(btrim(coalesce(p_notes,'')),''), auth.uid(), auth.uid(),
      p_start_time, p_stop_time, coalesce(p_lunch_minutes,0), coalesce(p_per_diem,false),
      case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
      coalesce(p_equipment_not_used,false), 'leadership_self', v_labor_code
    )
    returning id into v_entry_id;
  else
    update public.timekeeping_entries entry
       set job_id = p_job_id,
           work_date = p_work_date,
           crew_name = null,
           regular_hours = v_worked,
           overtime_hours = 0,
           storm_work = false,
           notes = nullif(btrim(coalesce(p_notes,'')),''),
           updated_by = auth.uid(),
           updated_at = now(),
           start_time = p_start_time,
           stop_time = p_stop_time,
           lunch_minutes = coalesce(p_lunch_minutes,0),
           per_diem = coalesce(p_per_diem,false),
           equipment_used = case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
           equipment_not_used = coalesce(p_equipment_not_used,false),
           labor_code = v_labor_code
     where entry.id = v_entry_id;
  end if;

  if v_old_work_date is not null and v_old_work_date is distinct from p_work_date then
    perform private.recalculate_leadership_week(v_company_id,p_employee_id,v_old_work_date,auth.uid());
  end if;
  perform private.recalculate_leadership_week(v_company_id,p_employee_id,p_work_date,auth.uid());

  return query
    select entry.id, entry.regular_hours, entry.overtime_hours
    from public.timekeeping_entries entry
    where entry.id = v_entry_id;
end;
$$;


--
-- Name: upsert_my_leadership_time(uuid, date, time without time zone, time without time zone, integer, uuid, text, boolean, text, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_my_leadership_time(p_entry_id uuid DEFAULT NULL::uuid, p_work_date date DEFAULT NULL::date, p_start_time time without time zone DEFAULT NULL::time without time zone, p_stop_time time without time zone DEFAULT NULL::time without time zone, p_lunch_minutes integer DEFAULT 0, p_job_id uuid DEFAULT NULL::uuid, p_labor_code text DEFAULT NULL::text, p_per_diem boolean DEFAULT false, p_equipment_used text DEFAULT NULL::text, p_equipment_not_used boolean DEFAULT false, p_notes text DEFAULT NULL::text) RETURNS TABLE(entry_id uuid, regular_hours numeric, overtime_hours numeric)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_employee_id uuid;
  v_entry_id uuid;
  v_old_work_date date;
  v_labor_code text;
  v_start_at timestamp without time zone;
  v_stop_at timestamp without time zone;
  v_worked numeric;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role,'')), coalesce(profile.active,true)
    into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true
     or v_role not in ('gf','superintendent','admin','owner') then
    raise exception using errcode = '42501', message = 'Only an active General Foreman, Superintendent, Admin, or Owner can submit My Time.';
  end if;

  select employee.id into v_employee_id
  from public.timekeeping_employees employee
  where employee.company_id = v_company_id
    and employee.linked_profile_id = auth.uid()
    and employee.active is true;

  if v_employee_id is null then
    raise exception using errcode = 'P0002', message = 'Your payroll employee record is not ready. Ask an Admin to refresh your profile.';
  end if;

  if p_work_date is null or p_start_time is null or p_stop_time is null then
    raise exception using errcode = '22023', message = 'Work Date, Start, and Stop are required.';
  end if;

  if coalesce(p_lunch_minutes,0) < 0 or coalesce(p_lunch_minutes,0) > 720 then
    raise exception using errcode = '22023', message = 'Lunch must be between 0 and 720 minutes.';
  end if;

  v_start_at := p_work_date + p_start_time;
  v_stop_at := p_work_date + p_stop_time;
  if v_stop_at <= v_start_at then
    v_stop_at := v_stop_at + interval '1 day';
  end if;
  v_worked := round(((extract(epoch from (v_stop_at - v_start_at)) / 3600.0) - (coalesce(p_lunch_minutes,0) / 60.0))::numeric,2);

  if v_worked <= 0 or v_worked > 24 then
    raise exception using errcode = '22023', message = 'Start, Stop, and Lunch must produce a shift greater than 0 and no more than 24 hours.';
  end if;

  if p_job_id is not null then
    if not exists (
      select 1 from public.jobs job
      where job.id = p_job_id and job.company_id = v_company_id and job.active is true
    ) then
      raise exception using errcode = 'P0002', message = 'Choose an active job from your company.';
    end if;
    v_labor_code := null;
  else
    v_labor_code := nullif(btrim(coalesce(p_labor_code,'')),'');
    if v_labor_code not in ('Company Overhead','Administration','Travel','Training','Other') then
      raise exception using errcode = '22023', message = 'Choose a valid overhead labor code.';
    end if;
  end if;

  if p_entry_id is not null then
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.id = p_entry_id
      and entry.company_id = v_company_id
      and entry.employee_id = v_employee_id
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null;

    if v_entry_id is null then
      raise exception using errcode = 'P0002', message = 'My Time entry was not found.';
    end if;
  else
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.company_id = v_company_id
      and entry.employee_id = v_employee_id
      and entry.work_date = p_work_date
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null
      and (
        (p_job_id is not null and entry.job_id = p_job_id)
        or
        (p_job_id is null and entry.job_id is null and lower(entry.labor_code) = lower(v_labor_code))
      )
    limit 1;
  end if;

  if v_entry_id is null then
    insert into public.timekeeping_entries(
      company_id, employee_id, daily_report_id, job_id, work_date, crew_name,
      regular_hours, overtime_hours, storm_work, notes, created_by, updated_by,
      start_time, stop_time, lunch_minutes, per_diem, equipment_used,
      equipment_not_used, entry_kind, labor_code
    ) values (
      v_company_id, v_employee_id, null, p_job_id, p_work_date, null,
      v_worked, 0, false, nullif(btrim(coalesce(p_notes,'')),''), auth.uid(), auth.uid(),
      p_start_time, p_stop_time, coalesce(p_lunch_minutes,0), coalesce(p_per_diem,false),
      case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
      coalesce(p_equipment_not_used,false), 'leadership_self', v_labor_code
    )
    returning id into v_entry_id;
  else
    update public.timekeeping_entries entry
       set job_id = p_job_id,
           work_date = p_work_date,
           crew_name = null,
           regular_hours = v_worked,
           overtime_hours = 0,
           storm_work = false,
           notes = nullif(btrim(coalesce(p_notes,'')),''),
           updated_by = auth.uid(),
           updated_at = now(),
           start_time = p_start_time,
           stop_time = p_stop_time,
           lunch_minutes = coalesce(p_lunch_minutes,0),
           per_diem = coalesce(p_per_diem,false),
           equipment_used = case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
           equipment_not_used = coalesce(p_equipment_not_used,false),
           labor_code = v_labor_code
     where entry.id = v_entry_id;
  end if;

  if v_old_work_date is not null and v_old_work_date is distinct from p_work_date then
    perform private.recalculate_leadership_week(v_company_id,v_employee_id,v_old_work_date,auth.uid());
  end if;
  perform private.recalculate_leadership_week(v_company_id,v_employee_id,p_work_date,auth.uid());

  return query
    select entry.id, entry.regular_hours, entry.overtime_hours
    from public.timekeeping_entries entry
    where entry.id = v_entry_id;
end;
$$;


--
-- Name: validate_job_package_import(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_job_package_import(p_package_id uuid, p_rows jsonb) RETURNS TABLE(row_number integer, is_valid boolean, error_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_job_id uuid;
  v_job_price_book_id uuid;
  v_price_book_id uuid;
  v_row jsonb;
  v_work_point text;
  v_unit_code text;
  v_error text;
  v_install numeric;
  v_transfer numeric;
  v_retirement numeric;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to validate job packet imports.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  select package.contract_id, package.job_id, job.price_book_id
  into v_contract_id, v_job_id, v_job_price_book_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.active is true
  where package.id = p_package_id
    and package.company_id = v_company_id
    and package.status in ('draft', 'active')
    and job.active is true;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'An editable utility package on an active company job is required.';
  end if;

  v_price_book_id := public.linecrew_resolve_job_price_book(
    v_company_id,
    v_job_id,
    v_contract_id
  );

  if v_price_book_id is null then
    if v_job_price_book_id is not null then
      raise exception using
        errcode = '22023',
        message = 'The job selected Price Book is not active for this contract.';
    else
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book is available for this job contract.';
    end if;
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 2000 then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := btrim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := btrim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);
    v_error := null;

    if v_work_point = '' then
      v_error := 'Missing work point';
    elsif v_unit_code = '' then
      v_error := 'Missing unit code';
    elsif v_install < 0 or v_transfer < 0 or v_retirement < 0
       or v_install + v_transfer + v_retirement <= 0 then
      v_error := 'Authorized quantity must be greater than zero';
    elsif not exists (
      select 1
      from public.price_book_items item
      where item.company_id = v_company_id
        and item.price_book_id = v_price_book_id
        and item.active is true
        and lower(btrim(item.item_code)) = lower(v_unit_code)
    ) then
      v_error := 'Unit code was not found in the selected job Price Book';
    end if;

    is_valid := v_error is null;
    error_message := v_error;
    return next;
  end loop;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using
      errcode = '22023',
      message = 'One or more quantities are not valid numbers.';
end;
$$;


--
-- Name: validate_timekeeping_employee_admin_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_timekeeping_employee_admin_assignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.assigned_admin_id is not null and not exists (
    select 1
    from public.profiles administrator
    where administrator.id = new.assigned_admin_id
      and administrator.company_id = new.company_id
      and administrator.active is true
      and lower(coalesce(administrator.role, '')) = 'admin'
  ) then
    raise exception using
      errcode = '23514',
      message = 'The assigned Admin must be an active Admin in this company.';
  end if;

  if tg_op = 'INSERT' then
    new.admin_assigned_by := case
      when new.assigned_admin_id is null then null
      else auth.uid()
    end;
    new.admin_assigned_at := case
      when new.assigned_admin_id is null then null
      else now()
    end;
  elsif new.assigned_admin_id is distinct from old.assigned_admin_id then
    new.admin_assigned_by := case
      when new.assigned_admin_id is null then null
      else auth.uid()
    end;
    new.admin_assigned_at := case
      when new.assigned_admin_id is null then null
      else now()
    end;
  end if;

  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: validate_timekeeping_employee_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_timekeeping_employee_assignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_actor_company uuid;
  v_actor_role text;
  v_trusted_profile_sync boolean := false;
begin
  if auth.uid() is null then
    if new.assigned_foreman_id is not null and not exists (
      select 1 from public.profiles foreman
      where foreman.id = new.assigned_foreman_id
        and foreman.company_id = new.company_id
        and foreman.active is true
        and lower(coalesce(foreman.role, '')) = 'foreman'
    ) then
      raise exception using errcode='23514',
        message='The assigned Foreman must be an active Foreman in this company.';
    end if;
    new.updated_at := now();
    return new;
  end if;

  select p.company_id, lower(coalesce(p.role, ''))
    into v_actor_company, v_actor_role
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  v_trusted_profile_sync :=
    current_setting('linecrew.profile_name_sync', true) = auth.uid()::text
    and v_actor_company is not null
    and new.company_id = v_actor_company
    and new.linked_profile_id = auth.uid()
    and (new.assigned_foreman_id is null or new.assigned_foreman_id = auth.uid());

  if v_trusted_profile_sync and (
    tg_op = 'INSERT'
    or (
      tg_op = 'UPDATE'
      and old.company_id = new.company_id
      and old.linked_profile_id = auth.uid()
    )
  ) then
    new.updated_at := now();
    return new;
  end if;

  if v_actor_company is null
     or v_actor_company <> new.company_id
     or v_actor_role not in ('owner', 'admin', 'gf') then
    raise exception using errcode='42501',
      message='Only an active Owner, Admin, or General Foreman can manage field employees.';
  end if;

  if new.assigned_foreman_id is not null and not exists (
    select 1
    from public.profiles foreman
    where foreman.id = new.assigned_foreman_id
      and foreman.company_id = new.company_id
      and foreman.active is true
      and lower(coalesce(foreman.role, '')) = 'foreman'
  ) then
    raise exception using errcode='23514',
      message='The assigned Foreman must be an active Foreman in this company.';
  end if;

  if tg_op = 'INSERT'
     or new.assigned_foreman_id is distinct from old.assigned_foreman_id then
    new.assigned_by := case when new.assigned_foreman_id is null then null else auth.uid() end;
    new.assigned_at := case when new.assigned_foreman_id is null then null else now() end;
  end if;

  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: app_error_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_error_events (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    user_id uuid,
    area text NOT NULL,
    error_code text NOT NULL,
    page text NOT NULL,
    safe_message text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_error_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.app_error_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.app_error_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assistant_memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assistant_memories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid,
    memory_type text NOT NULL,
    title text NOT NULL,
    instruction text NOT NULL,
    trigger_type text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_by uuid,
    completed_at timestamp with time zone,
    removed_by uuid,
    removed_at timestamp with time zone,
    CONSTRAINT assistant_memories_instruction_check CHECK (((char_length(instruction) >= 1) AND (char_length(instruction) <= 800))),
    CONSTRAINT assistant_memories_memory_type_check CHECK ((memory_type = ANY (ARRAY['company_workflow'::text, 'job_reminder'::text]))),
    CONSTRAINT assistant_memories_title_check CHECK (((char_length(title) >= 1) AND (char_length(title) <= 160))),
    CONSTRAINT assistant_memories_trigger_type_check CHECK ((trigger_type = ANY (ARRAY['always'::text, 'job_open'::text, 'production_review'::text, 'final_billing'::text, 'timekeeping'::text, 'billing'::text, 'manual'::text]))),
    CONSTRAINT assistant_memory_job_scope CHECK ((((memory_type = 'job_reminder'::text) AND (job_id IS NOT NULL)) OR ((memory_type = 'company_workflow'::text) AND (job_id IS NULL)))),
    CONSTRAINT assistant_memory_terminal_state CHECK ((NOT ((completed_at IS NOT NULL) AND (removed_at IS NOT NULL))))
);


--
-- Name: TABLE assistant_memories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.assistant_memories IS 'Owner/Admin-confirmed workflow notes and advisory job reminders; never operational job, report, timekeeping, or billing mutations.';


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    user_id uuid,
    action text NOT NULL,
    table_name text NOT NULL,
    record_id uuid,
    old_data jsonb,
    new_data jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: beta_applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.beta_applications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_name text NOT NULL,
    contact_name text NOT NULL,
    email text NOT NULL,
    phone text,
    active_crew_count integer NOT NULL,
    testing_notes text,
    status text DEFAULT 'pending'::text NOT NULL,
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    reviewed_at timestamp with time zone,
    reviewed_by uuid,
    approved_company_id uuid,
    invite_sent_at timestamp with time zone,
    request_fingerprint_hash text,
    source text DEFAULT 'website'::text NOT NULL,
    CONSTRAINT beta_applications_company_name_len CHECK (((char_length(btrim(company_name)) >= 2) AND (char_length(btrim(company_name)) <= 120))),
    CONSTRAINT beta_applications_contact_name_len CHECK (((char_length(btrim(contact_name)) >= 2) AND (char_length(btrim(contact_name)) <= 120))),
    CONSTRAINT beta_applications_crew_count CHECK (((active_crew_count >= 1) AND (active_crew_count <= 500))),
    CONSTRAINT beta_applications_email_len CHECK (((char_length(btrim(email)) >= 5) AND (char_length(btrim(email)) <= 254))),
    CONSTRAINT beta_applications_fingerprint CHECK (((request_fingerprint_hash IS NULL) OR (request_fingerprint_hash ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT beta_applications_notes_len CHECK (((testing_notes IS NULL) OR (char_length(testing_notes) <= 2000))),
    CONSTRAINT beta_applications_phone_len CHECK (((phone IS NULL) OR ((char_length(btrim(phone)) >= 7) AND (char_length(btrim(phone)) <= 30)))),
    CONSTRAINT beta_applications_status CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'declined'::text])))
);


--
-- Name: billing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    provider text DEFAULT 'stripe'::text NOT NULL,
    provider_event_id text,
    event_type text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    processed_at timestamp with time zone,
    error_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: billing_export_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_export_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    billing_batch_id uuid NOT NULL,
    storage_path text NOT NULL,
    original_filename text NOT NULL,
    mime_type text,
    file_size_bytes bigint DEFAULT 0 NOT NULL,
    caption text,
    uploaded_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: billing_export_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_export_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid NOT NULL,
    batch_number text NOT NULL,
    date_from date,
    date_to date,
    include_redlines boolean DEFAULT false NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    authorized_line_count integer DEFAULT 0 NOT NULL,
    redline_line_count integer DEFAULT 0 NOT NULL,
    total_value numeric(14,2) DEFAULT 0 NOT NULL,
    notes text,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    exported_at timestamp with time zone,
    submitted_at timestamp with time zone,
    paid_at timestamp with time zone,
    voided_at timestamp with time zone,
    billing_type text DEFAULT 'partial'::text NOT NULL,
    billing_sequence integer DEFAULT 1 NOT NULL,
    utility_invoice_number text,
    payment_reference text,
    correction_reason text,
    final_override_reason text,
    parent_batch_id uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    archived_at timestamp with time zone,
    archived_by uuid,
    CONSTRAINT billing_export_batches_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'exported'::text, 'submitted'::text, 'paid'::text, 'void'::text]))),
    CONSTRAINT billing_export_batches_type_check CHECK ((billing_type = ANY (ARRAY['partial'::text, 'final'::text, 'credit'::text])))
);


--
-- Name: COLUMN billing_export_batches.include_redlines; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.billing_export_batches.include_redlines IS 'True when exports should add a separate redline summary. Approved redlines are always included in the main billing production.';


--
-- Name: billing_export_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_export_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    billing_batch_id uuid NOT NULL,
    job_id uuid NOT NULL,
    daily_report_id uuid NOT NULL,
    production_location_id uuid NOT NULL,
    report_date date NOT NULL,
    foreman_name text,
    crew_name text,
    work_point text NOT NULL,
    price_book_item_id uuid NOT NULL,
    unit_code text NOT NULL,
    unit_name text,
    unit_description text,
    work_type text NOT NULL,
    quantity numeric(14,2) NOT NULL,
    unit_price numeric(14,2) DEFAULT 0 NOT NULL,
    extended_value numeric(14,2) DEFAULT 0 NOT NULL,
    authorization_status text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT billing_export_lines_authorization_status_check CHECK ((authorization_status = ANY (ARRAY['authorized'::text, 'redline'::text]))),
    CONSTRAINT billing_export_lines_quantity_check CHECK ((quantity > (0)::numeric)),
    CONSTRAINT billing_export_lines_work_type_check CHECK ((work_type = ANY (ARRAY['INSTALL'::text, 'REMOVE'::text, 'TRANSFER'::text])))
);


--
-- Name: companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.companies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    join_code text DEFAULT upper(substr(replace((gen_random_uuid())::text, '-'::text, ''::text), 1, 16)) NOT NULL,
    created_by uuid,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    require_gf_redline_approval boolean DEFAULT false NOT NULL,
    contact_email text,
    contact_phone text,
    logo_url text,
    primary_color text DEFAULT '#0b2d4d'::text NOT NULL,
    timezone text DEFAULT 'America/Chicago'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    storm_mode_enabled boolean DEFAULT false NOT NULL,
    storm_event_name text,
    storm_started_at timestamp with time zone,
    storm_ended_at timestamp with time zone,
    jsa_method text DEFAULT 'both'::text NOT NULL,
    subscription_status text DEFAULT 'trial'::text NOT NULL,
    subscription_expires_at timestamp with time zone,
    required_man_hour_rate numeric(12,2),
    week_start_day smallint DEFAULT 1 NOT NULL,
    CONSTRAINT companies_jsa_method_supported CHECK ((jsa_method = ANY (ARRAY['digital'::text, 'upload'::text, 'both'::text]))),
    CONSTRAINT companies_primary_color_format CHECK ((primary_color ~ '^#[0-9A-Fa-f]{6}$'::text)),
    CONSTRAINT companies_required_man_hour_rate_valid CHECK (((required_man_hour_rate IS NULL) OR ((required_man_hour_rate >= 0.01) AND (required_man_hour_rate <= (1000000)::numeric)))),
    CONSTRAINT companies_subscription_status_supported CHECK ((subscription_status = ANY (ARRAY['trial'::text, 'active'::text, 'internal'::text, 'past_due'::text, 'suspended'::text, 'cancelled'::text]))),
    CONSTRAINT companies_week_start_day_check CHECK (((week_start_day >= 0) AND (week_start_day <= 6)))
);


--
-- Name: company_crew_usage_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_crew_usage_daily (
    company_id uuid NOT NULL,
    usage_date date NOT NULL,
    peak_active_crews integer DEFAULT 0 NOT NULL,
    storm_crews integer DEFAULT 0 NOT NULL,
    billable_peak_crews integer GENERATED ALWAYS AS (GREATEST((peak_active_crews - storm_crews), 0)) STORED,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    peak_billable_crews integer DEFAULT 0 NOT NULL,
    CONSTRAINT company_crew_usage_daily_peak_active_crews_check CHECK ((peak_active_crews >= 0)),
    CONSTRAINT company_crew_usage_daily_peak_billable_crews_check CHECK ((peak_billable_crews >= 0)),
    CONSTRAINT company_crew_usage_daily_storm_crews_check CHECK ((storm_crews >= 0))
);


--
-- Name: TABLE company_crew_usage_daily; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.company_crew_usage_daily IS 'One row per company/calendar day. Overage uses peak non-storm active crews. Rolling allowance is six over-limit crew-days in the latest 30 days; taking crews off does not reset prior usage.';


--
-- Name: COLUMN company_crew_usage_daily.storm_crews; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.company_crew_usage_daily.storm_crews IS 'Crews explicitly designated for Storm Mode that day; excluded from normal subscription crew overage calculations.';


--
-- Name: company_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    display_name text,
    logo_url text,
    primary_color text DEFAULT '#0b2d4d'::text,
    secondary_color text DEFAULT '#1677d2'::text,
    adjustment_enabled boolean DEFAULT false NOT NULL,
    adjustment_percent numeric(8,4) DEFAULT 0 NOT NULL,
    adjustment_label text DEFAULT 'Adjustment'::text,
    show_original_pricing boolean DEFAULT true NOT NULL,
    gf_can_edit_reports boolean DEFAULT true NOT NULL,
    gf_can_delete_reports boolean DEFAULT true NOT NULL,
    pole_label text DEFAULT 'Pole / Location'::text NOT NULL,
    job_label text DEFAULT 'Job'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: contract_field_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_field_settings (
    contract_id uuid NOT NULL,
    company_id uuid NOT NULL,
    field_value_percent numeric(5,2) NOT NULL,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contract_field_value_percent_range CHECK (((field_value_percent >= (0)::numeric) AND (field_value_percent <= (100)::numeric)))
);


--
-- Name: contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contracts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    contract_name text NOT NULL,
    contract_number text,
    pay_item_label text DEFAULT 'Pay Item'::text NOT NULL,
    start_date date,
    end_date date,
    notes text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: crews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.crews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    foreman_id uuid,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    customer_type text,
    account_number text,
    contact_name text,
    contact_email text,
    contact_phone text,
    notes text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: daily_production_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_production_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    daily_report_id uuid NOT NULL,
    job_id uuid NOT NULL,
    work_point_id uuid,
    price_book_item_id uuid,
    action_type text NOT NULL,
    quantity numeric(12,3) DEFAULT 1 NOT NULL,
    item_code_snapshot text,
    item_name_snapshot text NOT NULL,
    description_snapshot text,
    unit_price_snapshot numeric(12,2) DEFAULT 0 NOT NULL,
    extended_value numeric(14,2) GENERATED ALWAYS AS (round((quantity * unit_price_snapshot), 2)) STORED,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT daily_production_items_action_type_check CHECK ((lower(action_type) = ANY (ARRAY['install'::text, 'retire'::text])))
);


--
-- Name: daily_production_unit_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_production_unit_locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    daily_report_id uuid NOT NULL,
    daily_production_unit_id uuid NOT NULL,
    price_book_item_id uuid NOT NULL,
    pole_location text NOT NULL,
    pole_location_key text GENERATED ALWAYS AS (lower(btrim(pole_location))) STORED,
    install_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    retirement_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    transfer_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT daily_production_unit_locations_has_quantity CHECK (((install_quantity > (0)::numeric) OR (transfer_quantity > (0)::numeric) OR (retirement_quantity > (0)::numeric))),
    CONSTRAINT daily_production_unit_locations_location_not_blank CHECK ((length(btrim(pole_location)) > 0)),
    CONSTRAINT daily_production_unit_locations_nonnegative CHECK (((install_quantity >= (0)::numeric) AND (transfer_quantity >= (0)::numeric) AND (retirement_quantity >= (0)::numeric)))
);


--
-- Name: daily_production_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_production_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    daily_report_id uuid NOT NULL,
    job_id uuid NOT NULL,
    contract_id uuid NOT NULL,
    price_book_id uuid NOT NULL,
    price_book_item_id uuid NOT NULL,
    item_code text NOT NULL,
    item_name text,
    description text,
    unit_of_measure text,
    category text,
    install_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    retirement_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    actual_install_price numeric(14,2) NOT NULL,
    actual_retirement_price numeric(14,2) NOT NULL,
    adjusted_install_price numeric(14,2) NOT NULL,
    adjusted_retirement_price numeric(14,2) NOT NULL,
    field_value_percent_snapshot numeric(5,2) NOT NULL,
    has_adjustment boolean DEFAULT false NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    actual_transfer_price numeric(14,2) NOT NULL,
    adjusted_transfer_price numeric(14,2) NOT NULL,
    CONSTRAINT daily_production_units_has_quantity CHECK (((install_quantity > (0)::numeric) OR (retirement_quantity > (0)::numeric))),
    CONSTRAINT daily_production_units_nonnegative_quantities CHECK (((install_quantity >= (0)::numeric) AND (retirement_quantity >= (0)::numeric)))
);


--
-- Name: daily_report_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_report_audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    daily_report_id uuid NOT NULL,
    event_type text NOT NULL,
    actor_id uuid,
    actor_name text,
    actor_role text,
    event_notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT daily_report_audit_events_event_type_check CHECK ((event_type = ANY (ARRAY['created'::text, 'submitted'::text, 'returned'::text, 'approved'::text, 'archived'::text, 'restored'::text, 'foreman_correction'::text])))
);


--
-- Name: daily_report_jsas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_report_jsas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    daily_report_id uuid,
    job_id uuid NOT NULL,
    created_by uuid NOT NULL,
    work_date date NOT NULL,
    crew_name text,
    job_briefing text NOT NULL,
    hazards text NOT NULL,
    controls text NOT NULL,
    ppe text NOT NULL,
    emergency_plan text NOT NULL,
    weather_conditions text,
    special_equipment text,
    crew_members text NOT NULL,
    foreman_acknowledged boolean DEFAULT false NOT NULL,
    acknowledged_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    jsa_source text DEFAULT 'digital'::text NOT NULL,
    upload_notes text,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    client_submission_id uuid,
    CONSTRAINT daily_report_jsas_controls_not_blank CHECK ((length(TRIM(BOTH FROM controls)) > 0)),
    CONSTRAINT daily_report_jsas_crew_members_not_blank CHECK ((length(TRIM(BOTH FROM crew_members)) > 0)),
    CONSTRAINT daily_report_jsas_emergency_plan_not_blank CHECK ((length(TRIM(BOTH FROM emergency_plan)) > 0)),
    CONSTRAINT daily_report_jsas_hazards_not_blank CHECK ((length(TRIM(BOTH FROM hazards)) > 0)),
    CONSTRAINT daily_report_jsas_job_briefing_not_blank CHECK ((length(TRIM(BOTH FROM job_briefing)) > 0)),
    CONSTRAINT daily_report_jsas_ppe_not_blank CHECK ((length(TRIM(BOTH FROM ppe)) > 0)),
    CONSTRAINT daily_report_jsas_source_supported CHECK ((jsa_source = ANY (ARRAY['digital'::text, 'upload'::text])))
);


--
-- Name: daily_report_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_report_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    report_id uuid NOT NULL,
    job_id uuid NOT NULL,
    work_point text,
    unit_code text NOT NULL,
    description text,
    installed_qty numeric(12,2) DEFAULT 0 NOT NULL,
    retired_qty numeric(12,2) DEFAULT 0 NOT NULL,
    install_unit_price numeric(14,2),
    retire_unit_price numeric(14,2),
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: daily_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid NOT NULL,
    crew_id uuid,
    foreman_id uuid NOT NULL,
    report_date date NOT NULL,
    crew_size numeric(8,2) DEFAULT 0 NOT NULL,
    hours numeric(8,2) DEFAULT 0 NOT NULL,
    unit_revenue numeric(14,2) DEFAULT 0 NOT NULL,
    adjusted_revenue numeric(14,2) DEFAULT 0 NOT NULL,
    manhour_revenue numeric(14,2) DEFAULT 0 NOT NULL,
    crewhour_revenue numeric(14,2) DEFAULT 0 NOT NULL,
    notes text,
    status text DEFAULT 'draft'::text NOT NULL,
    approved_by uuid,
    approved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    work_date date DEFAULT CURRENT_DATE,
    foreman_name text,
    crew_name text,
    regular_hours numeric(8,2) DEFAULT 0,
    overtime_hours numeric(8,2) DEFAULT 0,
    submitted_at timestamp with time zone,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    review_notes text,
    created_by uuid DEFAULT auth.uid(),
    price_book_id uuid,
    field_value_percent_snapshot numeric(5,2),
    has_field_adjustment boolean,
    archived boolean DEFAULT false NOT NULL,
    redline_override_by uuid,
    redline_override_reason text,
    redline_override_at timestamp with time zone,
    weather_conditions text,
    delay_hours numeric(8,2) DEFAULT 0 NOT NULL,
    delay_reason text,
    storm_mode boolean DEFAULT false NOT NULL,
    storm_event_name text,
    CONSTRAINT daily_reports_delay_hours_nonnegative CHECK ((delay_hours >= (0)::numeric)),
    CONSTRAINT daily_reports_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'submitted'::text, 'approved'::text, 'rejected'::text])))
);


--
-- Name: employees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employees (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    crew_id uuid,
    employee_number text,
    full_name text NOT NULL,
    classification text,
    hourly_cost numeric(12,2),
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: gf_foreman_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gf_foreman_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    gf_id uuid NOT NULL,
    foreman_id uuid NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: job_assignment_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_assignment_audit_events (
    id bigint NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid,
    member_id uuid,
    actor_id uuid,
    action text NOT NULL,
    job_number text NOT NULL,
    member_name text NOT NULL,
    actor_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT job_assignment_audit_events_action_check CHECK ((action = ANY (ARRAY['assigned'::text, 'unassigned'::text])))
);


--
-- Name: job_assignment_audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.job_assignment_audit_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.job_assignment_audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: job_closeout_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_closeout_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid NOT NULL,
    action text NOT NULL,
    reason text,
    blockers jsonb DEFAULT '{}'::jsonb NOT NULL,
    actor_id uuid NOT NULL,
    actor_role text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT job_closeout_history_action_check CHECK ((action = ANY (ARRAY['closed'::text, 'override_closed'::text, 'reopened'::text])))
);


--
-- Name: TABLE job_closeout_history; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.job_closeout_history IS 'Append-only audit trail for every job close, unresolved-work override close, and reopen.';


--
-- Name: COLUMN job_closeout_history.blockers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.job_closeout_history.blockers IS 'Immutable closeout snapshot: paid Final Bill state plus unbilled and pending report counts.';


--
-- Name: job_leader_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_leader_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid NOT NULL,
    member_id uuid NOT NULL,
    assigned_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: job_package_authorized_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_package_authorized_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_package_id uuid NOT NULL,
    work_point_id uuid NOT NULL,
    price_book_item_id uuid NOT NULL,
    unit_code text NOT NULL,
    authorized_install_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    authorized_retirement_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    authorized_transfer_quantity numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT job_package_authorized_units_has_quantity CHECK (((authorized_install_quantity > (0)::numeric) OR (authorized_transfer_quantity > (0)::numeric) OR (authorized_retirement_quantity > (0)::numeric))),
    CONSTRAINT job_package_authorized_units_nonnegative CHECK (((authorized_install_quantity >= (0)::numeric) AND (authorized_transfer_quantity >= (0)::numeric) AND (authorized_retirement_quantity >= (0)::numeric)))
);


--
-- Name: job_package_work_points; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_package_work_points (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_package_id uuid NOT NULL,
    job_id uuid NOT NULL,
    work_point_code text NOT NULL,
    work_point_key text GENERATED ALWAYS AS (lower(TRIM(BOTH FROM work_point_code))) STORED,
    description text,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT job_package_work_points_code_not_blank CHECK ((length(TRIM(BOTH FROM work_point_code)) > 0))
);


--
-- Name: job_packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid NOT NULL,
    contract_id uuid NOT NULL,
    package_name text NOT NULL,
    package_number text,
    received_date date,
    source_filename text,
    notes text,
    status text DEFAULT 'draft'::text NOT NULL,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    revision_number integer DEFAULT 1 NOT NULL,
    supersedes_package_id uuid,
    CONSTRAINT job_packages_name_not_blank CHECK ((length(TRIM(BOTH FROM package_name)) > 0)),
    CONSTRAINT job_packages_status_supported CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'closed'::text])))
);


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_number text NOT NULL,
    job_name text,
    customer_name text,
    utility_name text,
    active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    customer_id uuid,
    contract_id uuid,
    price_book_id uuid,
    closeout_status text DEFAULT 'open'::text NOT NULL,
    closeout_notes text,
    closed_by uuid,
    reopened_at timestamp with time zone,
    reopened_by uuid
);


--
-- Name: jsa_upload_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jsa_upload_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    jsa_id uuid NOT NULL,
    storage_path text NOT NULL,
    original_filename text NOT NULL,
    mime_type text NOT NULL,
    file_size_bytes bigint NOT NULL,
    page_order integer DEFAULT 1 NOT NULL,
    uploaded_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pilot_feedback; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pilot_feedback (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    submitted_by uuid NOT NULL,
    category text NOT NULL,
    rating smallint NOT NULL,
    message text NOT NULL,
    page text DEFAULT 'app'::text NOT NULL,
    contact_ok boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    resolved_by uuid,
    CONSTRAINT pilot_feedback_category_supported CHECK ((category = ANY (ARRAY['bug'::text, 'idea'::text, 'question'::text, 'other'::text]))),
    CONSTRAINT pilot_feedback_message_length CHECK (((char_length(message) >= 10) AND (char_length(message) <= 2000))),
    CONSTRAINT pilot_feedback_rating_supported CHECK (((rating >= 1) AND (rating <= 5)))
);


--
-- Name: platform_owner_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_owner_audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_user_id uuid,
    company_id uuid,
    action text NOT NULL,
    before_state jsonb,
    after_state jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: platform_owners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_owners (
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid
);


--
-- Name: platform_support_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_support_users (
    user_id uuid NOT NULL,
    active boolean DEFAULT true NOT NULL,
    display_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: price_book_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_book_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    price_book_id uuid NOT NULL,
    item_code text,
    item_name text NOT NULL,
    description text,
    install_price numeric(12,2),
    retirement_price numeric(12,2),
    unit_of_measure text,
    category text,
    extra_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    transfer_price numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT price_book_items_transfer_price_nonnegative CHECK ((transfer_price >= (0)::numeric))
);


--
-- Name: price_books; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_books (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    customer_name text,
    utility_name text,
    effective_date date,
    active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    contract_id uuid,
    version_name text,
    effective_start date,
    effective_end date,
    source_filename text,
    notes text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    company_id uuid NOT NULL,
    full_name text NOT NULL,
    role text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    role_permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT profiles_role_supported CHECK ((lower(role) = ANY (ARRAY['foreman'::text, 'gf'::text, 'superintendent'::text, 'admin'::text, 'owner'::text])))
);


--
-- Name: report_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.report_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    report_id uuid NOT NULL,
    pole_location text NOT NULL,
    unit text NOT NULL,
    action text NOT NULL,
    quantity numeric(12,2) NOT NULL,
    rate numeric(14,2) NOT NULL,
    amount numeric(14,2) NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT report_units_action_check CHECK ((action = ANY (ARRAY['install'::text, 'remove'::text, 'transfer'::text])))
);


--
-- Name: storm_mode_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.storm_mode_assignments (
    company_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: support_access_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_access_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    support_user_id uuid NOT NULL,
    company_id uuid NOT NULL,
    reason text NOT NULL,
    requested_minutes integer DEFAULT 30 NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    approved_by uuid,
    approved_at timestamp with time zone,
    expires_at timestamp with time zone,
    revoked_by uuid,
    revoked_at timestamp with time zone,
    CONSTRAINT support_access_requests_reason_check CHECK (((char_length(TRIM(BOTH FROM reason)) >= 10) AND (char_length(TRIM(BOTH FROM reason)) <= 500))),
    CONSTRAINT support_access_requests_requested_minutes_check CHECK (((requested_minutes >= 5) AND (requested_minutes <= 60))),
    CONSTRAINT support_access_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'revoked'::text, 'expired'::text])))
);


--
-- Name: support_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_audit_events (
    id bigint NOT NULL,
    request_id uuid,
    company_id uuid,
    actor_id uuid NOT NULL,
    event_type text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: support_audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.support_audit_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.support_audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: team_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_invitations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    email text NOT NULL,
    token_hash text NOT NULL,
    invited_by uuid,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    accepted_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    intended_role text DEFAULT 'foreman'::text NOT NULL,
    intended_full_name text,
    CONSTRAINT team_invitations_email_present CHECK (((length(btrim(email)) >= 3) AND (length(btrim(email)) <= 254))),
    CONSTRAINT team_invitations_intended_role_check CHECK ((lower(intended_role) = ANY (ARRAY['foreman'::text, 'gf'::text, 'superintendent'::text, 'admin'::text, 'owner'::text]))),
    CONSTRAINT team_invitations_token_hash_sha256 CHECK ((token_hash ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: timekeeping_edit_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_edit_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    timekeeping_entry_id uuid NOT NULL,
    daily_report_id uuid,
    employee_id uuid NOT NULL,
    work_date date NOT NULL,
    edited_by uuid NOT NULL,
    reason text,
    before_values jsonb NOT NULL,
    after_values jsonb NOT NULL,
    edited_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: timekeeping_employees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_employees (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    employee_number text,
    full_name text NOT NULL,
    classification text,
    default_crew_name text,
    active boolean DEFAULT true NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_foreman_id uuid,
    assigned_by uuid,
    assigned_at timestamp with time zone,
    default_equipment text,
    linked_profile_id uuid,
    assigned_admin_id uuid,
    admin_assigned_by uuid,
    admin_assigned_at timestamp with time zone
);


--
-- Name: timekeeping_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    daily_report_id uuid,
    job_id uuid,
    work_date date NOT NULL,
    crew_name text,
    regular_hours numeric(6,2) DEFAULT 0 NOT NULL,
    overtime_hours numeric(6,2) DEFAULT 0 NOT NULL,
    storm_work boolean DEFAULT false NOT NULL,
    notes text,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    updated_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    start_time time without time zone,
    stop_time time without time zone,
    lunch_minutes integer DEFAULT 0 NOT NULL,
    per_diem boolean DEFAULT false NOT NULL,
    equipment_used text,
    equipment_not_used boolean DEFAULT false NOT NULL,
    entry_kind text DEFAULT 'crew'::text NOT NULL,
    labor_code text,
    CONSTRAINT timekeeping_entries_charge_check CHECK ((((entry_kind = 'crew'::text) AND (job_id IS NOT NULL)) OR ((entry_kind = 'leadership_self'::text) AND ((job_id IS NOT NULL) OR (NULLIF(btrim(COALESCE(labor_code, ''::text)), ''::text) IS NOT NULL))))),
    CONSTRAINT timekeeping_entries_entry_kind_check CHECK ((entry_kind = ANY (ARRAY['crew'::text, 'leadership_self'::text]))),
    CONSTRAINT timekeeping_entries_lunch_minutes_check CHECK (((lunch_minutes >= 0) AND (lunch_minutes <= 720))),
    CONSTRAINT timekeeping_entries_overtime_hours_check CHECK (((overtime_hours >= (0)::numeric) AND (overtime_hours <= (24)::numeric))),
    CONSTRAINT timekeeping_entries_regular_hours_check CHECK (((regular_hours >= (0)::numeric) AND (regular_hours <= (24)::numeric))),
    CONSTRAINT timekeeping_entry_hours_check CHECK (((regular_hours + overtime_hours) <= (24)::numeric))
);


--
-- Name: timekeeping_entry_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_entry_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_entry_id uuid NOT NULL,
    company_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    daily_report_id uuid,
    job_id uuid NOT NULL,
    work_date date NOT NULL,
    crew_name text,
    regular_hours numeric DEFAULT 0 NOT NULL,
    overtime_hours numeric DEFAULT 0 NOT NULL,
    storm_work boolean DEFAULT false NOT NULL,
    notes text,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    archived_at timestamp with time zone DEFAULT now() NOT NULL,
    start_time time without time zone,
    stop_time time without time zone,
    lunch_minutes integer DEFAULT 0 NOT NULL,
    per_diem boolean DEFAULT false NOT NULL,
    equipment_used text,
    equipment_not_used boolean DEFAULT false NOT NULL,
    CONSTRAINT timekeeping_entry_history_check CHECK (((regular_hours + overtime_hours) <= (24)::numeric)),
    CONSTRAINT timekeeping_entry_history_lunch_minutes_check CHECK (((lunch_minutes >= 0) AND (lunch_minutes <= 720))),
    CONSTRAINT timekeeping_entry_history_overtime_hours_check CHECK (((overtime_hours >= (0)::numeric) AND (overtime_hours <= (24)::numeric))),
    CONSTRAINT timekeeping_entry_history_regular_hours_check CHECK (((regular_hours >= (0)::numeric) AND (regular_hours <= (24)::numeric)))
);


--
-- Name: timekeeping_equipment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_equipment (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    unit_number text NOT NULL,
    description text,
    active boolean DEFAULT true NOT NULL,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: timekeeping_pay_period_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_pay_period_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    action text NOT NULL,
    actor_id uuid,
    detail text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: timekeeping_pay_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timekeeping_pay_periods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    approved_by uuid,
    approved_at timestamp with time zone,
    locked_by uuid,
    locked_at timestamp with time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT timekeeping_pay_period_dates_check CHECK ((period_end >= period_start)),
    CONSTRAINT timekeeping_pay_periods_status_check CHECK ((status = ANY (ARRAY['open'::text, 'approved'::text, 'locked'::text])))
);


--
-- Name: training_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.training_progress (
    company_id uuid NOT NULL,
    user_id uuid NOT NULL,
    video_id uuid NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_position_seconds integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: training_videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.training_videos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    title text NOT NULL,
    description text,
    category text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    storage_path text NOT NULL,
    duration_seconds integer,
    minimum_role text DEFAULT 'foreman'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT training_video_role_supported CHECK ((minimum_role = ANY (ARRAY['foreman'::text, 'gf'::text, 'superintendent'::text, 'admin'::text, 'owner'::text])))
);


--
-- Name: unit_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unit_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    price_book_id uuid,
    unit text NOT NULL,
    description text,
    install numeric(14,2),
    remove numeric(14,2),
    transfer numeric(14,2),
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_dashboard_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_dashboard_preferences (
    user_id uuid NOT NULL,
    company_id uuid NOT NULL,
    tile_order text[] DEFAULT '{}'::text[] NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_dashboard_preferences_tile_limit CHECK ((cardinality(tile_order) <= 32))
);


--
-- Name: TABLE user_dashboard_preferences; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_dashboard_preferences IS 'Per-account dashboard card order for active company Admin and Owner users.';


--
-- Name: utility_packet_import_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.utility_packet_import_rows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    import_id uuid NOT NULL,
    source_page integer,
    source_row integer NOT NULL,
    work_point_code text NOT NULL,
    work_point_description text,
    work_type text NOT NULL,
    material_cu text,
    contractor_unit_code text,
    estimated_quantity numeric(12,2) NOT NULL,
    description text,
    confidence numeric(5,4),
    include_in_import boolean DEFAULT true NOT NULL,
    review_note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT utility_packet_import_rows_confidence_check CHECK (((confidence IS NULL) OR ((confidence >= (0)::numeric) AND (confidence <= (1)::numeric)))),
    CONSTRAINT utility_packet_import_rows_quantity_check CHECK ((estimated_quantity > (0)::numeric)),
    CONSTRAINT utility_packet_import_rows_type_check CHECK ((work_type = ANY (ARRAY['install'::text, 'transfer'::text, 'remove'::text])))
);


--
-- Name: utility_packet_imports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.utility_packet_imports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_package_id uuid NOT NULL,
    provider_key text NOT NULL,
    format_key text NOT NULL,
    profile_version text NOT NULL,
    source_filename text NOT NULL,
    source_sha256 text NOT NULL,
    detected_work_order text,
    extraction_confidence numeric(5,4),
    status text DEFAULT 'review'::text NOT NULL,
    extraction_summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    reviewed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reviewed_at timestamp with time zone,
    CONSTRAINT utility_packet_imports_confidence_check CHECK (((extraction_confidence IS NULL) OR ((extraction_confidence >= (0)::numeric) AND (extraction_confidence <= (1)::numeric)))),
    CONSTRAINT utility_packet_imports_status_check CHECK ((status = ANY (ARRAY['review'::text, 'imported'::text, 'cancelled'::text, 'failed'::text])))
);


--
-- Name: utility_packet_unit_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.utility_packet_unit_aliases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    contract_id uuid NOT NULL,
    packet_code text NOT NULL,
    normalized_code text NOT NULL,
    target_item_code text NOT NULL,
    normalized_target text NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT utility_packet_unit_aliases_normalized_check CHECK (((normalized_code ~ '^[A-Z0-9]+$'::text) AND (normalized_target ~ '^[A-Z0-9]+$'::text))),
    CONSTRAINT utility_packet_unit_aliases_packet_code_check CHECK ((btrim(packet_code) <> ''::text)),
    CONSTRAINT utility_packet_unit_aliases_target_code_check CHECK ((btrim(target_item_code) <> ''::text))
);


--
-- Name: TABLE utility_packet_unit_aliases; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.utility_packet_unit_aliases IS 'Maps a utility packet''s own unit code to a contract Price Book unit code. Scoped to one contract so each utility keeps its own vocabulary. Resolved by code, not id, so a Price Book revision does not break existing mappings.';


--
-- Name: work_points; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_points (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid NOT NULL,
    job_id uuid NOT NULL,
    work_point_number text NOT NULL,
    description text,
    latitude numeric,
    longitude numeric,
    notes text,
    active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_error_events app_error_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_error_events
    ADD CONSTRAINT app_error_events_pkey PRIMARY KEY (id);


--
-- Name: assistant_memories assistant_memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_memories
    ADD CONSTRAINT assistant_memories_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: beta_applications beta_applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beta_applications
    ADD CONSTRAINT beta_applications_pkey PRIMARY KEY (id);


--
-- Name: billing_events billing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_pkey PRIMARY KEY (id);


--
-- Name: billing_events billing_events_provider_event_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_provider_event_id_key UNIQUE (provider_event_id);


--
-- Name: billing_export_attachments billing_export_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_attachments
    ADD CONSTRAINT billing_export_attachments_pkey PRIMARY KEY (id);


--
-- Name: billing_export_attachments billing_export_attachments_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_attachments
    ADD CONSTRAINT billing_export_attachments_storage_path_key UNIQUE (storage_path);


--
-- Name: billing_export_batches billing_export_batches_company_id_batch_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_company_id_batch_number_key UNIQUE (company_id, batch_number);


--
-- Name: billing_export_batches billing_export_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_pkey PRIMARY KEY (id);


--
-- Name: billing_export_lines billing_export_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_pkey PRIMARY KEY (id);


--
-- Name: companies companies_join_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_join_code_key UNIQUE (join_code);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: company_crew_usage_daily company_crew_usage_daily_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_crew_usage_daily
    ADD CONSTRAINT company_crew_usage_daily_pkey PRIMARY KEY (company_id, usage_date);


--
-- Name: company_settings company_settings_company_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings
    ADD CONSTRAINT company_settings_company_id_key UNIQUE (company_id);


--
-- Name: company_settings company_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings
    ADD CONSTRAINT company_settings_pkey PRIMARY KEY (id);


--
-- Name: company_subscriptions company_subscriptions_company_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_subscriptions
    ADD CONSTRAINT company_subscriptions_company_id_key UNIQUE (company_id);


--
-- Name: company_subscriptions company_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_subscriptions
    ADD CONSTRAINT company_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: company_subscriptions company_subscriptions_stripe_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_subscriptions
    ADD CONSTRAINT company_subscriptions_stripe_customer_id_key UNIQUE (stripe_customer_id);


--
-- Name: company_subscriptions company_subscriptions_stripe_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_subscriptions
    ADD CONSTRAINT company_subscriptions_stripe_subscription_id_key UNIQUE (stripe_subscription_id);


--
-- Name: contract_field_settings contract_field_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_field_settings
    ADD CONSTRAINT contract_field_settings_pkey PRIMARY KEY (contract_id);


--
-- Name: contracts contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_pkey PRIMARY KEY (id);


--
-- Name: crews crews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crews
    ADD CONSTRAINT crews_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: daily_production_items daily_production_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_pkey PRIMARY KEY (id);


--
-- Name: daily_production_unit_locations daily_production_unit_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_pkey PRIMARY KEY (id);


--
-- Name: daily_production_unit_locations daily_production_unit_locations_report_item_location_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_report_item_location_unique UNIQUE (daily_report_id, price_book_item_id, pole_location_key);


--
-- Name: daily_production_units daily_production_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_pkey PRIMARY KEY (id);


--
-- Name: daily_production_units daily_production_units_report_item_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_report_item_unique UNIQUE (daily_report_id, price_book_item_id);


--
-- Name: daily_report_attachments daily_report_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_attachments
    ADD CONSTRAINT daily_report_attachments_pkey PRIMARY KEY (id);


--
-- Name: daily_report_attachments daily_report_attachments_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_attachments
    ADD CONSTRAINT daily_report_attachments_storage_path_key UNIQUE (storage_path);


--
-- Name: daily_report_audit_events daily_report_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_audit_events
    ADD CONSTRAINT daily_report_audit_events_pkey PRIMARY KEY (id);


--
-- Name: daily_report_jsas daily_report_jsas_daily_report_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_jsas
    ADD CONSTRAINT daily_report_jsas_daily_report_id_key UNIQUE (daily_report_id);


--
-- Name: daily_report_jsas daily_report_jsas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_jsas
    ADD CONSTRAINT daily_report_jsas_pkey PRIMARY KEY (id);


--
-- Name: daily_report_units daily_report_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_units
    ADD CONSTRAINT daily_report_units_pkey PRIMARY KEY (id);


--
-- Name: daily_reports daily_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_pkey PRIMARY KEY (id);


--
-- Name: employees employees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees
    ADD CONSTRAINT employees_pkey PRIMARY KEY (id);


--
-- Name: gf_foreman_assignments gf_foreman_assignments_one_primary_gf; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gf_foreman_assignments
    ADD CONSTRAINT gf_foreman_assignments_one_primary_gf UNIQUE (company_id, foreman_id);


--
-- Name: gf_foreman_assignments gf_foreman_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gf_foreman_assignments
    ADD CONSTRAINT gf_foreman_assignments_pkey PRIMARY KEY (id);


--
-- Name: job_assignment_audit_events job_assignment_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_assignment_audit_events
    ADD CONSTRAINT job_assignment_audit_events_pkey PRIMARY KEY (id);


--
-- Name: job_closeout_history job_closeout_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_closeout_history
    ADD CONSTRAINT job_closeout_history_pkey PRIMARY KEY (id);


--
-- Name: job_leader_assignments job_leader_assignments_job_id_member_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_leader_assignments
    ADD CONSTRAINT job_leader_assignments_job_id_member_id_key UNIQUE (job_id, member_id);


--
-- Name: job_leader_assignments job_leader_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_leader_assignments
    ADD CONSTRAINT job_leader_assignments_pkey PRIMARY KEY (id);


--
-- Name: job_package_authorized_units job_package_authorized_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_pkey PRIMARY KEY (id);


--
-- Name: job_package_authorized_units job_package_authorized_units_point_item_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_point_item_unique UNIQUE (work_point_id, price_book_item_id);


--
-- Name: job_package_work_points job_package_work_points_package_code_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_work_points
    ADD CONSTRAINT job_package_work_points_package_code_unique UNIQUE (job_package_id, work_point_key);


--
-- Name: job_package_work_points job_package_work_points_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_work_points
    ADD CONSTRAINT job_package_work_points_pkey PRIMARY KEY (id);


--
-- Name: job_packages job_packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_packages
    ADD CONSTRAINT job_packages_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_company_id_job_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_company_id_job_number_key UNIQUE (company_id, job_number);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: jsa_upload_attachments jsa_upload_attachments_jsa_id_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jsa_upload_attachments
    ADD CONSTRAINT jsa_upload_attachments_jsa_id_storage_path_key UNIQUE (jsa_id, storage_path);


--
-- Name: jsa_upload_attachments jsa_upload_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jsa_upload_attachments
    ADD CONSTRAINT jsa_upload_attachments_pkey PRIMARY KEY (id);


--
-- Name: pilot_feedback pilot_feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pilot_feedback
    ADD CONSTRAINT pilot_feedback_pkey PRIMARY KEY (id);


--
-- Name: platform_owner_audit_events platform_owner_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_owner_audit_events
    ADD CONSTRAINT platform_owner_audit_events_pkey PRIMARY KEY (id);


--
-- Name: platform_owners platform_owners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_owners
    ADD CONSTRAINT platform_owners_pkey PRIMARY KEY (user_id);


--
-- Name: platform_support_users platform_support_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_support_users
    ADD CONSTRAINT platform_support_users_pkey PRIMARY KEY (user_id);


--
-- Name: price_book_items price_book_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_book_items
    ADD CONSTRAINT price_book_items_pkey PRIMARY KEY (id);


--
-- Name: price_books price_books_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_books
    ADD CONSTRAINT price_books_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: report_units report_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_units
    ADD CONSTRAINT report_units_pkey PRIMARY KEY (id);


--
-- Name: storm_mode_assignments storm_mode_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storm_mode_assignments
    ADD CONSTRAINT storm_mode_assignments_pkey PRIMARY KEY (company_id, user_id);


--
-- Name: support_access_requests support_access_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_access_requests
    ADD CONSTRAINT support_access_requests_pkey PRIMARY KEY (id);


--
-- Name: support_audit_events support_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_audit_events
    ADD CONSTRAINT support_audit_events_pkey PRIMARY KEY (id);


--
-- Name: team_invitations team_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_invitations
    ADD CONSTRAINT team_invitations_pkey PRIMARY KEY (id);


--
-- Name: team_invitations team_invitations_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_invitations
    ADD CONSTRAINT team_invitations_token_hash_key UNIQUE (token_hash);


--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_edit_audit
    ADD CONSTRAINT timekeeping_edit_audit_pkey PRIMARY KEY (id);


--
-- Name: timekeeping_employees timekeeping_employees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_pkey PRIMARY KEY (id);


--
-- Name: timekeeping_entries timekeeping_entries_employee_day_job_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entries
    ADD CONSTRAINT timekeeping_entries_employee_day_job_unique UNIQUE (company_id, employee_id, work_date, job_id);


--
-- Name: timekeeping_entries timekeeping_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entries
    ADD CONSTRAINT timekeeping_entries_pkey PRIMARY KEY (id);


--
-- Name: timekeeping_entry_history timekeeping_entry_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entry_history
    ADD CONSTRAINT timekeeping_entry_history_pkey PRIMARY KEY (id);


--
-- Name: timekeeping_equipment timekeeping_equipment_company_id_unit_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_equipment
    ADD CONSTRAINT timekeeping_equipment_company_id_unit_number_key UNIQUE (company_id, unit_number);


--
-- Name: timekeeping_equipment timekeeping_equipment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_equipment
    ADD CONSTRAINT timekeeping_equipment_pkey PRIMARY KEY (id);


--
-- Name: timekeeping_pay_period_audit timekeeping_pay_period_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_period_audit
    ADD CONSTRAINT timekeeping_pay_period_audit_pkey PRIMARY KEY (id);


--
-- Name: timekeeping_pay_periods timekeeping_pay_period_company_dates_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_periods
    ADD CONSTRAINT timekeeping_pay_period_company_dates_unique UNIQUE (company_id, period_start, period_end);


--
-- Name: timekeeping_pay_periods timekeeping_pay_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_periods
    ADD CONSTRAINT timekeeping_pay_periods_pkey PRIMARY KEY (id);


--
-- Name: training_progress training_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_progress
    ADD CONSTRAINT training_progress_pkey PRIMARY KEY (user_id, video_id);


--
-- Name: training_videos training_videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_videos
    ADD CONSTRAINT training_videos_pkey PRIMARY KEY (id);


--
-- Name: training_videos training_videos_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_videos
    ADD CONSTRAINT training_videos_slug_key UNIQUE (slug);


--
-- Name: training_videos training_videos_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_videos
    ADD CONSTRAINT training_videos_storage_path_key UNIQUE (storage_path);


--
-- Name: unit_prices unit_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_prices
    ADD CONSTRAINT unit_prices_pkey PRIMARY KEY (id);


--
-- Name: unit_prices unit_prices_price_book_id_unit_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_prices
    ADD CONSTRAINT unit_prices_price_book_id_unit_key UNIQUE (price_book_id, unit);


--
-- Name: user_dashboard_preferences user_dashboard_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_dashboard_preferences
    ADD CONSTRAINT user_dashboard_preferences_pkey PRIMARY KEY (user_id);


--
-- Name: utility_packet_import_rows utility_packet_import_rows_number_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_import_rows
    ADD CONSTRAINT utility_packet_import_rows_number_unique UNIQUE (import_id, source_row);


--
-- Name: utility_packet_import_rows utility_packet_import_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_import_rows
    ADD CONSTRAINT utility_packet_import_rows_pkey PRIMARY KEY (id);


--
-- Name: utility_packet_imports utility_packet_imports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_imports
    ADD CONSTRAINT utility_packet_imports_pkey PRIMARY KEY (id);


--
-- Name: utility_packet_imports utility_packet_imports_source_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_imports
    ADD CONSTRAINT utility_packet_imports_source_unique UNIQUE (job_package_id, source_sha256);


--
-- Name: utility_packet_unit_aliases utility_packet_unit_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_unit_aliases
    ADD CONSTRAINT utility_packet_unit_aliases_pkey PRIMARY KEY (id);


--
-- Name: utility_packet_unit_aliases utility_packet_unit_aliases_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_unit_aliases
    ADD CONSTRAINT utility_packet_unit_aliases_unique UNIQUE (company_id, contract_id, normalized_code);


--
-- Name: work_points work_points_job_id_work_point_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_points
    ADD CONSTRAINT work_points_job_id_work_point_number_key UNIQUE (job_id, work_point_number);


--
-- Name: work_points work_points_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_points
    ADD CONSTRAINT work_points_pkey PRIMARY KEY (id);


--
-- Name: app_error_events_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_error_events_company_created_idx ON public.app_error_events USING btree (company_id, created_at DESC);


--
-- Name: app_error_events_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_error_events_user_id_idx ON public.app_error_events USING btree (user_id);


--
-- Name: assistant_memories_company_active_trigger_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assistant_memories_company_active_trigger_idx ON public.assistant_memories USING btree (company_id, active, trigger_type, created_at DESC);


--
-- Name: assistant_memories_completed_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assistant_memories_completed_by_idx ON public.assistant_memories USING btree (completed_by) WHERE (completed_by IS NOT NULL);


--
-- Name: assistant_memories_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assistant_memories_created_by_idx ON public.assistant_memories USING btree (created_by);


--
-- Name: assistant_memories_job_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assistant_memories_job_active_idx ON public.assistant_memories USING btree (job_id, active, created_at DESC) WHERE (job_id IS NOT NULL);


--
-- Name: assistant_memories_removed_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX assistant_memories_removed_by_idx ON public.assistant_memories USING btree (removed_by) WHERE (removed_by IS NOT NULL);


--
-- Name: audit_log_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_company_id_idx ON public.audit_log USING btree (company_id);


--
-- Name: audit_log_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_user_id_idx ON public.audit_log USING btree (user_id);


--
-- Name: beta_applications_fingerprint_submitted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX beta_applications_fingerprint_submitted_idx ON public.beta_applications USING btree (request_fingerprint_hash, submitted_at DESC) WHERE (request_fingerprint_hash IS NOT NULL);


--
-- Name: beta_applications_one_pending_email_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX beta_applications_one_pending_email_idx ON public.beta_applications USING btree (lower(email)) WHERE (status = 'pending'::text);


--
-- Name: beta_applications_status_submitted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX beta_applications_status_submitted_idx ON public.beta_applications USING btree (status, submitted_at DESC);


--
-- Name: billing_events_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_events_company_id_idx ON public.billing_events USING btree (company_id);


--
-- Name: billing_export_attachments_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_attachments_batch_idx ON public.billing_export_attachments USING btree (company_id, billing_batch_id, created_at);


--
-- Name: billing_export_attachments_billing_batch_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_attachments_billing_batch_id_idx ON public.billing_export_attachments USING btree (billing_batch_id);


--
-- Name: billing_export_attachments_uploaded_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_attachments_uploaded_by_idx ON public.billing_export_attachments USING btree (uploaded_by);


--
-- Name: billing_export_batches_archived_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_archived_by_idx ON public.billing_export_batches USING btree (archived_by);


--
-- Name: billing_export_batches_company_archive_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_company_archive_idx ON public.billing_export_batches USING btree (company_id, archived_at, created_at DESC);


--
-- Name: billing_export_batches_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_company_created_idx ON public.billing_export_batches USING btree (company_id, created_at DESC);


--
-- Name: billing_export_batches_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_created_by_idx ON public.billing_export_batches USING btree (created_by);


--
-- Name: billing_export_batches_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_job_id_idx ON public.billing_export_batches USING btree (job_id);


--
-- Name: billing_export_batches_parent_batch_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_parent_batch_id_idx ON public.billing_export_batches USING btree (parent_batch_id);


--
-- Name: billing_export_batches_updated_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_batches_updated_by_idx ON public.billing_export_batches USING btree (updated_by);


--
-- Name: billing_export_lines_active_source_action_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX billing_export_lines_active_source_action_uidx ON public.billing_export_lines USING btree (company_id, production_location_id, work_type) WHERE active;


--
-- Name: billing_export_lines_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_lines_batch_idx ON public.billing_export_lines USING btree (billing_batch_id, unit_code, work_point);


--
-- Name: billing_export_lines_daily_report_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_lines_daily_report_id_idx ON public.billing_export_lines USING btree (daily_report_id);


--
-- Name: billing_export_lines_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_lines_job_id_idx ON public.billing_export_lines USING btree (job_id);


--
-- Name: billing_export_lines_price_book_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_lines_price_book_item_id_idx ON public.billing_export_lines USING btree (price_book_item_id);


--
-- Name: billing_export_lines_production_location_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_export_lines_production_location_id_idx ON public.billing_export_lines USING btree (production_location_id);


--
-- Name: companies_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX companies_created_by_idx ON public.companies USING btree (created_by);


--
-- Name: contract_field_settings_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contract_field_settings_company_id_idx ON public.contract_field_settings USING btree (company_id);


--
-- Name: contract_field_settings_updated_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contract_field_settings_updated_by_idx ON public.contract_field_settings USING btree (updated_by);


--
-- Name: contracts_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contracts_company_id_idx ON public.contracts USING btree (company_id);


--
-- Name: contracts_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contracts_customer_id_idx ON public.contracts USING btree (customer_id);


--
-- Name: crews_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX crews_company_id_idx ON public.crews USING btree (company_id);


--
-- Name: crews_foreman_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX crews_foreman_id_idx ON public.crews USING btree (foreman_id);


--
-- Name: customers_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customers_company_id_idx ON public.customers USING btree (company_id);


--
-- Name: daily_production_items_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_items_company_id_idx ON public.daily_production_items USING btree (company_id);


--
-- Name: daily_production_items_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_items_created_by_idx ON public.daily_production_items USING btree (created_by);


--
-- Name: daily_production_items_daily_report_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_items_daily_report_id_idx ON public.daily_production_items USING btree (daily_report_id);


--
-- Name: daily_production_items_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_items_job_id_idx ON public.daily_production_items USING btree (job_id);


--
-- Name: daily_production_items_price_book_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_items_price_book_item_id_idx ON public.daily_production_items USING btree (price_book_item_id);


--
-- Name: daily_production_items_work_point_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_items_work_point_id_idx ON public.daily_production_items USING btree (work_point_id);


--
-- Name: daily_production_unit_locations_company_report_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_unit_locations_company_report_idx ON public.daily_production_unit_locations USING btree (company_id, daily_report_id);


--
-- Name: daily_production_unit_locations_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_unit_locations_created_by_idx ON public.daily_production_unit_locations USING btree (created_by);


--
-- Name: daily_production_unit_locations_daily_production_unit_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_unit_locations_daily_production_unit_id_idx ON public.daily_production_unit_locations USING btree (daily_production_unit_id);


--
-- Name: daily_production_unit_locations_price_book_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_unit_locations_price_book_item_id_idx ON public.daily_production_unit_locations USING btree (price_book_item_id);


--
-- Name: daily_production_units_company_report_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_units_company_report_idx ON public.daily_production_units USING btree (company_id, daily_report_id);


--
-- Name: daily_production_units_contract_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_units_contract_id_idx ON public.daily_production_units USING btree (contract_id);


--
-- Name: daily_production_units_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_units_created_by_idx ON public.daily_production_units USING btree (created_by);


--
-- Name: daily_production_units_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_units_job_id_idx ON public.daily_production_units USING btree (job_id);


--
-- Name: daily_production_units_price_book_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_units_price_book_id_idx ON public.daily_production_units USING btree (price_book_id);


--
-- Name: daily_production_units_price_book_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_production_units_price_book_item_id_idx ON public.daily_production_units USING btree (price_book_item_id);


--
-- Name: daily_report_attachments_daily_report_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_attachments_daily_report_id_idx ON public.daily_report_attachments USING btree (daily_report_id);


--
-- Name: daily_report_attachments_report_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_attachments_report_idx ON public.daily_report_attachments USING btree (company_id, daily_report_id, created_at);


--
-- Name: daily_report_attachments_uploaded_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_attachments_uploaded_by_idx ON public.daily_report_attachments USING btree (uploaded_by);


--
-- Name: daily_report_audit_events_actor_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_audit_events_actor_id_idx ON public.daily_report_audit_events USING btree (actor_id);


--
-- Name: daily_report_audit_events_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_audit_events_company_created_idx ON public.daily_report_audit_events USING btree (company_id, created_at DESC);


--
-- Name: daily_report_audit_events_report_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_audit_events_report_created_idx ON public.daily_report_audit_events USING btree (daily_report_id, created_at DESC);


--
-- Name: daily_report_jsas_company_client_submission_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX daily_report_jsas_company_client_submission_uidx ON public.daily_report_jsas USING btree (company_id, client_submission_id) WHERE (client_submission_id IS NOT NULL);


--
-- Name: daily_report_jsas_company_work_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_jsas_company_work_date_idx ON public.daily_report_jsas USING btree (company_id, work_date DESC);


--
-- Name: daily_report_jsas_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_jsas_created_by_idx ON public.daily_report_jsas USING btree (created_by);


--
-- Name: daily_report_jsas_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_jsas_job_id_idx ON public.daily_report_jsas USING btree (job_id);


--
-- Name: daily_report_units_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_units_company_idx ON public.daily_report_units USING btree (company_id);


--
-- Name: daily_report_units_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_units_job_idx ON public.daily_report_units USING btree (job_id);


--
-- Name: daily_report_units_report_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_units_report_idx ON public.daily_report_units USING btree (report_id);


--
-- Name: daily_reports_approved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_approved_by_idx ON public.daily_reports USING btree (approved_by);


--
-- Name: daily_reports_company_archived_work_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_company_archived_work_date_idx ON public.daily_reports USING btree (company_id, archived, work_date DESC);


--
-- Name: daily_reports_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_company_idx ON public.daily_reports USING btree (company_id);


--
-- Name: daily_reports_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_created_by_idx ON public.daily_reports USING btree (created_by);


--
-- Name: daily_reports_crew_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_crew_id_idx ON public.daily_reports USING btree (crew_id);


--
-- Name: daily_reports_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_date_idx ON public.daily_reports USING btree (work_date);


--
-- Name: daily_reports_foreman_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_foreman_idx ON public.daily_reports USING btree (foreman_id);


--
-- Name: daily_reports_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_job_idx ON public.daily_reports USING btree (job_id);


--
-- Name: daily_reports_price_book_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_price_book_id_idx ON public.daily_reports USING btree (price_book_id);


--
-- Name: daily_reports_redline_override_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_redline_override_by_idx ON public.daily_reports USING btree (redline_override_by);


--
-- Name: daily_reports_reviewed_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_reports_reviewed_by_idx ON public.daily_reports USING btree (reviewed_by);


--
-- Name: employees_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX employees_company_id_idx ON public.employees USING btree (company_id);


--
-- Name: employees_crew_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX employees_crew_id_idx ON public.employees USING btree (crew_id);


--
-- Name: gf_foreman_assignments_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gf_foreman_assignments_created_by_idx ON public.gf_foreman_assignments USING btree (created_by);


--
-- Name: gf_foreman_assignments_foreman_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gf_foreman_assignments_foreman_id_idx ON public.gf_foreman_assignments USING btree (foreman_id);


--
-- Name: gf_foreman_assignments_gf_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gf_foreman_assignments_gf_id_idx ON public.gf_foreman_assignments USING btree (gf_id);


--
-- Name: gf_foreman_assignments_gf_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gf_foreman_assignments_gf_idx ON public.gf_foreman_assignments USING btree (company_id, gf_id);


--
-- Name: idx_jobs_company; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_jobs_company ON public.jobs USING btree (company_id);


--
-- Name: idx_prices_company; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prices_company ON public.unit_prices USING btree (company_id);


--
-- Name: idx_profiles_company; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_company ON public.profiles USING btree (company_id);


--
-- Name: idx_report_units_company; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_report_units_company ON public.report_units USING btree (company_id);


--
-- Name: idx_report_units_report; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_report_units_report ON public.report_units USING btree (report_id);


--
-- Name: idx_reports_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reports_date ON public.daily_reports USING btree (report_date);


--
-- Name: job_assignment_audit_company_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_assignment_audit_company_job_idx ON public.job_assignment_audit_events USING btree (company_id, job_id, created_at DESC);


--
-- Name: job_assignment_audit_company_member_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_assignment_audit_company_member_idx ON public.job_assignment_audit_events USING btree (company_id, member_id, created_at DESC);


--
-- Name: job_assignment_audit_events_actor_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_assignment_audit_events_actor_id_idx ON public.job_assignment_audit_events USING btree (actor_id);


--
-- Name: job_assignment_audit_events_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_assignment_audit_events_job_id_idx ON public.job_assignment_audit_events USING btree (job_id);


--
-- Name: job_assignment_audit_events_member_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_assignment_audit_events_member_id_idx ON public.job_assignment_audit_events USING btree (member_id);


--
-- Name: job_closeout_history_actor_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_closeout_history_actor_id_idx ON public.job_closeout_history USING btree (actor_id);


--
-- Name: job_closeout_history_company_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_closeout_history_company_time_idx ON public.job_closeout_history USING btree (company_id, occurred_at DESC);


--
-- Name: job_closeout_history_job_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_closeout_history_job_time_idx ON public.job_closeout_history USING btree (job_id, occurred_at DESC);


--
-- Name: job_leader_assignments_assigned_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_leader_assignments_assigned_by_idx ON public.job_leader_assignments USING btree (assigned_by);


--
-- Name: job_leader_assignments_company_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_leader_assignments_company_job_idx ON public.job_leader_assignments USING btree (company_id, job_id);


--
-- Name: job_leader_assignments_company_member_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_leader_assignments_company_member_idx ON public.job_leader_assignments USING btree (company_id, member_id);


--
-- Name: job_leader_assignments_member_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_leader_assignments_member_id_idx ON public.job_leader_assignments USING btree (member_id);


--
-- Name: job_package_authorized_units_company_package_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_authorized_units_company_package_idx ON public.job_package_authorized_units USING btree (company_id, job_package_id);


--
-- Name: job_package_authorized_units_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_authorized_units_created_by_idx ON public.job_package_authorized_units USING btree (created_by);


--
-- Name: job_package_authorized_units_job_package_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_authorized_units_job_package_id_idx ON public.job_package_authorized_units USING btree (job_package_id);


--
-- Name: job_package_authorized_units_price_book_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_authorized_units_price_book_item_id_idx ON public.job_package_authorized_units USING btree (price_book_item_id);


--
-- Name: job_package_work_points_company_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_work_points_company_job_idx ON public.job_package_work_points USING btree (company_id, job_id);


--
-- Name: job_package_work_points_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_work_points_created_by_idx ON public.job_package_work_points USING btree (created_by);


--
-- Name: job_package_work_points_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_package_work_points_job_id_idx ON public.job_package_work_points USING btree (job_id);


--
-- Name: job_package_work_points_package_canonical_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX job_package_work_points_package_canonical_key_idx ON public.job_package_work_points USING btree (job_package_id, public.normalize_work_point_key(work_point_code));


--
-- Name: job_packages_company_contract_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_packages_company_contract_idx ON public.job_packages USING btree (company_id, contract_id);


--
-- Name: job_packages_company_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_packages_company_job_idx ON public.job_packages USING btree (company_id, job_id, created_at DESC);


--
-- Name: job_packages_contract_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_packages_contract_id_idx ON public.job_packages USING btree (contract_id);


--
-- Name: job_packages_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_packages_created_by_idx ON public.job_packages USING btree (created_by);


--
-- Name: job_packages_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_packages_job_id_idx ON public.job_packages USING btree (job_id);


--
-- Name: job_packages_reference_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX job_packages_reference_unique ON public.job_packages USING btree (company_id, job_id, lower(TRIM(BOTH FROM package_number))) WHERE ((package_number IS NOT NULL) AND (length(TRIM(BOTH FROM package_number)) > 0));


--
-- Name: job_packages_supersedes_package_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_packages_supersedes_package_id_idx ON public.job_packages USING btree (supersedes_package_id);


--
-- Name: jobs_closed_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_closed_by_idx ON public.jobs USING btree (closed_by);


--
-- Name: jobs_company_contract_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_company_contract_idx ON public.jobs USING btree (company_id, contract_id);


--
-- Name: jobs_contract_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_contract_id_idx ON public.jobs USING btree (contract_id);


--
-- Name: jobs_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_created_by_idx ON public.jobs USING btree (created_by);


--
-- Name: jobs_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_customer_id_idx ON public.jobs USING btree (customer_id);


--
-- Name: jobs_price_book_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_price_book_id_idx ON public.jobs USING btree (price_book_id);


--
-- Name: jobs_reopened_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_reopened_by_idx ON public.jobs USING btree (reopened_by);


--
-- Name: jsa_upload_attachments_company_jsa_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jsa_upload_attachments_company_jsa_idx ON public.jsa_upload_attachments USING btree (company_id, jsa_id, page_order);


--
-- Name: jsa_upload_attachments_uploaded_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jsa_upload_attachments_uploaded_by_idx ON public.jsa_upload_attachments USING btree (uploaded_by);


--
-- Name: pilot_feedback_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pilot_feedback_company_created_idx ON public.pilot_feedback USING btree (company_id, created_at DESC);


--
-- Name: pilot_feedback_resolved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pilot_feedback_resolved_by_idx ON public.pilot_feedback USING btree (resolved_by);


--
-- Name: pilot_feedback_submitted_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pilot_feedback_submitted_by_idx ON public.pilot_feedback USING btree (submitted_by);


--
-- Name: pilot_feedback_unresolved_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pilot_feedback_unresolved_idx ON public.pilot_feedback USING btree (created_at DESC) WHERE (resolved_at IS NULL);


--
-- Name: platform_owner_audit_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_owner_audit_company_created_idx ON public.platform_owner_audit_events USING btree (company_id, created_at DESC);


--
-- Name: platform_owner_audit_events_actor_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_owner_audit_events_actor_user_id_idx ON public.platform_owner_audit_events USING btree (actor_user_id);


--
-- Name: platform_owners_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_owners_created_by_idx ON public.platform_owners USING btree (created_by);


--
-- Name: price_book_items_book_code_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX price_book_items_book_code_unique ON public.price_book_items USING btree (price_book_id, lower(btrim(item_code)));


--
-- Name: price_book_items_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX price_book_items_company_id_idx ON public.price_book_items USING btree (company_id);


--
-- Name: price_book_items_item_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX price_book_items_item_code_idx ON public.price_book_items USING btree (item_code);


--
-- Name: price_book_items_price_book_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX price_book_items_price_book_id_idx ON public.price_book_items USING btree (price_book_id);


--
-- Name: price_books_contract_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX price_books_contract_id_idx ON public.price_books USING btree (contract_id);


--
-- Name: price_books_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX price_books_created_by_idx ON public.price_books USING btree (created_by);


--
-- Name: price_books_one_active_version_per_family; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX price_books_one_active_version_per_family ON public.price_books USING btree (company_id, COALESCE(contract_id, '00000000-0000-0000-0000-000000000000'::uuid), COALESCE(lower(btrim(name)), ''::text)) WHERE (active IS TRUE);


--
-- Name: profiles_one_owner_per_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_one_owner_per_company_idx ON public.profiles USING btree (company_id) WHERE (lower(COALESCE(role, ''::text)) = 'owner'::text);


--
-- Name: INDEX profiles_one_owner_per_company_idx; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON INDEX public.profiles_one_owner_per_company_idx IS 'Enforces exactly zero or one Owner role per company. Owner creation and transfer are serialized by company row locks.';


--
-- Name: storm_mode_assignments_assigned_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX storm_mode_assignments_assigned_by_idx ON public.storm_mode_assignments USING btree (assigned_by);


--
-- Name: storm_mode_assignments_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX storm_mode_assignments_user_idx ON public.storm_mode_assignments USING btree (user_id, company_id);


--
-- Name: support_access_requests_approved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_access_requests_approved_by_idx ON public.support_access_requests USING btree (approved_by);


--
-- Name: support_access_requests_company_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_access_requests_company_status_idx ON public.support_access_requests USING btree (company_id, status, requested_at DESC);


--
-- Name: support_access_requests_operator_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_access_requests_operator_idx ON public.support_access_requests USING btree (support_user_id, requested_at DESC);


--
-- Name: support_access_requests_revoked_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_access_requests_revoked_by_idx ON public.support_access_requests USING btree (revoked_by);


--
-- Name: support_audit_events_actor_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_audit_events_actor_id_idx ON public.support_audit_events USING btree (actor_id);


--
-- Name: support_audit_events_company_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_audit_events_company_created_idx ON public.support_audit_events USING btree (company_id, created_at DESC);


--
-- Name: support_audit_events_request_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_audit_events_request_id_idx ON public.support_audit_events USING btree (request_id);


--
-- Name: team_invitations_accepted_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX team_invitations_accepted_by_idx ON public.team_invitations USING btree (accepted_by);


--
-- Name: team_invitations_company_email_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX team_invitations_company_email_pending_idx ON public.team_invitations USING btree (company_id, lower(email), expires_at) WHERE (accepted_at IS NULL);


--
-- Name: team_invitations_invited_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX team_invitations_invited_by_idx ON public.team_invitations USING btree (invited_by);


--
-- Name: timekeeping_edit_audit_company_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_edit_audit_company_date_idx ON public.timekeeping_edit_audit USING btree (company_id, edited_at DESC);


--
-- Name: timekeeping_edit_audit_daily_report_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_edit_audit_daily_report_id_idx ON public.timekeeping_edit_audit USING btree (daily_report_id);


--
-- Name: timekeeping_edit_audit_edited_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_edit_audit_edited_by_idx ON public.timekeeping_edit_audit USING btree (edited_by);


--
-- Name: timekeeping_edit_audit_employee_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_edit_audit_employee_id_idx ON public.timekeeping_edit_audit USING btree (employee_id);


--
-- Name: timekeeping_edit_audit_entry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_edit_audit_entry_idx ON public.timekeeping_edit_audit USING btree (timekeeping_entry_id, edited_at DESC);


--
-- Name: timekeeping_employees_admin_assigned_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_admin_assigned_by_idx ON public.timekeeping_employees USING btree (admin_assigned_by);


--
-- Name: timekeeping_employees_assigned_admin_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_assigned_admin_id_idx ON public.timekeeping_employees USING btree (assigned_admin_id);


--
-- Name: timekeeping_employees_assigned_admin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_assigned_admin_idx ON public.timekeeping_employees USING btree (company_id, assigned_admin_id, active, full_name);


--
-- Name: timekeeping_employees_assigned_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_assigned_by_idx ON public.timekeeping_employees USING btree (assigned_by);


--
-- Name: timekeeping_employees_assigned_foreman_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_assigned_foreman_id_idx ON public.timekeeping_employees USING btree (assigned_foreman_id);


--
-- Name: timekeeping_employees_assigned_foreman_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_assigned_foreman_idx ON public.timekeeping_employees USING btree (company_id, assigned_foreman_id, active, full_name);


--
-- Name: timekeeping_employees_company_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_employees_company_active_idx ON public.timekeeping_employees USING btree (company_id, active, full_name);


--
-- Name: timekeeping_employees_company_employee_number_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX timekeeping_employees_company_employee_number_uidx ON public.timekeeping_employees USING btree (company_id, lower(employee_number)) WHERE ((employee_number IS NOT NULL) AND (btrim(employee_number) <> ''::text));


--
-- Name: timekeeping_employees_company_linked_profile_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX timekeeping_employees_company_linked_profile_uidx ON public.timekeeping_employees USING btree (company_id, linked_profile_id) WHERE (linked_profile_id IS NOT NULL);


--
-- Name: timekeeping_employees_linked_profile_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX timekeeping_employees_linked_profile_uidx ON public.timekeeping_employees USING btree (linked_profile_id) WHERE (linked_profile_id IS NOT NULL);


--
-- Name: timekeeping_entries_company_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entries_company_date_idx ON public.timekeeping_entries USING btree (company_id, work_date DESC);


--
-- Name: timekeeping_entries_company_employee_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entries_company_employee_idx ON public.timekeeping_entries USING btree (company_id, employee_id, work_date DESC);


--
-- Name: timekeeping_entries_daily_report_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entries_daily_report_idx ON public.timekeeping_entries USING btree (daily_report_id) WHERE (daily_report_id IS NOT NULL);


--
-- Name: timekeeping_entries_employee_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entries_employee_id_idx ON public.timekeeping_entries USING btree (employee_id);


--
-- Name: timekeeping_entries_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entries_job_idx ON public.timekeeping_entries USING btree (job_id);


--
-- Name: timekeeping_entries_kind_company_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entries_kind_company_date_idx ON public.timekeeping_entries USING btree (entry_kind, company_id, work_date DESC);


--
-- Name: timekeeping_entries_leadership_overhead_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX timekeeping_entries_leadership_overhead_uidx ON public.timekeeping_entries USING btree (company_id, employee_id, work_date, lower(labor_code)) WHERE ((entry_kind = 'leadership_self'::text) AND (job_id IS NULL));


--
-- Name: timekeeping_entry_history_company_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entry_history_company_date_idx ON public.timekeeping_entry_history USING btree (company_id, work_date DESC);


--
-- Name: timekeeping_entry_history_daily_report_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entry_history_daily_report_id_idx ON public.timekeeping_entry_history USING btree (daily_report_id);


--
-- Name: timekeeping_entry_history_employee_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entry_history_employee_id_idx ON public.timekeeping_entry_history USING btree (employee_id);


--
-- Name: timekeeping_entry_history_employee_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entry_history_employee_idx ON public.timekeeping_entry_history USING btree (company_id, employee_id, work_date DESC);


--
-- Name: timekeeping_entry_history_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_entry_history_job_id_idx ON public.timekeeping_entry_history USING btree (job_id);


--
-- Name: timekeeping_entry_history_segment_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX timekeeping_entry_history_segment_uidx ON public.timekeeping_entry_history USING btree (source_entry_id, daily_report_id, archived_at);


--
-- Name: timekeeping_equipment_company_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_equipment_company_active_idx ON public.timekeeping_equipment USING btree (company_id, active, unit_number);


--
-- Name: timekeeping_pay_period_audit_actor_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_pay_period_audit_actor_id_idx ON public.timekeeping_pay_period_audit USING btree (actor_id);


--
-- Name: timekeeping_pay_period_audit_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_pay_period_audit_company_idx ON public.timekeeping_pay_period_audit USING btree (company_id, created_at DESC);


--
-- Name: timekeeping_pay_periods_approved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_pay_periods_approved_by_idx ON public.timekeeping_pay_periods USING btree (approved_by);


--
-- Name: timekeeping_pay_periods_company_dates_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_pay_periods_company_dates_idx ON public.timekeeping_pay_periods USING btree (company_id, period_start DESC, period_end DESC);


--
-- Name: timekeeping_pay_periods_locked_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX timekeeping_pay_periods_locked_by_idx ON public.timekeeping_pay_periods USING btree (locked_by);


--
-- Name: training_progress_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX training_progress_company_id_idx ON public.training_progress USING btree (company_id);


--
-- Name: training_progress_video_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX training_progress_video_id_idx ON public.training_progress USING btree (video_id);


--
-- Name: user_dashboard_preferences_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_dashboard_preferences_company_idx ON public.user_dashboard_preferences USING btree (company_id);


--
-- Name: utility_packet_import_rows_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_import_rows_company_idx ON public.utility_packet_import_rows USING btree (company_id, import_id);


--
-- Name: utility_packet_import_rows_import_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_import_rows_import_idx ON public.utility_packet_import_rows USING btree (import_id, work_point_code, contractor_unit_code);


--
-- Name: utility_packet_imports_company_package_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_imports_company_package_idx ON public.utility_packet_imports USING btree (company_id, job_package_id, created_at DESC);


--
-- Name: utility_packet_imports_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_imports_created_by_idx ON public.utility_packet_imports USING btree (created_by);


--
-- Name: utility_packet_imports_reviewed_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_imports_reviewed_by_idx ON public.utility_packet_imports USING btree (reviewed_by);


--
-- Name: utility_packet_unit_aliases_contract_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_unit_aliases_contract_id_idx ON public.utility_packet_unit_aliases USING btree (contract_id);


--
-- Name: utility_packet_unit_aliases_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_unit_aliases_created_by_idx ON public.utility_packet_unit_aliases USING btree (created_by);


--
-- Name: utility_packet_unit_aliases_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_unit_aliases_lookup ON public.utility_packet_unit_aliases USING btree (company_id, contract_id, normalized_code);


--
-- Name: utility_packet_unit_aliases_updated_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX utility_packet_unit_aliases_updated_by_idx ON public.utility_packet_unit_aliases USING btree (updated_by);


--
-- Name: work_points_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX work_points_company_id_idx ON public.work_points USING btree (company_id);


--
-- Name: work_points_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX work_points_created_by_idx ON public.work_points USING btree (created_by);


--
-- Name: utility_packet_imports activate_finalized_utility_packet_revision_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER activate_finalized_utility_packet_revision_trigger AFTER UPDATE OF status ON public.utility_packet_imports FOR EACH ROW EXECUTE FUNCTION public.activate_finalized_utility_packet_revision();


--
-- Name: timekeeping_entries archive_timekeeping_segment_on_report_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER archive_timekeeping_segment_on_report_change BEFORE UPDATE ON public.timekeeping_entries FOR EACH ROW EXECUTE FUNCTION public.archive_timekeeping_segment_on_report_change();


--
-- Name: job_packages assign_job_package_revision_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assign_job_package_revision_trigger BEFORE INSERT ON public.job_packages FOR EACH ROW EXECUTE FUNCTION public.assign_job_package_revision();


--
-- Name: daily_reports daily_report_audit_event_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER daily_report_audit_event_trigger AFTER INSERT OR UPDATE OF status, archived ON public.daily_reports FOR EACH ROW EXECUTE FUNCTION public.record_daily_report_audit_event();


--
-- Name: daily_report_jsas daily_report_jsas_foreman_assigned_job; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER daily_report_jsas_foreman_assigned_job BEFORE INSERT OR UPDATE OF job_id, company_id ON public.daily_report_jsas FOR EACH ROW EXECUTE FUNCTION public.enforce_foreman_assigned_job();


--
-- Name: daily_reports daily_reports_foreman_assigned_job; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER daily_reports_foreman_assigned_job BEFORE INSERT OR UPDATE OF job_id, company_id ON public.daily_reports FOR EACH ROW EXECUTE FUNCTION public.enforce_foreman_assigned_job();


--
-- Name: daily_production_units enforce_active_job_daily_production_units; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_active_job_daily_production_units BEFORE INSERT OR DELETE OR UPDATE ON public.daily_production_units FOR EACH ROW EXECUTE FUNCTION public.enforce_active_job_for_daily_unit_mutation();


--
-- Name: daily_production_unit_locations enforce_active_job_daily_unit_locations; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_active_job_daily_unit_locations BEFORE INSERT OR DELETE OR UPDATE ON public.daily_production_unit_locations FOR EACH ROW EXECUTE FUNCTION public.enforce_active_job_for_daily_unit_mutation();


--
-- Name: job_package_authorized_units enforce_draft_job_package_authorized_unit_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_draft_job_package_authorized_unit_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.job_package_authorized_units FOR EACH ROW EXECUTE FUNCTION public.enforce_draft_job_package_unit_mutation();


--
-- Name: job_package_work_points enforce_draft_job_package_work_point_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_draft_job_package_work_point_mutation BEFORE INSERT OR DELETE OR UPDATE ON public.job_package_work_points FOR EACH ROW EXECUTE FUNCTION public.enforce_draft_job_package_unit_mutation();


--
-- Name: timekeeping_entries guard_timekeeping_locked_period; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_timekeeping_locked_period BEFORE INSERT OR DELETE OR UPDATE ON public.timekeeping_entries FOR EACH ROW EXECUTE FUNCTION public.guard_timekeeping_locked_period();


--
-- Name: crews linecrew_capture_crew_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_capture_crew_usage AFTER INSERT OR DELETE OR UPDATE OF active, foreman_id, company_id ON public.crews FOR EACH ROW EXECUTE FUNCTION public.capture_crew_usage_from_change();


--
-- Name: storm_mode_assignments linecrew_capture_storm_assignment_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_capture_storm_assignment_usage AFTER INSERT OR DELETE OR UPDATE ON public.storm_mode_assignments FOR EACH ROW EXECUTE FUNCTION public.capture_crew_usage_from_change();


--
-- Name: companies linecrew_capture_storm_toggle_usage; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_capture_storm_toggle_usage AFTER UPDATE OF storm_mode_enabled ON public.companies FOR EACH ROW WHEN ((old.storm_mode_enabled IS DISTINCT FROM new.storm_mode_enabled)) EXECUTE FUNCTION public.capture_company_storm_toggle_usage();


--
-- Name: crews linecrew_enforce_active_crew_plan_limit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_enforce_active_crew_plan_limit BEFORE INSERT OR UPDATE OF active, company_id ON public.crews FOR EACH ROW EXECUTE FUNCTION public.enforce_active_crew_plan_limit();


--
-- Name: companies linecrew_ensure_company_subscription; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_ensure_company_subscription AFTER INSERT ON public.companies FOR EACH ROW EXECUTE FUNCTION public.ensure_company_subscription();


--
-- Name: daily_report_jsas linecrew_validate_jsa_source_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_validate_jsa_source_trigger BEFORE INSERT OR UPDATE OF jsa_source, company_id ON public.daily_report_jsas FOR EACH ROW EXECUTE FUNCTION public.linecrew_validate_jsa_source();


--
-- Name: profiles linecrew_validate_profile_role_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER linecrew_validate_profile_role_trigger BEFORE INSERT OR UPDATE OF role, role_permissions ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.linecrew_validate_profile_role();


--
-- Name: daily_reports prevent_duplicate_daily_report; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_duplicate_daily_report BEFORE INSERT OR UPDATE OF company_id, job_id, work_date, foreman_id, archived ON public.daily_reports FOR EACH ROW EXECUTE FUNCTION public.prevent_duplicate_daily_report();


--
-- Name: job_packages prevent_non_draft_job_package_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_non_draft_job_package_delete BEFORE DELETE ON public.job_packages FOR EACH ROW EXECUTE FUNCTION public.prevent_non_draft_job_package_delete();


--
-- Name: daily_reports protect_daily_report_unit_history_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_daily_report_unit_history_trigger BEFORE UPDATE ON public.daily_reports FOR EACH ROW EXECUTE FUNCTION public.protect_daily_report_unit_history();


--
-- Name: daily_production_units set_daily_production_transfer_price_snapshot; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_daily_production_transfer_price_snapshot BEFORE INSERT OR UPDATE OF price_book_item_id, price_book_id, company_id, field_value_percent_snapshot, actual_install_price, adjusted_install_price ON public.daily_production_units FOR EACH ROW EXECUTE FUNCTION public.set_daily_production_transfer_price_snapshot();


--
-- Name: job_packages supersede_prior_job_package_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER supersede_prior_job_package_trigger AFTER UPDATE OF status ON public.job_packages FOR EACH ROW EXECUTE FUNCTION public.supersede_prior_job_package();


--
-- Name: profiles sync_foreman_timekeeping_employee_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_foreman_timekeeping_employee_trigger AFTER INSERT OR UPDATE OF role, active, company_id, full_name ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.sync_foreman_timekeeping_employee();


--
-- Name: daily_production_unit_locations trg_audit_returned_unit_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_returned_unit_change AFTER INSERT OR DELETE OR UPDATE ON public.daily_production_unit_locations FOR EACH ROW EXECUTE FUNCTION public.audit_returned_unit_change();


--
-- Name: daily_reports trg_set_daily_report_date; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_daily_report_date BEFORE INSERT OR UPDATE ON public.daily_reports FOR EACH ROW EXECUTE FUNCTION public.set_daily_report_date();


--
-- Name: timekeeping_entries trg_sync_daily_report_hours_from_timekeeping; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_daily_report_hours_from_timekeeping AFTER INSERT OR DELETE OR UPDATE ON public.timekeeping_entries FOR EACH ROW EXECUTE FUNCTION public.sync_daily_report_hours_from_timekeeping();


--
-- Name: timekeeping_employees validate_timekeeping_employee_admin_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_timekeeping_employee_admin_assignment BEFORE INSERT OR UPDATE OF assigned_admin_id ON public.timekeeping_employees FOR EACH ROW EXECUTE FUNCTION public.validate_timekeeping_employee_admin_assignment();


--
-- Name: timekeeping_employees validate_timekeeping_employee_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_timekeeping_employee_assignment BEFORE INSERT OR UPDATE ON public.timekeeping_employees FOR EACH ROW EXECUTE FUNCTION public.validate_timekeeping_employee_assignment();


--
-- Name: app_error_events app_error_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_error_events
    ADD CONSTRAINT app_error_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: app_error_events app_error_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_error_events
    ADD CONSTRAINT app_error_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: assistant_memories assistant_memories_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_memories
    ADD CONSTRAINT assistant_memories_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: assistant_memories assistant_memories_completed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_memories
    ADD CONSTRAINT assistant_memories_completed_by_fkey FOREIGN KEY (completed_by) REFERENCES public.profiles(id) ON DELETE RESTRICT;


--
-- Name: assistant_memories assistant_memories_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_memories
    ADD CONSTRAINT assistant_memories_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE RESTRICT;


--
-- Name: assistant_memories assistant_memories_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_memories
    ADD CONSTRAINT assistant_memories_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: assistant_memories assistant_memories_removed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assistant_memories
    ADD CONSTRAINT assistant_memories_removed_by_fkey FOREIGN KEY (removed_by) REFERENCES public.profiles(id) ON DELETE RESTRICT;


--
-- Name: audit_log audit_log_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: beta_applications beta_applications_approved_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beta_applications
    ADD CONSTRAINT beta_applications_approved_company_id_fkey FOREIGN KEY (approved_company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: beta_applications beta_applications_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beta_applications
    ADD CONSTRAINT beta_applications_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: billing_events billing_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: billing_export_attachments billing_export_attachments_billing_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_attachments
    ADD CONSTRAINT billing_export_attachments_billing_batch_id_fkey FOREIGN KEY (billing_batch_id) REFERENCES public.billing_export_batches(id) ON DELETE CASCADE;


--
-- Name: billing_export_attachments billing_export_attachments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_attachments
    ADD CONSTRAINT billing_export_attachments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: billing_export_attachments billing_export_attachments_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_attachments
    ADD CONSTRAINT billing_export_attachments_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.profiles(id);


--
-- Name: billing_export_batches billing_export_batches_archived_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_archived_by_fkey FOREIGN KEY (archived_by) REFERENCES public.profiles(id);


--
-- Name: billing_export_batches billing_export_batches_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: billing_export_batches billing_export_batches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: billing_export_batches billing_export_batches_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE RESTRICT;


--
-- Name: billing_export_batches billing_export_batches_parent_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_parent_batch_id_fkey FOREIGN KEY (parent_batch_id) REFERENCES public.billing_export_batches(id) ON DELETE RESTRICT;


--
-- Name: billing_export_batches billing_export_batches_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_batches
    ADD CONSTRAINT billing_export_batches_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id);


--
-- Name: billing_export_lines billing_export_lines_billing_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_billing_batch_id_fkey FOREIGN KEY (billing_batch_id) REFERENCES public.billing_export_batches(id) ON DELETE CASCADE;


--
-- Name: billing_export_lines billing_export_lines_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: billing_export_lines billing_export_lines_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE RESTRICT;


--
-- Name: billing_export_lines billing_export_lines_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE RESTRICT;


--
-- Name: billing_export_lines billing_export_lines_price_book_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_price_book_item_id_fkey FOREIGN KEY (price_book_item_id) REFERENCES public.price_book_items(id) ON DELETE RESTRICT;


--
-- Name: billing_export_lines billing_export_lines_production_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_export_lines
    ADD CONSTRAINT billing_export_lines_production_location_id_fkey FOREIGN KEY (production_location_id) REFERENCES public.daily_production_unit_locations(id) ON DELETE RESTRICT;


--
-- Name: companies companies_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: company_crew_usage_daily company_crew_usage_daily_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_crew_usage_daily
    ADD CONSTRAINT company_crew_usage_daily_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_settings company_settings_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings
    ADD CONSTRAINT company_settings_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_subscriptions company_subscriptions_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_subscriptions
    ADD CONSTRAINT company_subscriptions_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: contract_field_settings contract_field_settings_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_field_settings
    ADD CONSTRAINT contract_field_settings_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: contract_field_settings contract_field_settings_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_field_settings
    ADD CONSTRAINT contract_field_settings_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE CASCADE;


--
-- Name: contract_field_settings contract_field_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_field_settings
    ADD CONSTRAINT contract_field_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: contracts contracts_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: contracts contracts_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;


--
-- Name: crews crews_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crews
    ADD CONSTRAINT crews_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: crews crews_foreman_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.crews
    ADD CONSTRAINT crews_foreman_id_fkey FOREIGN KEY (foreman_id) REFERENCES public.profiles(id);


--
-- Name: customers customers_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_production_items daily_production_items_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_production_items daily_production_items_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: daily_production_items daily_production_items_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_production_items daily_production_items_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: daily_production_items daily_production_items_price_book_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_price_book_item_id_fkey FOREIGN KEY (price_book_item_id) REFERENCES public.price_book_items(id) ON DELETE SET NULL;


--
-- Name: daily_production_items daily_production_items_work_point_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_items
    ADD CONSTRAINT daily_production_items_work_point_id_fkey FOREIGN KEY (work_point_id) REFERENCES public.work_points(id) ON DELETE SET NULL;


--
-- Name: daily_production_unit_locations daily_production_unit_locations_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_production_unit_locations daily_production_unit_locations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: daily_production_unit_locations daily_production_unit_locations_daily_production_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_daily_production_unit_id_fkey FOREIGN KEY (daily_production_unit_id) REFERENCES public.daily_production_units(id) ON DELETE CASCADE;


--
-- Name: daily_production_unit_locations daily_production_unit_locations_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_production_unit_locations daily_production_unit_locations_price_book_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_unit_locations
    ADD CONSTRAINT daily_production_unit_locations_price_book_item_id_fkey FOREIGN KEY (price_book_item_id) REFERENCES public.price_book_items(id) ON DELETE RESTRICT;


--
-- Name: daily_production_units daily_production_units_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_production_units daily_production_units_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE RESTRICT;


--
-- Name: daily_production_units daily_production_units_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: daily_production_units daily_production_units_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_production_units daily_production_units_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE RESTRICT;


--
-- Name: daily_production_units daily_production_units_price_book_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_price_book_id_fkey FOREIGN KEY (price_book_id) REFERENCES public.price_books(id) ON DELETE RESTRICT;


--
-- Name: daily_production_units daily_production_units_price_book_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_production_units
    ADD CONSTRAINT daily_production_units_price_book_item_id_fkey FOREIGN KEY (price_book_item_id) REFERENCES public.price_book_items(id) ON DELETE RESTRICT;


--
-- Name: daily_report_attachments daily_report_attachments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_attachments
    ADD CONSTRAINT daily_report_attachments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_report_attachments daily_report_attachments_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_attachments
    ADD CONSTRAINT daily_report_attachments_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_report_attachments daily_report_attachments_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_attachments
    ADD CONSTRAINT daily_report_attachments_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: daily_report_audit_events daily_report_audit_events_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_audit_events
    ADD CONSTRAINT daily_report_audit_events_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: daily_report_audit_events daily_report_audit_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_audit_events
    ADD CONSTRAINT daily_report_audit_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_report_audit_events daily_report_audit_events_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_audit_events
    ADD CONSTRAINT daily_report_audit_events_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_report_jsas daily_report_jsas_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_jsas
    ADD CONSTRAINT daily_report_jsas_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_report_jsas daily_report_jsas_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_jsas
    ADD CONSTRAINT daily_report_jsas_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: daily_report_jsas daily_report_jsas_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_jsas
    ADD CONSTRAINT daily_report_jsas_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_report_jsas daily_report_jsas_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_jsas
    ADD CONSTRAINT daily_report_jsas_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: daily_report_units daily_report_units_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_units
    ADD CONSTRAINT daily_report_units_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_report_units daily_report_units_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_units
    ADD CONSTRAINT daily_report_units_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE RESTRICT;


--
-- Name: daily_report_units daily_report_units_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_units
    ADD CONSTRAINT daily_report_units_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: daily_reports daily_reports_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.profiles(id);


--
-- Name: daily_reports daily_reports_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: daily_reports daily_reports_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: daily_reports daily_reports_crew_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_crew_id_fkey FOREIGN KEY (crew_id) REFERENCES public.crews(id);


--
-- Name: daily_reports daily_reports_foreman_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_foreman_id_fkey FOREIGN KEY (foreman_id) REFERENCES public.profiles(id);


--
-- Name: daily_reports daily_reports_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: daily_reports daily_reports_price_book_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_price_book_id_fkey FOREIGN KEY (price_book_id) REFERENCES public.price_books(id) ON DELETE RESTRICT;


--
-- Name: daily_reports daily_reports_redline_override_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_redline_override_by_fkey FOREIGN KEY (redline_override_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: daily_reports daily_reports_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_reports
    ADD CONSTRAINT daily_reports_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: employees employees_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees
    ADD CONSTRAINT employees_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: employees employees_crew_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees
    ADD CONSTRAINT employees_crew_id_fkey FOREIGN KEY (crew_id) REFERENCES public.crews(id) ON DELETE SET NULL;


--
-- Name: gf_foreman_assignments gf_foreman_assignments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gf_foreman_assignments
    ADD CONSTRAINT gf_foreman_assignments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: gf_foreman_assignments gf_foreman_assignments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gf_foreman_assignments
    ADD CONSTRAINT gf_foreman_assignments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: gf_foreman_assignments gf_foreman_assignments_foreman_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gf_foreman_assignments
    ADD CONSTRAINT gf_foreman_assignments_foreman_id_fkey FOREIGN KEY (foreman_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: gf_foreman_assignments gf_foreman_assignments_gf_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gf_foreman_assignments
    ADD CONSTRAINT gf_foreman_assignments_gf_id_fkey FOREIGN KEY (gf_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: job_assignment_audit_events job_assignment_audit_events_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_assignment_audit_events
    ADD CONSTRAINT job_assignment_audit_events_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: job_assignment_audit_events job_assignment_audit_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_assignment_audit_events
    ADD CONSTRAINT job_assignment_audit_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: job_assignment_audit_events job_assignment_audit_events_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_assignment_audit_events
    ADD CONSTRAINT job_assignment_audit_events_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE SET NULL;


--
-- Name: job_assignment_audit_events job_assignment_audit_events_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_assignment_audit_events
    ADD CONSTRAINT job_assignment_audit_events_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: job_closeout_history job_closeout_history_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_closeout_history
    ADD CONSTRAINT job_closeout_history_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE RESTRICT;


--
-- Name: job_closeout_history job_closeout_history_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_closeout_history
    ADD CONSTRAINT job_closeout_history_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;


--
-- Name: job_closeout_history job_closeout_history_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_closeout_history
    ADD CONSTRAINT job_closeout_history_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE RESTRICT;


--
-- Name: job_leader_assignments job_leader_assignments_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_leader_assignments
    ADD CONSTRAINT job_leader_assignments_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: job_leader_assignments job_leader_assignments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_leader_assignments
    ADD CONSTRAINT job_leader_assignments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: job_leader_assignments job_leader_assignments_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_leader_assignments
    ADD CONSTRAINT job_leader_assignments_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: job_leader_assignments job_leader_assignments_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_leader_assignments
    ADD CONSTRAINT job_leader_assignments_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: job_package_authorized_units job_package_authorized_units_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: job_package_authorized_units job_package_authorized_units_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: job_package_authorized_units job_package_authorized_units_job_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_job_package_id_fkey FOREIGN KEY (job_package_id) REFERENCES public.job_packages(id) ON DELETE CASCADE;


--
-- Name: job_package_authorized_units job_package_authorized_units_price_book_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_price_book_item_id_fkey FOREIGN KEY (price_book_item_id) REFERENCES public.price_book_items(id) ON DELETE RESTRICT;


--
-- Name: job_package_authorized_units job_package_authorized_units_work_point_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_authorized_units
    ADD CONSTRAINT job_package_authorized_units_work_point_id_fkey FOREIGN KEY (work_point_id) REFERENCES public.job_package_work_points(id) ON DELETE CASCADE;


--
-- Name: job_package_work_points job_package_work_points_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_work_points
    ADD CONSTRAINT job_package_work_points_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: job_package_work_points job_package_work_points_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_work_points
    ADD CONSTRAINT job_package_work_points_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: job_package_work_points job_package_work_points_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_work_points
    ADD CONSTRAINT job_package_work_points_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: job_package_work_points job_package_work_points_job_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_package_work_points
    ADD CONSTRAINT job_package_work_points_job_package_id_fkey FOREIGN KEY (job_package_id) REFERENCES public.job_packages(id) ON DELETE CASCADE;


--
-- Name: job_packages job_packages_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_packages
    ADD CONSTRAINT job_packages_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: job_packages job_packages_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_packages
    ADD CONSTRAINT job_packages_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE RESTRICT;


--
-- Name: job_packages job_packages_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_packages
    ADD CONSTRAINT job_packages_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: job_packages job_packages_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_packages
    ADD CONSTRAINT job_packages_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: job_packages job_packages_supersedes_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_packages
    ADD CONSTRAINT job_packages_supersedes_package_id_fkey FOREIGN KEY (supersedes_package_id) REFERENCES public.job_packages(id) ON DELETE SET NULL;


--
-- Name: jobs jobs_closed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.profiles(id);


--
-- Name: jobs jobs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: jobs jobs_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE RESTRICT;


--
-- Name: jobs jobs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: jobs jobs_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;


--
-- Name: jobs jobs_price_book_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_price_book_id_fkey FOREIGN KEY (price_book_id) REFERENCES public.price_books(id) ON DELETE RESTRICT;


--
-- Name: jobs jobs_reopened_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_reopened_by_fkey FOREIGN KEY (reopened_by) REFERENCES public.profiles(id);


--
-- Name: jsa_upload_attachments jsa_upload_attachments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jsa_upload_attachments
    ADD CONSTRAINT jsa_upload_attachments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: jsa_upload_attachments jsa_upload_attachments_jsa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jsa_upload_attachments
    ADD CONSTRAINT jsa_upload_attachments_jsa_id_fkey FOREIGN KEY (jsa_id) REFERENCES public.daily_report_jsas(id) ON DELETE CASCADE;


--
-- Name: jsa_upload_attachments jsa_upload_attachments_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jsa_upload_attachments
    ADD CONSTRAINT jsa_upload_attachments_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES auth.users(id);


--
-- Name: pilot_feedback pilot_feedback_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pilot_feedback
    ADD CONSTRAINT pilot_feedback_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: pilot_feedback pilot_feedback_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pilot_feedback
    ADD CONSTRAINT pilot_feedback_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: pilot_feedback pilot_feedback_submitted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pilot_feedback
    ADD CONSTRAINT pilot_feedback_submitted_by_fkey FOREIGN KEY (submitted_by) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: platform_owner_audit_events platform_owner_audit_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_owner_audit_events
    ADD CONSTRAINT platform_owner_audit_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: platform_owner_audit_events platform_owner_audit_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_owner_audit_events
    ADD CONSTRAINT platform_owner_audit_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: platform_owners platform_owners_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_owners
    ADD CONSTRAINT platform_owners_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: platform_owners platform_owners_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_owners
    ADD CONSTRAINT platform_owners_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: platform_support_users platform_support_users_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_support_users
    ADD CONSTRAINT platform_support_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: price_book_items price_book_items_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_book_items
    ADD CONSTRAINT price_book_items_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: price_book_items price_book_items_price_book_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_book_items
    ADD CONSTRAINT price_book_items_price_book_id_fkey FOREIGN KEY (price_book_id) REFERENCES public.price_books(id) ON DELETE CASCADE;


--
-- Name: price_books price_books_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_books
    ADD CONSTRAINT price_books_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: price_books price_books_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_books
    ADD CONSTRAINT price_books_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE CASCADE;


--
-- Name: price_books price_books_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_books
    ADD CONSTRAINT price_books_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: profiles profiles_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: report_units report_units_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_units
    ADD CONSTRAINT report_units_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: report_units report_units_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.report_units
    ADD CONSTRAINT report_units_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.daily_reports(id) ON DELETE CASCADE;


--
-- Name: storm_mode_assignments storm_mode_assignments_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storm_mode_assignments
    ADD CONSTRAINT storm_mode_assignments_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: storm_mode_assignments storm_mode_assignments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storm_mode_assignments
    ADD CONSTRAINT storm_mode_assignments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: storm_mode_assignments storm_mode_assignments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storm_mode_assignments
    ADD CONSTRAINT storm_mode_assignments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: support_access_requests support_access_requests_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_access_requests
    ADD CONSTRAINT support_access_requests_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES auth.users(id);


--
-- Name: support_access_requests support_access_requests_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_access_requests
    ADD CONSTRAINT support_access_requests_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: support_access_requests support_access_requests_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_access_requests
    ADD CONSTRAINT support_access_requests_revoked_by_fkey FOREIGN KEY (revoked_by) REFERENCES auth.users(id);


--
-- Name: support_access_requests support_access_requests_support_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_access_requests
    ADD CONSTRAINT support_access_requests_support_user_id_fkey FOREIGN KEY (support_user_id) REFERENCES auth.users(id);


--
-- Name: support_audit_events support_audit_events_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_audit_events
    ADD CONSTRAINT support_audit_events_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES auth.users(id);


--
-- Name: support_audit_events support_audit_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_audit_events
    ADD CONSTRAINT support_audit_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: support_audit_events support_audit_events_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_audit_events
    ADD CONSTRAINT support_audit_events_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.support_access_requests(id) ON DELETE SET NULL;


--
-- Name: team_invitations team_invitations_accepted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_invitations
    ADD CONSTRAINT team_invitations_accepted_by_fkey FOREIGN KEY (accepted_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: team_invitations team_invitations_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_invitations
    ADD CONSTRAINT team_invitations_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: team_invitations team_invitations_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_invitations
    ADD CONSTRAINT team_invitations_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_edit_audit
    ADD CONSTRAINT timekeeping_edit_audit_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_edit_audit
    ADD CONSTRAINT timekeeping_edit_audit_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE SET NULL;


--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_edited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_edit_audit
    ADD CONSTRAINT timekeeping_edit_audit_edited_by_fkey FOREIGN KEY (edited_by) REFERENCES public.profiles(id) ON DELETE RESTRICT;


--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_edit_audit
    ADD CONSTRAINT timekeeping_edit_audit_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.timekeeping_employees(id) ON DELETE RESTRICT;


--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_timekeeping_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_edit_audit
    ADD CONSTRAINT timekeeping_edit_audit_timekeeping_entry_id_fkey FOREIGN KEY (timekeeping_entry_id) REFERENCES public.timekeeping_entries(id) ON DELETE CASCADE;


--
-- Name: timekeeping_employees timekeeping_employees_admin_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_admin_assigned_by_fkey FOREIGN KEY (admin_assigned_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_employees timekeeping_employees_assigned_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_employees timekeeping_employees_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_employees timekeeping_employees_assigned_foreman_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_assigned_foreman_id_fkey FOREIGN KEY (assigned_foreman_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_employees timekeeping_employees_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_employees timekeeping_employees_linked_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_employees
    ADD CONSTRAINT timekeeping_employees_linked_profile_id_fkey FOREIGN KEY (linked_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_entries timekeeping_entries_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entries
    ADD CONSTRAINT timekeeping_entries_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_entries timekeeping_entries_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entries
    ADD CONSTRAINT timekeeping_entries_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE SET NULL;


--
-- Name: timekeeping_entries timekeeping_entries_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entries
    ADD CONSTRAINT timekeeping_entries_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.timekeeping_employees(id) ON DELETE RESTRICT;


--
-- Name: timekeeping_entries timekeeping_entries_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entries
    ADD CONSTRAINT timekeeping_entries_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE RESTRICT;


--
-- Name: timekeeping_entry_history timekeeping_entry_history_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entry_history
    ADD CONSTRAINT timekeeping_entry_history_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_entry_history timekeeping_entry_history_daily_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entry_history
    ADD CONSTRAINT timekeeping_entry_history_daily_report_id_fkey FOREIGN KEY (daily_report_id) REFERENCES public.daily_reports(id) ON DELETE SET NULL;


--
-- Name: timekeeping_entry_history timekeeping_entry_history_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entry_history
    ADD CONSTRAINT timekeeping_entry_history_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.timekeeping_employees(id) ON DELETE CASCADE;


--
-- Name: timekeeping_entry_history timekeeping_entry_history_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_entry_history
    ADD CONSTRAINT timekeeping_entry_history_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: timekeeping_equipment timekeeping_equipment_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_equipment
    ADD CONSTRAINT timekeeping_equipment_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_pay_period_audit timekeeping_pay_period_audit_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_period_audit
    ADD CONSTRAINT timekeeping_pay_period_audit_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_pay_period_audit timekeeping_pay_period_audit_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_period_audit
    ADD CONSTRAINT timekeeping_pay_period_audit_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_pay_periods timekeeping_pay_periods_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_periods
    ADD CONSTRAINT timekeeping_pay_periods_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: timekeeping_pay_periods timekeeping_pay_periods_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_periods
    ADD CONSTRAINT timekeeping_pay_periods_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: timekeeping_pay_periods timekeeping_pay_periods_locked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timekeeping_pay_periods
    ADD CONSTRAINT timekeeping_pay_periods_locked_by_fkey FOREIGN KEY (locked_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: training_progress training_progress_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_progress
    ADD CONSTRAINT training_progress_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: training_progress training_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_progress
    ADD CONSTRAINT training_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: training_progress training_progress_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.training_progress
    ADD CONSTRAINT training_progress_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.training_videos(id) ON DELETE CASCADE;


--
-- Name: unit_prices unit_prices_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_prices
    ADD CONSTRAINT unit_prices_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: unit_prices unit_prices_price_book_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_prices
    ADD CONSTRAINT unit_prices_price_book_id_fkey FOREIGN KEY (price_book_id) REFERENCES public.price_books(id) ON DELETE CASCADE;


--
-- Name: user_dashboard_preferences user_dashboard_preferences_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_dashboard_preferences
    ADD CONSTRAINT user_dashboard_preferences_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: user_dashboard_preferences user_dashboard_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_dashboard_preferences
    ADD CONSTRAINT user_dashboard_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: utility_packet_import_rows utility_packet_import_rows_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_import_rows
    ADD CONSTRAINT utility_packet_import_rows_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: utility_packet_import_rows utility_packet_import_rows_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_import_rows
    ADD CONSTRAINT utility_packet_import_rows_import_id_fkey FOREIGN KEY (import_id) REFERENCES public.utility_packet_imports(id) ON DELETE CASCADE;


--
-- Name: utility_packet_imports utility_packet_imports_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_imports
    ADD CONSTRAINT utility_packet_imports_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: utility_packet_imports utility_packet_imports_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_imports
    ADD CONSTRAINT utility_packet_imports_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: utility_packet_imports utility_packet_imports_job_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_imports
    ADD CONSTRAINT utility_packet_imports_job_package_id_fkey FOREIGN KEY (job_package_id) REFERENCES public.job_packages(id) ON DELETE CASCADE;


--
-- Name: utility_packet_imports utility_packet_imports_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_imports
    ADD CONSTRAINT utility_packet_imports_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: utility_packet_unit_aliases utility_packet_unit_aliases_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_unit_aliases
    ADD CONSTRAINT utility_packet_unit_aliases_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: utility_packet_unit_aliases utility_packet_unit_aliases_contract_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_unit_aliases
    ADD CONSTRAINT utility_packet_unit_aliases_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.contracts(id) ON DELETE CASCADE;


--
-- Name: utility_packet_unit_aliases utility_packet_unit_aliases_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_unit_aliases
    ADD CONSTRAINT utility_packet_unit_aliases_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: utility_packet_unit_aliases utility_packet_unit_aliases_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_packet_unit_aliases
    ADD CONSTRAINT utility_packet_unit_aliases_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: work_points work_points_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_points
    ADD CONSTRAINT work_points_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: work_points work_points_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_points
    ADD CONSTRAINT work_points_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: work_points work_points_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_points
    ADD CONSTRAINT work_points_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE CASCADE;


--
-- Name: daily_production_items Company users can create production items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Company users can create production items" ON public.daily_production_items FOR INSERT TO authenticated WITH CHECK ((company_id = public.my_company_id()));


--
-- Name: daily_production_items Company users can update production items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Company users can update production items" ON public.daily_production_items FOR UPDATE TO authenticated USING ((company_id = public.my_company_id())) WITH CHECK ((company_id = public.my_company_id()));


--
-- Name: daily_production_items Company users can view production items; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Company users can view production items" ON public.daily_production_items FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: companies active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.companies AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: contracts active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.contracts AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: customers active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.customers AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: daily_report_attachments active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.daily_report_attachments AS RESTRICTIVE TO authenticated USING (public.current_user_has_active_profile()) WITH CHECK (public.current_user_has_active_profile());


--
-- Name: daily_reports active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.daily_reports AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: jobs active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.jobs AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: jsa_upload_attachments active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.jsa_upload_attachments AS RESTRICTIVE TO authenticated USING (public.current_user_has_active_profile()) WITH CHECK (public.current_user_has_active_profile());


--
-- Name: price_book_items active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.price_book_items AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: price_books active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.price_books AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: profiles active_profile_required; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY active_profile_required ON public.profiles AS RESTRICTIVE TO authenticated USING (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)) WITH CHECK (( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile));


--
-- Name: app_error_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_error_events ENABLE ROW LEVEL SECURITY;

--
-- Name: assistant_memories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.assistant_memories ENABLE ROW LEVEL SECURITY;

--
-- Name: assistant_memories assistant_memories_owner_admin_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY assistant_memories_owner_admin_select ON public.assistant_memories FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.profiles profile
  WHERE ((profile.id = ( SELECT auth.uid() AS uid)) AND (profile.company_id = assistant_memories.company_id) AND (profile.active IS TRUE) AND (lower(COALESCE(profile.role, ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))))));


--
-- Name: audit_log audit_leadership_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY audit_leadership_select ON public.audit_log FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: beta_applications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.beta_applications ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_events ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_export_attachments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_export_attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_export_batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_export_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_export_lines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_export_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: companies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

--
-- Name: company_crew_usage_daily; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_crew_usage_daily ENABLE ROW LEVEL SECURITY;

--
-- Name: companies company_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY company_leadership_update ON public.companies FOR UPDATE TO authenticated USING (((id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])))) WITH CHECK (((id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: companies company_same_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY company_same_company_select ON public.companies FOR SELECT TO authenticated USING (((id = ( SELECT public.my_company_id() AS my_company_id)) OR (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: company_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: company_subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: contract_field_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contract_field_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: contracts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;

--
-- Name: contracts contracts_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_company_select ON public.contracts FOR SELECT TO authenticated USING ((company_id = ( SELECT public.my_company_id() AS my_company_id)));


--
-- Name: contracts contracts_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_leadership_delete ON public.contracts FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability)))));


--
-- Name: contracts contracts_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_leadership_insert ON public.contracts FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability)))));


--
-- Name: contracts contracts_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_leadership_update ON public.contracts FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability))))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability)))));


--
-- Name: crews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.crews ENABLE ROW LEVEL SECURITY;

--
-- Name: crews crews_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crews_leadership_insert ON public.crews FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: crews crews_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crews_leadership_update ON public.crews FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: crews crews_owner_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crews_owner_delete ON public.crews FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'owner'::text)));


--
-- Name: crews crews_same_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY crews_same_company_select ON public.crews FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: customers customers_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_company_select ON public.customers FOR SELECT TO authenticated USING ((company_id = ( SELECT public.my_company_id() AS my_company_id)));


--
-- Name: customers customers_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_leadership_delete ON public.customers FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability)))));


--
-- Name: customers customers_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_leadership_insert ON public.customers FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability)))));


--
-- Name: customers customers_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_leadership_update ON public.customers FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability))))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('customers_contracts'::text) AS linecrew_has_capability)))));


--
-- Name: daily_production_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_production_items ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_production_unit_locations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_production_unit_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_production_units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_production_units ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_attachments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_report_attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_attachments daily_report_attachments_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY daily_report_attachments_company_select ON public.daily_report_attachments FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: daily_report_audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_report_audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_jsas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_report_jsas ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_jsas daily_report_jsas_role_scoped_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY daily_report_jsas_role_scoped_select ON public.daily_report_jsas FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((created_by = ( SELECT auth.uid() AS uid)) OR (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('safety_records'::text) AS linecrew_has_capability)))));


--
-- Name: daily_report_units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_report_units ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_units daily_report_units_actual_pricing_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY daily_report_units_actual_pricing_select ON public.daily_report_units FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('actual_pricing'::text) AS linecrew_has_capability)))));


--
-- Name: daily_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_reports daily_reports_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY daily_reports_leadership_delete ON public.daily_reports FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: daily_reports daily_reports_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY daily_reports_leadership_update ON public.daily_reports FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: daily_reports daily_reports_role_scoped_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY daily_reports_role_scoped_select ON public.daily_reports FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND (( SELECT public.linecrew_has_capability('production_review'::text) AS linecrew_has_capability) OR ( SELECT public.linecrew_has_capability('reporting'::text) AS linecrew_has_capability))) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND ((foreman_id = ( SELECT auth.uid() AS uid)) OR (created_by = ( SELECT auth.uid() AS uid)))))));


--
-- Name: employees; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

--
-- Name: employees employees_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY employees_leadership_delete ON public.employees FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: employees employees_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY employees_leadership_insert ON public.employees FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: employees employees_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY employees_leadership_update ON public.employees FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: employees employees_same_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY employees_same_company_select ON public.employees FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: gf_foreman_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gf_foreman_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: job_assignment_audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_assignment_audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: job_closeout_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_closeout_history ENABLE ROW LEVEL SECURITY;

--
-- Name: job_leader_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_leader_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: job_leader_assignments job_leader_assignments_role_scoped_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY job_leader_assignments_role_scoped_select ON public.job_leader_assignments FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((member_id = ( SELECT auth.uid() AS uid)) OR (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('jobs'::text) AS linecrew_has_capability)))));


--
-- Name: job_package_authorized_units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_package_authorized_units ENABLE ROW LEVEL SECURITY;

--
-- Name: job_package_work_points; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_package_work_points ENABLE ROW LEVEL SECURITY;

--
-- Name: job_packages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_packages ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs jobs_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY jobs_leadership_delete ON public.jobs FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('jobs'::text) AS linecrew_has_capability)))));


--
-- Name: jobs jobs_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY jobs_leadership_insert ON public.jobs FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('jobs'::text) AS linecrew_has_capability)))));


--
-- Name: jobs jobs_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY jobs_leadership_update ON public.jobs FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('jobs'::text) AS linecrew_has_capability))))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('jobs'::text) AS linecrew_has_capability)))));


--
-- Name: jobs jobs_role_scoped_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY jobs_role_scoped_select ON public.jobs FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('jobs'::text) AS linecrew_has_capability)) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND ( SELECT public.linecrew_foreman_has_job_assignment(jobs.id) AS linecrew_foreman_has_job_assignment)))));


--
-- Name: jsa_upload_attachments jsa attachment role scoped read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "jsa attachment role scoped read" ON public.jsa_upload_attachments FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (EXISTS ( SELECT 1
   FROM public.daily_report_jsas j
  WHERE ((j.id = jsa_upload_attachments.jsa_id) AND (j.company_id = jsa_upload_attachments.company_id))))));


--
-- Name: jsa_upload_attachments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.jsa_upload_attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: pilot_feedback; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pilot_feedback ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_owner_audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_owner_audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_owners; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_owners ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_support_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_support_users ENABLE ROW LEVEL SECURITY;

--
-- Name: price_book_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.price_book_items ENABLE ROW LEVEL SECURITY;

--
-- Name: price_book_items price_book_items_actual_pricing_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_book_items_actual_pricing_select ON public.price_book_items FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('actual_pricing'::text) AS linecrew_has_capability)))));


--
-- Name: price_book_items price_book_items_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_book_items_leadership_delete ON public.price_book_items FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: price_book_items price_book_items_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_book_items_leadership_insert ON public.price_book_items FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: price_book_items price_book_items_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_book_items_leadership_update ON public.price_book_items FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: price_books; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.price_books ENABLE ROW LEVEL SECURITY;

--
-- Name: price_books price_books_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_books_leadership_delete ON public.price_books FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: price_books price_books_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_books_leadership_insert ON public.price_books FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: price_books price_books_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_books_leadership_update ON public.price_books FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: price_books price_books_same_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY price_books_same_company_select ON public.price_books FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: daily_production_items production_items_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY production_items_leadership_delete ON public.daily_production_items FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_same_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_same_company_select ON public.profiles FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) OR (id = ( SELECT auth.uid() AS uid))));


--
-- Name: report_units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.report_units ENABLE ROW LEVEL SECURITY;

--
-- Name: report_units report_units_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY report_units_company_select ON public.report_units FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: report_units report_units_foreman_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY report_units_foreman_insert ON public.report_units FOR INSERT TO authenticated WITH CHECK ((company_id = public.my_company_id()));


--
-- Name: report_units report_units_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY report_units_leadership_delete ON public.report_units FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: report_units report_units_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY report_units_leadership_update ON public.report_units FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: daily_reports reports_foreman_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY reports_foreman_insert ON public.daily_reports FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (foreman_id = ( SELECT auth.uid() AS uid))));


--
-- Name: app_error_events server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.app_error_events AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: billing_export_attachments server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.billing_export_attachments AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: billing_export_batches server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.billing_export_batches AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: billing_export_lines server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.billing_export_lines AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: contract_field_settings server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.contract_field_settings AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: daily_production_unit_locations server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.daily_production_unit_locations AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: daily_production_units server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.daily_production_units AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: daily_report_audit_events server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.daily_report_audit_events AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: job_assignment_audit_events server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.job_assignment_audit_events AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: job_closeout_history server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.job_closeout_history AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: job_package_authorized_units server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.job_package_authorized_units AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: job_package_work_points server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.job_package_work_points AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: job_packages server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.job_packages AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: pilot_feedback server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.pilot_feedback AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: platform_support_users server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.platform_support_users AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: storm_mode_assignments server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.storm_mode_assignments AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: support_access_requests server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.support_access_requests AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: support_audit_events server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.support_audit_events AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: team_invitations server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.team_invitations AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: utility_packet_import_rows server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.utility_packet_import_rows AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: utility_packet_imports server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.utility_packet_imports AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: work_points server_only_no_direct_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY server_only_no_direct_access ON public.work_points AS RESTRICTIVE USING (false) WITH CHECK (false);


--
-- Name: company_settings settings_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_leadership_update ON public.company_settings FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: company_settings settings_same_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_same_company_select ON public.company_settings FOR SELECT TO authenticated USING ((company_id = public.my_company_id()));


--
-- Name: storm_mode_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.storm_mode_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: support_access_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.support_access_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: support_audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.support_audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: team_invitations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.team_invitations ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_edit_audit; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_edit_audit ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_edit_audit timekeeping_edit_audit_admin_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_edit_audit_admin_select ON public.timekeeping_edit_audit FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: timekeeping_employees; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_employees ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_employees timekeeping_employees_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_employees_leadership_delete ON public.timekeeping_employees FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: timekeeping_employees timekeeping_employees_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_employees_leadership_insert ON public.timekeeping_employees FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: timekeeping_employees timekeeping_employees_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_employees_leadership_update ON public.timekeeping_employees FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text]))));


--
-- Name: timekeeping_employees timekeeping_employees_role_scoped_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_employees_role_scoped_select ON public.timekeeping_employees FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('reporting'::text) AS linecrew_has_capability)) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND (active IS TRUE)) OR (linked_profile_id = ( SELECT auth.uid() AS uid)))));


--
-- Name: timekeeping_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_entries timekeeping_entries_delete_company; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_entries_delete_company ON public.timekeeping_entries FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((created_by = ( SELECT auth.uid() AS uid)) OR (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['gf'::text, 'admin'::text, 'owner'::text])) OR ((entry_kind = 'leadership_self'::text) AND (EXISTS ( SELECT 1
   FROM public.timekeeping_employees employee
  WHERE ((employee.id = timekeeping_entries.employee_id) AND (employee.company_id = timekeeping_entries.company_id) AND (employee.linked_profile_id = ( SELECT auth.uid() AS uid)))))))));


--
-- Name: timekeeping_entries timekeeping_entries_role_scoped_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_entries_role_scoped_insert ON public.timekeeping_entries FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (created_by = ( SELECT auth.uid() AS uid)) AND (updated_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.timekeeping_employees employee
  WHERE ((employee.id = timekeeping_entries.employee_id) AND (employee.company_id = timekeeping_entries.company_id) AND (employee.active IS TRUE) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND ( SELECT public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id) AS linecrew_foreman_has_job_assignment)) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['gf'::text, 'superintendent'::text, 'admin'::text, 'owner'::text])) AND (timekeeping_entries.entry_kind = 'leadership_self'::text) AND (timekeeping_entries.daily_report_id IS NULL) AND (employee.linked_profile_id = ( SELECT auth.uid() AS uid)))))))));


--
-- Name: timekeeping_entries timekeeping_entries_role_scoped_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_entries_role_scoped_update ON public.timekeeping_entries FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR (created_by = ( SELECT auth.uid() AS uid)) OR ((entry_kind = 'leadership_self'::text) AND (EXISTS ( SELECT 1
   FROM public.timekeeping_employees employee
  WHERE ((employee.id = timekeeping_entries.employee_id) AND (employee.company_id = timekeeping_entries.company_id) AND (employee.linked_profile_id = ( SELECT auth.uid() AS uid))))))))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (updated_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.timekeeping_employees employee
  WHERE ((employee.id = timekeeping_entries.employee_id) AND (employee.company_id = timekeeping_entries.company_id) AND (employee.active IS TRUE) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND ( SELECT public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id) AS linecrew_foreman_has_job_assignment)) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['gf'::text, 'superintendent'::text, 'admin'::text, 'owner'::text])) AND (timekeeping_entries.entry_kind = 'leadership_self'::text) AND (timekeeping_entries.daily_report_id IS NULL) AND (employee.linked_profile_id = ( SELECT auth.uid() AS uid)))))))));


--
-- Name: timekeeping_entries timekeeping_entries_select_company; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_entries_select_company ON public.timekeeping_entries FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['gf'::text, 'admin'::text, 'owner'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('reporting'::text) AS linecrew_has_capability)) OR ((entry_kind = 'leadership_self'::text) AND (EXISTS ( SELECT 1
   FROM public.timekeeping_employees employee
  WHERE ((employee.id = timekeeping_entries.employee_id) AND (employee.company_id = timekeeping_entries.company_id) AND (employee.linked_profile_id = ( SELECT auth.uid() AS uid)))))) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND ((created_by = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM public.timekeeping_employees employee
  WHERE ((employee.id = timekeeping_entries.employee_id) AND (employee.company_id = timekeeping_entries.company_id) AND (employee.assigned_foreman_id = ( SELECT auth.uid() AS uid))))))))));


--
-- Name: timekeeping_entry_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_entry_history ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_entry_history timekeeping_entry_history_select_company; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_entry_history_select_company ON public.timekeeping_entry_history FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['gf'::text, 'admin'::text, 'owner'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('reporting'::text) AS linecrew_has_capability)) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'foreman'::text) AND ((created_by = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM public.timekeeping_employees te
  WHERE ((te.id = timekeeping_entry_history.employee_id) AND (te.company_id = timekeeping_entry_history.company_id) AND (te.assigned_foreman_id = ( SELECT auth.uid() AS uid))))))))));


--
-- Name: timekeeping_equipment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_equipment ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_equipment timekeeping_equipment_admin_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_equipment_admin_delete ON public.timekeeping_equipment FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: timekeeping_equipment timekeeping_equipment_admin_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_equipment_admin_insert ON public.timekeeping_equipment FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: timekeeping_equipment timekeeping_equipment_admin_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_equipment_admin_update ON public.timekeeping_equipment FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: timekeeping_equipment timekeeping_equipment_company_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_equipment_company_select ON public.timekeeping_equipment FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)));


--
-- Name: timekeeping_pay_period_audit; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_pay_period_audit ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_pay_period_audit timekeeping_pay_period_audit_select_company; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_pay_period_audit_select_company ON public.timekeeping_pay_period_audit FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)));


--
-- Name: timekeeping_pay_periods; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timekeeping_pay_periods ENABLE ROW LEVEL SECURITY;

--
-- Name: timekeeping_pay_periods timekeeping_pay_periods_select_company; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY timekeeping_pay_periods_select_company ON public.timekeeping_pay_periods FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile)));


--
-- Name: training_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.training_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: training_progress training_progress_read_own_company; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY training_progress_read_own_company ON public.training_progress FOR SELECT TO authenticated USING (((user_id = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND (p.company_id = training_progress.company_id) AND (lower(COALESCE(p.role, ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])) AND COALESCE(p.active, true))))));


--
-- Name: training_progress training_progress_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY training_progress_update_own ON public.training_progress FOR UPDATE TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: training_progress training_progress_write_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY training_progress_write_own ON public.training_progress FOR INSERT TO authenticated WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.current_training_access() a(company_id, role, subscription_status, can_train)
  WHERE ((a.company_id = training_progress.company_id) AND a.can_train)))));


--
-- Name: training_videos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.training_videos ENABLE ROW LEVEL SECURITY;

--
-- Name: training_videos training_videos_subscriber_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY training_videos_subscriber_read ON public.training_videos FOR SELECT TO authenticated USING (((active IS TRUE) AND (EXISTS ( SELECT 1
   FROM public.current_training_access() a(company_id, role, subscription_status, can_train)
  WHERE ((a.can_train IS TRUE) AND (public.training_role_rank(a.role) >= public.training_role_rank(training_videos.minimum_role)))))));


--
-- Name: unit_prices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.unit_prices ENABLE ROW LEVEL SECURITY;

--
-- Name: unit_prices unit_prices_actual_pricing_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY unit_prices_actual_pricing_select ON public.unit_prices FOR SELECT TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND ( SELECT public.current_user_has_active_profile() AS current_user_has_active_profile) AND ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = 'superintendent'::text) AND ( SELECT public.linecrew_has_capability('actual_pricing'::text) AS linecrew_has_capability)))));


--
-- Name: unit_prices unit_prices_leadership_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY unit_prices_leadership_delete ON public.unit_prices FOR DELETE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: unit_prices unit_prices_leadership_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY unit_prices_leadership_insert ON public.unit_prices FOR INSERT TO authenticated WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: unit_prices unit_prices_leadership_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY unit_prices_leadership_update ON public.unit_prices FOR UPDATE TO authenticated USING (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text])))) WITH CHECK (((company_id = ( SELECT public.my_company_id() AS my_company_id)) AND (lower(COALESCE(( SELECT public.my_role() AS my_role), ''::text)) = ANY (ARRAY['owner'::text, 'admin'::text]))));


--
-- Name: user_dashboard_preferences; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_dashboard_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: user_dashboard_preferences user_dashboard_preferences_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_dashboard_preferences_insert_own ON public.user_dashboard_preferences FOR INSERT TO authenticated WITH CHECK (((( SELECT auth.uid() AS uid) = user_id) AND (EXISTS ( SELECT 1
   FROM public.profiles profile
  WHERE ((profile.id = ( SELECT auth.uid() AS uid)) AND (profile.company_id = user_dashboard_preferences.company_id) AND (profile.active IS TRUE) AND (lower(COALESCE(profile.role, ''::text)) = ANY (ARRAY['admin'::text, 'owner'::text])))))));


--
-- Name: user_dashboard_preferences user_dashboard_preferences_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_dashboard_preferences_select_own ON public.user_dashboard_preferences FOR SELECT TO authenticated USING (((( SELECT auth.uid() AS uid) = user_id) AND (EXISTS ( SELECT 1
   FROM public.profiles profile
  WHERE ((profile.id = ( SELECT auth.uid() AS uid)) AND (profile.company_id = user_dashboard_preferences.company_id) AND (profile.active IS TRUE) AND (lower(COALESCE(profile.role, ''::text)) = ANY (ARRAY['admin'::text, 'owner'::text])))))));


--
-- Name: user_dashboard_preferences user_dashboard_preferences_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_dashboard_preferences_update_own ON public.user_dashboard_preferences FOR UPDATE TO authenticated USING (((( SELECT auth.uid() AS uid) = user_id) AND (EXISTS ( SELECT 1
   FROM public.profiles profile
  WHERE ((profile.id = ( SELECT auth.uid() AS uid)) AND (profile.company_id = user_dashboard_preferences.company_id) AND (profile.active IS TRUE) AND (lower(COALESCE(profile.role, ''::text)) = ANY (ARRAY['admin'::text, 'owner'::text]))))))) WITH CHECK (((( SELECT auth.uid() AS uid) = user_id) AND (EXISTS ( SELECT 1
   FROM public.profiles profile
  WHERE ((profile.id = ( SELECT auth.uid() AS uid)) AND (profile.company_id = user_dashboard_preferences.company_id) AND (profile.active IS TRUE) AND (lower(COALESCE(profile.role, ''::text)) = ANY (ARRAY['admin'::text, 'owner'::text])))))));


--
-- Name: utility_packet_import_rows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.utility_packet_import_rows ENABLE ROW LEVEL SECURITY;

--
-- Name: utility_packet_imports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.utility_packet_imports ENABLE ROW LEVEL SECURITY;

--
-- Name: utility_packet_unit_aliases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.utility_packet_unit_aliases ENABLE ROW LEVEL SECURITY;

--
-- Name: work_points; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.work_points ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION accept_team_invitation(p_token_hash text, p_user_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.accept_team_invitation(p_token_hash text, p_user_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.accept_team_invitation(p_token_hash text, p_user_name text) TO authenticated;
GRANT ALL ON FUNCTION public.accept_team_invitation(p_token_hash text, p_user_name text) TO service_role;


--
-- Name: FUNCTION activate_finalized_utility_packet_revision(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activate_finalized_utility_packet_revision() FROM PUBLIC;
GRANT ALL ON FUNCTION public.activate_finalized_utility_packet_revision() TO service_role;


--
-- Name: FUNCTION add_daily_report_unit(p_report_id uuid, p_work_point text, p_unit_code text, p_description text, p_installed_qty numeric, p_retired_qty numeric, p_install_unit_price numeric, p_retire_unit_price numeric, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.add_daily_report_unit(p_report_id uuid, p_work_point text, p_unit_code text, p_description text, p_installed_qty numeric, p_retired_qty numeric, p_install_unit_price numeric, p_retire_unit_price numeric, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_daily_report_unit(p_report_id uuid, p_work_point text, p_unit_code text, p_description text, p_installed_qty numeric, p_retired_qty numeric, p_install_unit_price numeric, p_retire_unit_price numeric, p_notes text) TO service_role;


--
-- Name: FUNCTION admin_create_price_book(p_name text, p_customer_name text, p_utility_name text, p_effective_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_create_price_book(p_name text, p_customer_name text, p_utility_name text, p_effective_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_create_price_book(p_name text, p_customer_name text, p_utility_name text, p_effective_date date) TO service_role;


--
-- Name: FUNCTION admin_delete_price_book(p_price_book_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_delete_price_book(p_price_book_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_delete_price_book(p_price_book_id uuid) TO service_role;


--
-- Name: FUNCTION admin_delete_unit_price(p_unit_price_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_delete_unit_price(p_unit_price_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_delete_unit_price(p_unit_price_id uuid) TO service_role;


--
-- Name: FUNCTION admin_import_timekeeping_roster(p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_import_timekeeping_roster(p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_import_timekeeping_roster(p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.admin_import_timekeeping_roster(p_rows jsonb) TO service_role;


--
-- Name: FUNCTION admin_save_unit_price(p_price_book_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_save_unit_price(p_price_book_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_save_unit_price(p_price_book_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric) TO service_role;


--
-- Name: FUNCTION admin_update_company_settings(p_adjustment_enabled boolean, p_adjustment_percent numeric, p_adjustment_label text, p_primary_color text, p_secondary_color text, p_logo_url text, p_gf_can_edit_reports boolean, p_gf_can_delete_reports boolean, p_location_label text, p_job_label text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_update_company_settings(p_adjustment_enabled boolean, p_adjustment_percent numeric, p_adjustment_label text, p_primary_color text, p_secondary_color text, p_logo_url text, p_gf_can_edit_reports boolean, p_gf_can_delete_reports boolean, p_location_label text, p_job_label text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_update_company_settings(p_adjustment_enabled boolean, p_adjustment_percent numeric, p_adjustment_label text, p_primary_color text, p_secondary_color text, p_logo_url text, p_gf_can_edit_reports boolean, p_gf_can_delete_reports boolean, p_location_label text, p_job_label text) TO service_role;


--
-- Name: FUNCTION admin_update_timekeeping_entry(p_daily_report_id uuid, p_employee_id uuid, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_regular_hours numeric, p_overtime_hours numeric, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_update_timekeeping_entry(p_daily_report_id uuid, p_employee_id uuid, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_regular_hours numeric, p_overtime_hours numeric, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_update_timekeeping_entry(p_daily_report_id uuid, p_employee_id uuid, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_regular_hours numeric, p_overtime_hours numeric, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_update_timekeeping_entry(p_daily_report_id uuid, p_employee_id uuid, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_regular_hours numeric, p_overtime_hours numeric, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_reason text) TO service_role;


--
-- Name: FUNCTION admin_update_unit_price(p_unit_price_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric, p_active boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_update_unit_price(p_unit_price_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_update_unit_price(p_unit_price_id uuid, p_unit text, p_description text, p_install numeric, p_remove numeric, p_transfer numeric, p_active boolean) TO service_role;


--
-- Name: FUNCTION admin_update_user(target_user_id uuid, new_role text, new_active boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_update_user(target_user_id uuid, new_role text, new_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_update_user(target_user_id uuid, new_role text, new_active boolean) TO service_role;


--
-- Name: FUNCTION approve_daily_report(p_report_id uuid, p_review_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.approve_daily_report(p_report_id uuid, p_review_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.approve_daily_report(p_report_id uuid, p_review_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.approve_daily_report(p_report_id uuid, p_review_notes text) TO service_role;


--
-- Name: FUNCTION archive_timekeeping_segment_on_report_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.archive_timekeeping_segment_on_report_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.archive_timekeeping_segment_on_report_change() TO service_role;


--
-- Name: FUNCTION assign_job_package_revision(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assign_job_package_revision() FROM PUBLIC;
GRANT ALL ON FUNCTION public.assign_job_package_revision() TO service_role;


--
-- Name: FUNCTION audit_returned_unit_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.audit_returned_unit_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.audit_returned_unit_change() TO service_role;


--
-- Name: FUNCTION backup_public_table_inventory(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.backup_public_table_inventory() FROM PUBLIC;
GRANT ALL ON FUNCTION public.backup_public_table_inventory() TO service_role;


--
-- Name: FUNCTION can_review_daily_reports(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_review_daily_reports() FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_review_daily_reports() TO authenticated;
GRANT ALL ON FUNCTION public.can_review_daily_reports() TO service_role;


--
-- Name: FUNCTION capture_all_company_crew_usage(p_usage_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capture_all_company_crew_usage(p_usage_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.capture_all_company_crew_usage(p_usage_date date) TO service_role;


--
-- Name: FUNCTION capture_company_crew_usage(p_company_id uuid, p_usage_date date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capture_company_crew_usage(p_company_id uuid, p_usage_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.capture_company_crew_usage(p_company_id uuid, p_usage_date date) TO service_role;


--
-- Name: FUNCTION capture_company_storm_toggle_usage(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capture_company_storm_toggle_usage() FROM PUBLIC;
GRANT ALL ON FUNCTION public.capture_company_storm_toggle_usage() TO service_role;


--
-- Name: FUNCTION capture_crew_usage_from_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.capture_crew_usage_from_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.capture_crew_usage_from_change() TO service_role;


--
-- Name: FUNCTION company_decide_support_request(p_request_id uuid, p_approve boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_decide_support_request(p_request_id uuid, p_approve boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_decide_support_request(p_request_id uuid, p_approve boolean) TO authenticated;
GRANT ALL ON FUNCTION public.company_decide_support_request(p_request_id uuid, p_approve boolean) TO service_role;


--
-- Name: FUNCTION company_list_support_requests(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_list_support_requests() FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_list_support_requests() TO authenticated;
GRANT ALL ON FUNCTION public.company_list_support_requests() TO service_role;


--
-- Name: FUNCTION company_revoke_support_access(p_request_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_revoke_support_access(p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_revoke_support_access(p_request_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.company_revoke_support_access(p_request_id uuid) TO service_role;


--
-- Name: FUNCTION company_support_audit_history(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_support_audit_history() FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_support_audit_history() TO authenticated;
GRANT ALL ON FUNCTION public.company_support_audit_history() TO service_role;


--
-- Name: FUNCTION complete_assistant_memory(p_memory_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_assistant_memory(p_memory_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_assistant_memory(p_memory_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.complete_assistant_memory(p_memory_id uuid) TO authenticated;


--
-- Name: FUNCTION complete_team_invitation_signup(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_team_invitation_signup() FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_team_invitation_signup() TO service_role;


--
-- Name: FUNCTION create_and_stage_utility_packet_import(p_job_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_and_stage_utility_packet_import(p_job_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_and_stage_utility_packet_import(p_job_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_and_stage_utility_packet_import(p_job_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION create_assistant_memory(p_memory_type text, p_title text, p_instruction text, p_trigger_type text, p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_assistant_memory(p_memory_type text, p_title text, p_instruction text, p_trigger_type text, p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_assistant_memory(p_memory_type text, p_title text, p_instruction text, p_trigger_type text, p_job_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.create_assistant_memory(p_memory_type text, p_title text, p_instruction text, p_trigger_type text, p_job_id uuid) TO authenticated;


--
-- Name: FUNCTION create_billing_credit_batch(p_paid_batch_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_billing_credit_batch(p_paid_batch_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_billing_credit_batch(p_paid_batch_id uuid, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.create_billing_credit_batch(p_paid_batch_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION create_billing_export_batch(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_billing_export_batch(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_billing_export_batch(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text) TO service_role;


--
-- Name: FUNCTION create_billing_export_batch_v2(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text, p_is_final boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_billing_export_batch_v2(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text, p_is_final boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_billing_export_batch_v2(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text, p_is_final boolean) TO service_role;


--
-- Name: FUNCTION create_billing_export_batch_v3(p_job_id uuid, p_date_from date, p_date_to date, p_separate_redline_summary boolean, p_notes text, p_is_final boolean, p_final_override_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_billing_export_batch_v3(p_job_id uuid, p_date_from date, p_date_to date, p_separate_redline_summary boolean, p_notes text, p_is_final boolean, p_final_override_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_billing_export_batch_v3(p_job_id uuid, p_date_from date, p_date_to date, p_separate_redline_summary boolean, p_notes text, p_is_final boolean, p_final_override_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.create_billing_export_batch_v3(p_job_id uuid, p_date_from date, p_date_to date, p_separate_redline_summary boolean, p_notes text, p_is_final boolean, p_final_override_reason text) TO service_role;


--
-- Name: FUNCTION create_company(company_name text, admin_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_company(company_name text, admin_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_company(company_name text, admin_name text) TO authenticated;
GRANT ALL ON FUNCTION public.create_company(company_name text, admin_name text) TO service_role;


--
-- Name: FUNCTION create_contract_job(p_contract_id uuid, p_job_number text, p_job_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_contract_job(p_contract_id uuid, p_job_number text, p_job_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_contract_job(p_contract_id uuid, p_job_number text, p_job_name text) TO authenticated;
GRANT ALL ON FUNCTION public.create_contract_job(p_contract_id uuid, p_job_number text, p_job_name text) TO service_role;


--
-- Name: FUNCTION create_daily_report(p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_daily_report(p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_daily_report(p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.create_daily_report(p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) TO service_role;


--
-- Name: FUNCTION create_job(p_job_number text, p_job_name text, p_customer_name text, p_utility_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_job(p_job_number text, p_job_name text, p_customer_name text, p_utility_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_job(p_job_number text, p_job_name text, p_customer_name text, p_utility_name text) TO authenticated;
GRANT ALL ON FUNCTION public.create_job(p_job_number text, p_job_name text, p_customer_name text, p_utility_name text) TO service_role;


--
-- Name: FUNCTION create_job_package(p_job_id uuid, p_package_name text, p_package_number text, p_received_date date, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_job_package(p_job_id uuid, p_package_name text, p_package_number text, p_received_date date, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_job_package(p_job_id uuid, p_package_name text, p_package_number text, p_received_date date, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.create_job_package(p_job_id uuid, p_package_name text, p_package_number text, p_received_date date, p_notes text) TO service_role;


--
-- Name: FUNCTION create_job_package_from_file(p_job_id uuid, p_source_filename text, p_detected_reference text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_job_package_from_file(p_job_id uuid, p_source_filename text, p_detected_reference text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_job_package_from_file(p_job_id uuid, p_source_filename text, p_detected_reference text) TO service_role;


--
-- Name: FUNCTION create_job_package_work_point(p_package_id uuid, p_work_point_code text, p_description text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_job_package_work_point(p_package_id uuid, p_work_point_code text, p_description text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_job_package_work_point(p_package_id uuid, p_work_point_code text, p_description text) TO authenticated;
GRANT ALL ON FUNCTION public.create_job_package_work_point(p_package_id uuid, p_work_point_code text, p_description text) TO service_role;


--
-- Name: FUNCTION create_standalone_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_standalone_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_standalone_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean) TO authenticated;
GRANT ALL ON FUNCTION public.create_standalone_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean) TO service_role;


--
-- Name: FUNCTION create_standalone_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_standalone_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_standalone_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_standalone_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) TO service_role;


--
-- Name: FUNCTION create_standalone_jsa_v2(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_standalone_jsa_v2(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_standalone_jsa_v2(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_standalone_jsa_v2(p_job_id uuid, p_work_date date, p_crew_name text, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_weather_conditions text, p_special_equipment text, p_foreman_acknowledged boolean, p_details jsonb) TO service_role;


--
-- Name: FUNCTION create_team_invitation(p_email text, p_token_hash text, p_expires_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_team_invitation(p_email text, p_token_hash text, p_expires_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_team_invitation(p_email text, p_token_hash text, p_expires_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.create_team_invitation(p_email text, p_token_hash text, p_expires_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION create_uploaded_company_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_uploaded_company_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_uploaded_company_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.create_uploaded_company_jsa(p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) TO service_role;


--
-- Name: FUNCTION create_uploaded_company_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_uploaded_company_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_uploaded_company_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.create_uploaded_company_jsa_offline(p_client_submission_id uuid, p_job_id uuid, p_work_date date, p_crew_name text, p_notes text) TO service_role;


--
-- Name: FUNCTION current_training_access(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.current_training_access() FROM PUBLIC;
GRANT ALL ON FUNCTION public.current_training_access() TO authenticated;
GRANT ALL ON FUNCTION public.current_training_access() TO service_role;


--
-- Name: FUNCTION current_user_has_active_profile(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.current_user_has_active_profile() FROM PUBLIC;
GRANT ALL ON FUNCTION public.current_user_has_active_profile() TO authenticated;
GRANT ALL ON FUNCTION public.current_user_has_active_profile() TO service_role;


--
-- Name: FUNCTION delete_billing_export_attachment(p_attachment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_billing_export_attachment(p_attachment_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_billing_export_attachment(p_attachment_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_billing_export_attachment(p_attachment_id uuid) TO service_role;


--
-- Name: FUNCTION delete_daily_report_attachment(p_attachment_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_daily_report_attachment(p_attachment_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_daily_report_attachment(p_attachment_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_daily_report_attachment(p_attachment_id uuid) TO service_role;


--
-- Name: FUNCTION delete_daily_report_unit(p_unit_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_daily_report_unit(p_unit_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_daily_report_unit(p_unit_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_daily_report_unit(p_unit_id uuid) TO service_role;


--
-- Name: FUNCTION delete_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid) TO service_role;


--
-- Name: FUNCTION delete_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) TO authenticated;
GRANT ALL ON FUNCTION public.delete_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) TO service_role;


--
-- Name: FUNCTION delete_draft_daily_report(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_draft_daily_report(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_draft_daily_report(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_draft_daily_report(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION delete_job(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_job(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_job(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_job(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION delete_job_package(p_package_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_job_package(p_package_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_job_package(p_package_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_job_package(p_package_id uuid) TO service_role;


--
-- Name: FUNCTION delete_job_package_authorized_unit(p_authorized_unit_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_job_package_authorized_unit(p_authorized_unit_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_job_package_authorized_unit(p_authorized_unit_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_job_package_authorized_unit(p_authorized_unit_id uuid) TO service_role;


--
-- Name: FUNCTION delete_job_package_work_point(p_work_point_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_job_package_work_point(p_work_point_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_job_package_work_point(p_work_point_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_job_package_work_point(p_work_point_id uuid) TO service_role;


--
-- Name: FUNCTION delete_uploaded_company_jsa(p_jsa_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_uploaded_company_jsa(p_jsa_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_uploaded_company_jsa(p_jsa_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_uploaded_company_jsa(p_jsa_id uuid) TO service_role;


--
-- Name: FUNCTION delete_void_billing_export_batch(p_batch_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_void_billing_export_batch(p_batch_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION enforce_active_crew_plan_limit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_active_crew_plan_limit() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_active_crew_plan_limit() TO service_role;


--
-- Name: FUNCTION enforce_active_job_for_daily_unit_mutation(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_active_job_for_daily_unit_mutation() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_active_job_for_daily_unit_mutation() TO service_role;


--
-- Name: FUNCTION enforce_draft_job_package_unit_mutation(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_draft_job_package_unit_mutation() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_draft_job_package_unit_mutation() TO service_role;


--
-- Name: FUNCTION enforce_foreman_assigned_job(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_foreman_assigned_job() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_foreman_assigned_job() TO service_role;


--
-- Name: FUNCTION enforce_linecrew_company_access(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_linecrew_company_access() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_linecrew_company_access() TO service_role;
GRANT ALL ON FUNCTION public.enforce_linecrew_company_access() TO authenticated;


--
-- Name: FUNCTION ensure_company_subscription(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ensure_company_subscription() FROM PUBLIC;
GRANT ALL ON FUNCTION public.ensure_company_subscription() TO service_role;


--
-- Name: FUNCTION finalize_job_package_spreadsheet_import(p_package_id uuid, p_rows jsonb, p_source_filename text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_job_package_spreadsheet_import(p_package_id uuid, p_rows jsonb, p_source_filename text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_job_package_spreadsheet_import(p_package_id uuid, p_rows jsonb, p_source_filename text) TO authenticated;
GRANT ALL ON FUNCTION public.finalize_job_package_spreadsheet_import(p_package_id uuid, p_rows jsonb, p_source_filename text) TO service_role;


--
-- Name: FUNCTION finalize_utility_packet_import(p_import_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_utility_packet_import(p_import_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_utility_packet_import(p_import_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.finalize_utility_packet_import(p_import_id uuid) TO service_role;


--
-- Name: FUNCTION finalize_utility_packet_import_review(p_import_id uuid, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_utility_packet_import_review(p_import_id uuid, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_utility_packet_import_review(p_import_id uuid, p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.finalize_utility_packet_import_review(p_import_id uuid, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION get_assignable_job_leaders(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_assignable_job_leaders() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_assignable_job_leaders() TO service_role;
GRANT ALL ON FUNCTION public.get_assignable_job_leaders() TO authenticated;


--
-- Name: FUNCTION get_billing_export_attachments(p_batch_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_billing_export_attachments(p_batch_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_billing_export_attachments(p_batch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_billing_export_attachments(p_batch_id uuid) TO service_role;


--
-- Name: FUNCTION get_billing_export_batch_lines(p_batch_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_billing_export_batch_lines(p_batch_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_billing_export_batch_lines(p_batch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_billing_export_batch_lines(p_batch_id uuid) TO service_role;


--
-- Name: FUNCTION get_billing_export_batches(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_billing_export_batches() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_billing_export_batches() TO service_role;


--
-- Name: FUNCTION get_billing_export_batches_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_billing_export_batches_v2() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_billing_export_batches_v2() TO service_role;


--
-- Name: FUNCTION get_billing_export_batches_v3(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_billing_export_batches_v3() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_billing_export_batches_v3() TO authenticated;
GRANT ALL ON FUNCTION public.get_billing_export_batches_v3() TO service_role;


--
-- Name: FUNCTION get_billing_export_batches_v4(p_archive_filter text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_billing_export_batches_v4(p_archive_filter text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_billing_export_batches_v4(p_archive_filter text) TO authenticated;
GRANT ALL ON FUNCTION public.get_billing_export_batches_v4(p_archive_filter text) TO service_role;


--
-- Name: FUNCTION get_company_general_foremen(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_company_general_foremen() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_company_general_foremen() TO authenticated;
GRANT ALL ON FUNCTION public.get_company_general_foremen() TO service_role;


--
-- Name: FUNCTION get_company_jsas(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_company_jsas() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_company_jsas() TO authenticated;
GRANT ALL ON FUNCTION public.get_company_jsas() TO service_role;


--
-- Name: FUNCTION get_company_jsas_scoped(p_show_all boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_company_jsas_scoped(p_show_all boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_company_jsas_scoped(p_show_all boolean) TO authenticated;
GRANT ALL ON FUNCTION public.get_company_jsas_scoped(p_show_all boolean) TO service_role;


--
-- Name: FUNCTION get_company_jsas_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_company_jsas_v2() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_company_jsas_v2() TO service_role;


--
-- Name: FUNCTION get_complete_job_billing_export_details_v1(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_complete_job_billing_export_details_v1(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_complete_job_billing_export_details_v1(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_complete_job_billing_export_details_v1(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_completed_job_export_details_v1(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_completed_job_export_details_v1(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_completed_job_export_details_v1(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_completed_job_export_details_v1(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_contract_field_settings(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_contract_field_settings() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_contract_field_settings() TO service_role;
GRANT ALL ON FUNCTION public.get_contract_field_settings() TO authenticated;


--
-- Name: FUNCTION get_daily_report_audit_history(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_audit_history(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_audit_history(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_audit_history(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_authorization_summaries(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_authorization_summaries() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_authorization_summaries() TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_authorization_summaries() TO service_role;


--
-- Name: FUNCTION get_daily_report_jsa(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_jsa(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_jsa(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_unit_authorized_action(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_unit_authorized_action(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_unit_authorized_action(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_unit_authorized_action(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) TO service_role;


--
-- Name: FUNCTION get_daily_report_unit_catalog(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_unit_catalog(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_unit_catalog(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_unit_catalog(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_unit_catalog_visible(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_unit_catalog_visible(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_unit_catalog_visible(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_unit_catalog_visible(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_unit_locations(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_unit_locations(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_unit_locations(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_unit_locations(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_unit_locations_v2(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_unit_locations_v2(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_unit_locations_v2(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_unit_locations_v2(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_unit_locations_visible_v2(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_unit_locations_visible_v2(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_unit_locations_visible_v2(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_unit_locations_visible_v2(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_daily_report_value_summaries(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_report_value_summaries() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_report_value_summaries() TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_report_value_summaries() TO service_role;


--
-- Name: FUNCTION get_daily_unit_usage_memory(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_daily_unit_usage_memory(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_daily_unit_usage_memory(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_daily_unit_usage_memory(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION get_gf_crew_assignment_roster(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_gf_crew_assignment_roster() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_gf_crew_assignment_roster() TO authenticated;
GRANT ALL ON FUNCTION public.get_gf_crew_assignment_roster() TO service_role;


--
-- Name: FUNCTION get_job_assignment_history(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_assignment_history(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_assignment_history(p_job_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.get_job_assignment_history(p_job_id uuid) TO authenticated;


--
-- Name: FUNCTION get_job_billing_reconciliation(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_billing_reconciliation(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_billing_reconciliation(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_billing_reconciliation(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_closeout_history(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_closeout_history(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_closeout_history(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_closeout_history(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_leader_assignments(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_leader_assignments() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_leader_assignments() TO service_role;
GRANT ALL ON FUNCTION public.get_job_leader_assignments() TO authenticated;


--
-- Name: FUNCTION get_job_package_revision_delta(p_package_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_package_revision_delta(p_package_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_package_revision_delta(p_package_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_package_revision_delta(p_package_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_package_revision_delta_v2(p_package_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_package_revision_delta_v2(p_package_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_package_revision_delta_v2(p_package_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_package_revision_delta_v2(p_package_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_package_work_points(p_package_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_package_work_points(p_package_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_package_work_points(p_package_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_package_work_points(p_package_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_package_work_points_v2(p_package_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_package_work_points_v2(p_package_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_package_work_points_v2(p_package_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_package_work_points_v2(p_package_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_packages(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_packages(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_packages(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_packages_v2(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_packages_v2(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_packages_v2(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_job_packages_v2(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_job_progress_dashboard(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_job_progress_dashboard() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_job_progress_dashboard() TO authenticated;
GRANT ALL ON FUNCTION public.get_job_progress_dashboard() TO service_role;


--
-- Name: FUNCTION get_jsa_upload_attachments(p_jsa_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_jsa_upload_attachments(p_jsa_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_jsa_upload_attachments(p_jsa_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_jsa_upload_attachments(p_jsa_id uuid) TO service_role;


--
-- Name: FUNCTION get_pending_utility_packet_import_for_package(p_package_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_pending_utility_packet_import_for_package(p_package_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_pending_utility_packet_import_for_package(p_package_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_pending_utility_packet_import_for_package(p_package_id uuid) TO service_role;


--
-- Name: FUNCTION get_price_book_items_for_user(p_price_book_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_price_book_items_for_user(p_price_book_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_price_book_items_for_user(p_price_book_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_price_book_items_for_user(p_price_book_id uuid) TO service_role;


--
-- Name: FUNCTION get_price_book_items_visible(p_price_book_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_price_book_items_visible(p_price_book_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_price_book_items_visible(p_price_book_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_price_book_items_visible(p_price_book_id uuid) TO service_role;


--
-- Name: FUNCTION get_remaining_job_units_for_field(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_remaining_job_units_for_field(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_remaining_job_units_for_field(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_remaining_job_units_for_field(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION get_storm_mode_assignments(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_storm_mode_assignments() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_storm_mode_assignments() TO authenticated;
GRANT ALL ON FUNCTION public.get_storm_mode_assignments() TO service_role;


--
-- Name: FUNCTION get_uploaded_company_jsas(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_uploaded_company_jsas() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_uploaded_company_jsas() TO authenticated;
GRANT ALL ON FUNCTION public.get_uploaded_company_jsas() TO service_role;


--
-- Name: FUNCTION get_utility_packet_import_review(p_import_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_utility_packet_import_review(p_import_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_utility_packet_import_review(p_import_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_utility_packet_import_review(p_import_id uuid) TO service_role;


--
-- Name: FUNCTION guard_timekeeping_locked_period(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_timekeeping_locked_period() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_timekeeping_locked_period() TO service_role;


--
-- Name: FUNCTION import_job_package_units(p_package_id uuid, p_rows jsonb, p_source_filename text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.import_job_package_units(p_package_id uuid, p_rows jsonb, p_source_filename text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_job_package_units(p_package_id uuid, p_rows jsonb, p_source_filename text) TO service_role;


--
-- Name: FUNCTION import_price_book_items_atomic(p_price_book_id uuid, p_rows jsonb, p_update_existing boolean, p_source_filename text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.import_price_book_items_atomic(p_price_book_id uuid, p_rows jsonb, p_update_existing boolean, p_source_filename text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_price_book_items_atomic(p_price_book_id uuid, p_rows jsonb, p_update_existing boolean, p_source_filename text) TO authenticated;
GRANT ALL ON FUNCTION public.import_price_book_items_atomic(p_price_book_id uuid, p_rows jsonb, p_update_existing boolean, p_source_filename text) TO service_role;


--
-- Name: FUNCTION is_current_user_in_storm_mode(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_current_user_in_storm_mode() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_current_user_in_storm_mode() TO authenticated;
GRANT ALL ON FUNCTION public.is_current_user_in_storm_mode() TO service_role;


--
-- Name: FUNCTION is_my_profile_suspended(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_my_profile_suspended() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_my_profile_suspended() TO authenticated;
GRANT ALL ON FUNCTION public.is_my_profile_suspended() TO service_role;


--
-- Name: FUNCTION is_platform_owner(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_platform_owner() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_platform_owner() TO authenticated;
GRANT ALL ON FUNCTION public.is_platform_owner() TO service_role;


--
-- Name: FUNCTION is_platform_support(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_platform_support() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_platform_support() TO authenticated;
GRANT ALL ON FUNCTION public.is_platform_support() TO service_role;


--
-- Name: FUNCTION join_company(company_code text, user_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.join_company(company_code text, user_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.join_company(company_code text, user_name text) TO authenticated;
GRANT ALL ON FUNCTION public.join_company(company_code text, user_name text) TO service_role;


--
-- Name: FUNCTION linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text) TO service_role;
GRANT ALL ON FUNCTION public.linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text) TO authenticated;


--
-- Name: FUNCTION linecrew_can_manage_job_packages(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_can_manage_job_packages() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_can_manage_job_packages() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_can_manage_job_packages() TO service_role;


--
-- Name: FUNCTION linecrew_can_manage_jobs(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_can_manage_jobs() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_can_manage_jobs() TO service_role;


--
-- Name: FUNCTION linecrew_can_manage_packet_unit_aliases(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_can_manage_packet_unit_aliases() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_can_manage_packet_unit_aliases() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_can_manage_packet_unit_aliases() TO service_role;


--
-- Name: FUNCTION linecrew_can_use_billing_exports_internal(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_can_use_billing_exports_internal() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_can_use_billing_exports_internal() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_can_use_billing_exports_internal() TO service_role;


--
-- Name: FUNCTION linecrew_claim_initial_owner(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_claim_initial_owner() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_claim_initial_owner() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_claim_initial_owner() TO service_role;


--
-- Name: FUNCTION linecrew_foreman_has_job_assignment(p_job_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_foreman_has_job_assignment(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_foreman_has_job_assignment(p_job_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_foreman_has_job_assignment(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION linecrew_has_capability(capability text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_has_capability(capability text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_has_capability(capability text) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_has_capability(capability text) TO service_role;


--
-- Name: FUNCTION linecrew_mfa_bootstrap_identity(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_mfa_bootstrap_identity() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_mfa_bootstrap_identity() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_mfa_bootstrap_identity() TO service_role;


--
-- Name: FUNCTION linecrew_packet_unit_aliases_for_import(p_import_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_packet_unit_aliases_for_import(p_import_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_packet_unit_aliases_for_import(p_import_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_packet_unit_aliases_for_import(p_import_id uuid) TO service_role;


--
-- Name: FUNCTION linecrew_price_book_units_for_import(p_import_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_price_book_units_for_import(p_import_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_price_book_units_for_import(p_import_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_price_book_units_for_import(p_import_id uuid) TO service_role;


--
-- Name: FUNCTION linecrew_privileged_mfa_satisfied(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_privileged_mfa_satisfied() FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_privileged_mfa_satisfied() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_privileged_mfa_satisfied() TO service_role;


--
-- Name: FUNCTION linecrew_report_counts_toward_progress(p_status text, p_reviewed_at timestamp with time zone, p_review_notes text, p_archived boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_report_counts_toward_progress(p_status text, p_reviewed_at timestamp with time zone, p_review_notes text, p_archived boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_report_counts_toward_progress(p_status text, p_reviewed_at timestamp with time zone, p_review_notes text, p_archived boolean) TO service_role;


--
-- Name: FUNCTION linecrew_resolve_job_price_book(p_company_id uuid, p_job_id uuid, p_contract_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_resolve_job_price_book(p_company_id uuid, p_job_id uuid, p_contract_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_resolve_job_price_book(p_company_id uuid, p_job_id uuid, p_contract_id uuid) TO service_role;


--
-- Name: FUNCTION linecrew_set_member_money_permissions(target_user_id uuid, can_see_actual boolean, can_see_field boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_set_member_money_permissions(target_user_id uuid, can_see_actual boolean, can_see_field boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_set_member_money_permissions(target_user_id uuid, can_see_actual boolean, can_see_field boolean) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_set_member_money_permissions(target_user_id uuid, can_see_actual boolean, can_see_field boolean) TO service_role;


--
-- Name: FUNCTION linecrew_set_member_role(target_user_id uuid, new_role text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_set_member_role(target_user_id uuid, new_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_set_member_role(target_user_id uuid, new_role text) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_set_member_role(target_user_id uuid, new_role text) TO service_role;


--
-- Name: FUNCTION linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text) TO service_role;


--
-- Name: FUNCTION linecrew_set_superintendent_permissions(target_user_id uuid, permissions jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_set_superintendent_permissions(target_user_id uuid, permissions jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_set_superintendent_permissions(target_user_id uuid, permissions jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_set_superintendent_permissions(target_user_id uuid, permissions jsonb) TO service_role;


--
-- Name: FUNCTION linecrew_transfer_company_owner(target_admin_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_transfer_company_owner(target_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_transfer_company_owner(target_admin_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_transfer_company_owner(target_admin_id uuid) TO service_role;


--
-- Name: FUNCTION linecrew_utility_packet_import_matches(p_import_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.linecrew_utility_packet_import_matches(p_import_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linecrew_utility_packet_import_matches(p_import_id uuid) TO service_role;


--
-- Name: FUNCTION linecrew_validate_jsa_source(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.linecrew_validate_jsa_source() TO anon;
GRANT ALL ON FUNCTION public.linecrew_validate_jsa_source() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_validate_jsa_source() TO service_role;


--
-- Name: FUNCTION linecrew_validate_profile_role(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.linecrew_validate_profile_role() TO anon;
GRANT ALL ON FUNCTION public.linecrew_validate_profile_role() TO authenticated;
GRANT ALL ON FUNCTION public.linecrew_validate_profile_role() TO service_role;


--
-- Name: FUNCTION my_company_billing_summary(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_company_billing_summary() FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_company_billing_summary() TO authenticated;
GRANT ALL ON FUNCTION public.my_company_billing_summary() TO service_role;


--
-- Name: FUNCTION my_company_id(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_company_id() FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_company_id() TO authenticated;
GRANT ALL ON FUNCTION public.my_company_id() TO service_role;


--
-- Name: FUNCTION my_company_subscription_access(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_company_subscription_access() FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_company_subscription_access() TO service_role;


--
-- Name: FUNCTION my_role(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_role() FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_role() TO authenticated;
GRANT ALL ON FUNCTION public.my_role() TO service_role;


--
-- Name: FUNCTION normalize_work_point_key(p_value text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.normalize_work_point_key(p_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.normalize_work_point_key(p_value text) TO authenticated;
GRANT ALL ON FUNCTION public.normalize_work_point_key(p_value text) TO service_role;


--
-- Name: FUNCTION plan_crew_limit(p_plan_code text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.plan_crew_limit(p_plan_code text) TO anon;
GRANT ALL ON FUNCTION public.plan_crew_limit(p_plan_code text) TO authenticated;
GRANT ALL ON FUNCTION public.plan_crew_limit(p_plan_code text) TO service_role;


--
-- Name: FUNCTION plan_monthly_cents(p_plan_code text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.plan_monthly_cents(p_plan_code text) TO anon;
GRANT ALL ON FUNCTION public.plan_monthly_cents(p_plan_code text) TO authenticated;
GRANT ALL ON FUNCTION public.plan_monthly_cents(p_plan_code text) TO service_role;


--
-- Name: FUNCTION platform_owner_beta_applications(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_owner_beta_applications() FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_owner_beta_applications() TO authenticated;
GRANT ALL ON FUNCTION public.platform_owner_beta_applications() TO service_role;


--
-- Name: FUNCTION platform_owner_company_dashboard(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_owner_company_dashboard() FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_owner_company_dashboard() TO authenticated;
GRANT ALL ON FUNCTION public.platform_owner_company_dashboard() TO service_role;


--
-- Name: FUNCTION platform_owner_decline_beta_application(p_application_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_owner_decline_beta_application(p_application_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_owner_decline_beta_application(p_application_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.platform_owner_decline_beta_application(p_application_id uuid) TO service_role;


--
-- Name: FUNCTION platform_owner_mark_beta_invite_sent(p_application_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_owner_mark_beta_invite_sent(p_application_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_owner_mark_beta_invite_sent(p_application_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.platform_owner_mark_beta_invite_sent(p_application_id uuid) TO service_role;


--
-- Name: FUNCTION platform_owner_prepare_beta_company(p_application_id uuid, p_token_hash text, p_invite_expires_at timestamp with time zone, p_pilot_ends_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_owner_prepare_beta_company(p_application_id uuid, p_token_hash text, p_invite_expires_at timestamp with time zone, p_pilot_ends_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_owner_prepare_beta_company(p_application_id uuid, p_token_hash text, p_invite_expires_at timestamp with time zone, p_pilot_ends_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.platform_owner_prepare_beta_company(p_application_id uuid, p_token_hash text, p_invite_expires_at timestamp with time zone, p_pilot_ends_at timestamp with time zone) TO service_role;


--
-- Name: TABLE company_subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.company_subscriptions TO service_role;


--
-- Name: FUNCTION platform_owner_set_subscription(p_company_id uuid, p_plan_code text, p_monthly_price_cents integer, p_status text, p_access_override boolean, p_trial_ends_at timestamp with time zone, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_owner_set_subscription(p_company_id uuid, p_plan_code text, p_monthly_price_cents integer, p_status text, p_access_override boolean, p_trial_ends_at timestamp with time zone, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_owner_set_subscription(p_company_id uuid, p_plan_code text, p_monthly_price_cents integer, p_status text, p_access_override boolean, p_trial_ends_at timestamp with time zone, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.platform_owner_set_subscription(p_company_id uuid, p_plan_code text, p_monthly_price_cents integer, p_status text, p_access_override boolean, p_trial_ends_at timestamp with time zone, p_notes text) TO service_role;


--
-- Name: FUNCTION prevent_duplicate_daily_report(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.prevent_duplicate_daily_report() FROM PUBLIC;
GRANT ALL ON FUNCTION public.prevent_duplicate_daily_report() TO service_role;


--
-- Name: FUNCTION prevent_non_draft_job_package_delete(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.prevent_non_draft_job_package_delete() FROM PUBLIC;
GRANT ALL ON FUNCTION public.prevent_non_draft_job_package_delete() TO service_role;


--
-- Name: FUNCTION protect_daily_report_unit_history(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_daily_report_unit_history() FROM PUBLIC;
GRANT ALL ON FUNCTION public.protect_daily_report_unit_history() TO service_role;


--
-- Name: FUNCTION recalculate_company_crew_overage(p_company_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recalculate_company_crew_overage(p_company_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recalculate_company_crew_overage(p_company_id uuid) TO service_role;


--
-- Name: FUNCTION recalculate_timekeeping_employee_week(p_report_id uuid, p_employee_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recalculate_timekeeping_employee_week(p_report_id uuid, p_employee_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recalculate_timekeeping_employee_week(p_report_id uuid, p_employee_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.recalculate_timekeeping_employee_week(p_report_id uuid, p_employee_id uuid) TO service_role;


--
-- Name: FUNCTION recommended_crew_plan(p_peak_crews integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.recommended_crew_plan(p_peak_crews integer) TO anon;
GRANT ALL ON FUNCTION public.recommended_crew_plan(p_peak_crews integer) TO authenticated;
GRANT ALL ON FUNCTION public.recommended_crew_plan(p_peak_crews integer) TO service_role;


--
-- Name: FUNCTION record_app_error(p_area text, p_error_code text, p_page text, p_message text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_app_error(p_area text, p_error_code text, p_page text, p_message text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_app_error(p_area text, p_error_code text, p_page text, p_message text) TO authenticated;
GRANT ALL ON FUNCTION public.record_app_error(p_area text, p_error_code text, p_page text, p_message text) TO service_role;


--
-- Name: FUNCTION record_daily_report_audit_event(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_daily_report_audit_event() FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_daily_report_audit_event() TO authenticated;
GRANT ALL ON FUNCTION public.record_daily_report_audit_event() TO service_role;


--
-- Name: FUNCTION register_billing_export_attachment(p_batch_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_billing_export_attachment(p_batch_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_billing_export_attachment(p_batch_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) TO authenticated;
GRANT ALL ON FUNCTION public.register_billing_export_attachment(p_batch_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) TO service_role;


--
-- Name: TABLE daily_report_attachments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_report_attachments TO anon;
GRANT ALL ON TABLE public.daily_report_attachments TO authenticated;
GRANT ALL ON TABLE public.daily_report_attachments TO service_role;


--
-- Name: FUNCTION register_daily_report_attachment(p_report_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_daily_report_attachment(p_report_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_daily_report_attachment(p_report_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) TO authenticated;
GRANT ALL ON FUNCTION public.register_daily_report_attachment(p_report_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) TO service_role;


--
-- Name: FUNCTION register_jsa_upload_attachment(p_jsa_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_page_order integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_jsa_upload_attachment(p_jsa_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_page_order integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_jsa_upload_attachment(p_jsa_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_page_order integer) TO authenticated;
GRANT ALL ON FUNCTION public.register_jsa_upload_attachment(p_jsa_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_page_order integer) TO service_role;


--
-- Name: FUNCTION remove_assistant_memory(p_memory_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.remove_assistant_memory(p_memory_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_assistant_memory(p_memory_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.remove_assistant_memory(p_memory_id uuid) TO authenticated;


--
-- Name: FUNCTION resolve_utility_packet_price_item(p_import_id uuid, p_contractor_unit_code text, p_work_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resolve_utility_packet_price_item(p_import_id uuid, p_contractor_unit_code text, p_work_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_utility_packet_price_item(p_import_id uuid, p_contractor_unit_code text, p_work_type text) TO service_role;


--
-- Name: FUNCTION return_daily_report(p_report_id uuid, p_review_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.return_daily_report(p_report_id uuid, p_review_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.return_daily_report(p_report_id uuid, p_review_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.return_daily_report(p_report_id uuid, p_review_notes text) TO service_role;


--
-- Name: FUNCTION review_daily_report(p_report_id uuid, p_approved boolean, p_review_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.review_daily_report(p_report_id uuid, p_approved boolean, p_review_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.review_daily_report(p_report_id uuid, p_approved boolean, p_review_notes text) TO service_role;


--
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.rls_auto_enable() TO service_role;


--
-- Name: FUNCTION rotate_company_join_code(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rotate_company_join_code() FROM PUBLIC;
GRANT ALL ON FUNCTION public.rotate_company_join_code() TO authenticated;
GRANT ALL ON FUNCTION public.rotate_company_join_code() TO service_role;


--
-- Name: FUNCTION save_billing_export_batch_details(p_batch_id uuid, p_utility_invoice_number text, p_payment_reference text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_billing_export_batch_details(p_batch_id uuid, p_utility_invoice_number text, p_payment_reference text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_billing_export_batch_details(p_batch_id uuid, p_utility_invoice_number text, p_payment_reference text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.save_billing_export_batch_details(p_batch_id uuid, p_utility_invoice_number text, p_payment_reference text, p_notes text) TO service_role;


--
-- Name: FUNCTION save_daily_report_jsa(p_report_id uuid, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_special_equipment text, p_foreman_acknowledged boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_daily_report_jsa(p_report_id uuid, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_special_equipment text, p_foreman_acknowledged boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_daily_report_jsa(p_report_id uuid, p_job_briefing text, p_hazards text, p_controls text, p_ppe text, p_emergency_plan text, p_crew_members text, p_special_equipment text, p_foreman_acknowledged boolean) TO service_role;


--
-- Name: FUNCTION save_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid, p_install_quantity numeric, p_retirement_quantity numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid, p_install_quantity numeric, p_retirement_quantity numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid, p_install_quantity numeric, p_retirement_quantity numeric) TO authenticated;
GRANT ALL ON FUNCTION public.save_daily_report_unit(p_report_id uuid, p_price_book_item_id uuid, p_install_quantity numeric, p_retirement_quantity numeric) TO service_role;


--
-- Name: FUNCTION save_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_retirement_quantity numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_retirement_quantity numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_daily_report_unit_location(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_retirement_quantity numeric) TO service_role;


--
-- Name: FUNCTION save_daily_report_unit_location_v2(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_daily_report_unit_location_v2(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_daily_report_unit_location_v2(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) TO authenticated;
GRANT ALL ON FUNCTION public.save_daily_report_unit_location_v2(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) TO service_role;


--
-- Name: FUNCTION save_job_package_authorized_unit(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_retirement_quantity numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_job_package_authorized_unit(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_retirement_quantity numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_job_package_authorized_unit(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_retirement_quantity numeric) TO authenticated;
GRANT ALL ON FUNCTION public.save_job_package_authorized_unit(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_retirement_quantity numeric) TO service_role;


--
-- Name: FUNCTION save_job_package_authorized_unit_v2(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_job_package_authorized_unit_v2(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_job_package_authorized_unit_v2(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) TO authenticated;
GRANT ALL ON FUNCTION public.save_job_package_authorized_unit_v2(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) TO service_role;


--
-- Name: FUNCTION set_billing_export_batch_status(p_batch_id uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_billing_export_batch_status(p_batch_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_billing_export_batch_status(p_batch_id uuid, p_status text) TO service_role;


--
-- Name: FUNCTION set_billing_export_batch_status_v2(p_batch_id uuid, p_status text, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_billing_export_batch_status_v2(p_batch_id uuid, p_status text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_billing_export_batch_status_v2(p_batch_id uuid, p_status text, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.set_billing_export_batch_status_v2(p_batch_id uuid, p_status text, p_reason text) TO service_role;


--
-- Name: FUNCTION set_company_jsa_method(p_method text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_company_jsa_method(p_method text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_jsa_method(p_method text) TO authenticated;
GRANT ALL ON FUNCTION public.set_company_jsa_method(p_method text) TO service_role;


--
-- Name: FUNCTION set_company_member_active(p_member_id uuid, p_active boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_company_member_active(p_member_id uuid, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_member_active(p_member_id uuid, p_active boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_company_member_active(p_member_id uuid, p_active boolean) TO service_role;


--
-- Name: FUNCTION set_company_member_role(p_member_id uuid, p_role text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_company_member_role(p_member_id uuid, p_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_member_role(p_member_id uuid, p_role text) TO authenticated;
GRANT ALL ON FUNCTION public.set_company_member_role(p_member_id uuid, p_role text) TO service_role;


--
-- Name: FUNCTION set_company_redline_approval_requirement(p_required boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_company_redline_approval_requirement(p_required boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_redline_approval_requirement(p_required boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_company_redline_approval_requirement(p_required boolean) TO service_role;


--
-- Name: FUNCTION set_company_storm_mode(p_enabled boolean, p_event_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_company_storm_mode(p_enabled boolean, p_event_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_storm_mode(p_enabled boolean, p_event_name text) TO authenticated;
GRANT ALL ON FUNCTION public.set_company_storm_mode(p_enabled boolean, p_event_name text) TO service_role;


--
-- Name: FUNCTION set_contract_field_value_percent(p_contract_id uuid, p_field_value_percent numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_contract_field_value_percent(p_contract_id uuid, p_field_value_percent numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_contract_field_value_percent(p_contract_id uuid, p_field_value_percent numeric) TO authenticated;
GRANT ALL ON FUNCTION public.set_contract_field_value_percent(p_contract_id uuid, p_field_value_percent numeric) TO service_role;


--
-- Name: FUNCTION set_daily_production_transfer_price_snapshot(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_daily_production_transfer_price_snapshot() FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_daily_production_transfer_price_snapshot() TO service_role;


--
-- Name: FUNCTION set_daily_report_archived(p_report_id uuid, p_archived boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_daily_report_archived(p_report_id uuid, p_archived boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_daily_report_archived(p_report_id uuid, p_archived boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_daily_report_archived(p_report_id uuid, p_archived boolean) TO service_role;


--
-- Name: FUNCTION set_daily_report_context(p_report_id uuid, p_weather_conditions text, p_delay_hours numeric, p_delay_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_daily_report_context(p_report_id uuid, p_weather_conditions text, p_delay_hours numeric, p_delay_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_daily_report_context(p_report_id uuid, p_weather_conditions text, p_delay_hours numeric, p_delay_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.set_daily_report_context(p_report_id uuid, p_weather_conditions text, p_delay_hours numeric, p_delay_reason text) TO service_role;


--
-- Name: FUNCTION set_daily_report_date(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_daily_report_date() TO anon;
GRANT ALL ON FUNCTION public.set_daily_report_date() TO authenticated;
GRANT ALL ON FUNCTION public.set_daily_report_date() TO service_role;


--
-- Name: FUNCTION set_daily_report_storm_context(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_daily_report_storm_context(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_daily_report_storm_context(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.set_daily_report_storm_context(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION set_gf_crew_assignment(p_foreman_id uuid, p_gf_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_gf_crew_assignment(p_foreman_id uuid, p_gf_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_gf_crew_assignment(p_foreman_id uuid, p_gf_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.set_gf_crew_assignment(p_foreman_id uuid, p_gf_id uuid) TO service_role;


--
-- Name: FUNCTION set_job_closeout(p_job_id uuid, p_close boolean, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_job_closeout(p_job_id uuid, p_close boolean, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_job_closeout(p_job_id uuid, p_close boolean, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.set_job_closeout(p_job_id uuid, p_close boolean, p_reason text) TO service_role;


--
-- Name: FUNCTION set_job_leader_assignment(p_job_id uuid, p_member_id uuid, p_assigned boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_job_leader_assignment(p_job_id uuid, p_member_id uuid, p_assigned boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_job_leader_assignment(p_job_id uuid, p_member_id uuid, p_assigned boolean) TO service_role;
GRANT ALL ON FUNCTION public.set_job_leader_assignment(p_job_id uuid, p_member_id uuid, p_assigned boolean) TO authenticated;


--
-- Name: FUNCTION set_job_package_status(p_package_id uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_job_package_status(p_package_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_job_package_status(p_package_id uuid, p_status text) TO authenticated;
GRANT ALL ON FUNCTION public.set_job_package_status(p_package_id uuid, p_status text) TO service_role;


--
-- Name: FUNCTION set_price_book_active(p_price_book_id uuid, p_active boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_price_book_active(p_price_book_id uuid, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_price_book_active(p_price_book_id uuid, p_active boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_price_book_active(p_price_book_id uuid, p_active boolean) TO service_role;


--
-- Name: FUNCTION set_storm_mode_assignments(p_user_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_storm_mode_assignments(p_user_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_storm_mode_assignments(p_user_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.set_storm_mode_assignments(p_user_ids uuid[]) TO service_role;


--
-- Name: FUNCTION set_void_billing_batch_archived(p_batch_id uuid, p_archived boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_void_billing_batch_archived(p_batch_id uuid, p_archived boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_void_billing_batch_archived(p_batch_id uuid, p_archived boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_void_billing_batch_archived(p_batch_id uuid, p_archived boolean) TO service_role;


--
-- Name: FUNCTION stage_utility_packet_import(p_package_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.stage_utility_packet_import(p_package_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stage_utility_packet_import(p_package_id uuid, p_provider_key text, p_format_key text, p_profile_version text, p_source_filename text, p_source_sha256 text, p_detected_work_order text, p_extraction_confidence numeric, p_summary jsonb, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION submit_daily_report(p_report_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_daily_report(p_report_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_daily_report(p_report_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.submit_daily_report(p_report_id uuid) TO service_role;


--
-- Name: FUNCTION submit_pilot_feedback(p_category text, p_rating integer, p_message text, p_page text, p_contact_ok boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_pilot_feedback(p_category text, p_rating integer, p_message text, p_page text, p_contact_ok boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_pilot_feedback(p_category text, p_rating integer, p_message text, p_page text, p_contact_ok boolean) TO authenticated;
GRANT ALL ON FUNCTION public.submit_pilot_feedback(p_category text, p_rating integer, p_message text, p_page text, p_contact_ok boolean) TO service_role;


--
-- Name: FUNCTION supersede_prior_job_package(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.supersede_prior_job_package() FROM PUBLIC;
GRANT ALL ON FUNCTION public.supersede_prior_job_package() TO service_role;


--
-- Name: FUNCTION support_console_identity(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_console_identity() FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_console_identity() TO authenticated;
GRANT ALL ON FUNCTION public.support_console_identity() TO service_role;


--
-- Name: FUNCTION support_get_diagnostics(p_request_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_get_diagnostics(p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_get_diagnostics(p_request_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.support_get_diagnostics(p_request_id uuid) TO service_role;


--
-- Name: FUNCTION support_get_recent_errors(p_request_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_get_recent_errors(p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_get_recent_errors(p_request_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.support_get_recent_errors(p_request_id uuid) TO service_role;


--
-- Name: FUNCTION support_list_companies(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_list_companies() FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_list_companies() TO authenticated;
GRANT ALL ON FUNCTION public.support_list_companies() TO service_role;


--
-- Name: FUNCTION support_list_my_requests(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_list_my_requests() FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_list_my_requests() TO authenticated;
GRANT ALL ON FUNCTION public.support_list_my_requests() TO service_role;


--
-- Name: FUNCTION support_list_pilot_command_center(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_list_pilot_command_center() FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_list_pilot_command_center() TO service_role;
GRANT ALL ON FUNCTION public.support_list_pilot_command_center() TO authenticated;


--
-- Name: FUNCTION support_list_pilot_feedback(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_list_pilot_feedback(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_list_pilot_feedback(p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.support_list_pilot_feedback(p_limit integer) TO service_role;


--
-- Name: FUNCTION support_request_access(p_company_id uuid, p_reason text, p_minutes integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_request_access(p_company_id uuid, p_reason text, p_minutes integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_request_access(p_company_id uuid, p_reason text, p_minutes integer) TO authenticated;
GRANT ALL ON FUNCTION public.support_request_access(p_company_id uuid, p_reason text, p_minutes integer) TO service_role;


--
-- Name: FUNCTION support_resolve_pilot_feedback(p_feedback_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_resolve_pilot_feedback(p_feedback_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_resolve_pilot_feedback(p_feedback_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.support_resolve_pilot_feedback(p_feedback_id uuid) TO service_role;


--
-- Name: FUNCTION support_set_company_access(p_company_id uuid, p_status text, p_expires_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.support_set_company_access(p_company_id uuid, p_status text, p_expires_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.support_set_company_access(p_company_id uuid, p_status text, p_expires_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.support_set_company_access(p_company_id uuid, p_status text, p_expires_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION sync_daily_report_hours_from_timekeeping(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_daily_report_hours_from_timekeeping() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_daily_report_hours_from_timekeeping() TO service_role;


--
-- Name: FUNCTION sync_foreman_timekeeping_employee(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_foreman_timekeeping_employee() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_foreman_timekeeping_employee() TO service_role;


--
-- Name: FUNCTION timekeeping_period_state(p_start date, p_end date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.timekeeping_period_state(p_start date, p_end date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.timekeeping_period_state(p_start date, p_end date) TO authenticated;
GRANT ALL ON FUNCTION public.timekeeping_period_state(p_start date, p_end date) TO service_role;


--
-- Name: FUNCTION timekeeping_report_rows(p_from date, p_through date, p_employee uuid, p_job uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.timekeeping_report_rows(p_from date, p_through date, p_employee uuid, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.timekeeping_report_rows(p_from date, p_through date, p_employee uuid, p_job uuid) TO service_role;


--
-- Name: FUNCTION timekeeping_report_rows_v2(p_from date, p_through date, p_employee uuid, p_job uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.timekeeping_report_rows_v2(p_from date, p_through date, p_employee uuid, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.timekeeping_report_rows_v2(p_from date, p_through date, p_employee uuid, p_job uuid) TO authenticated;
GRANT ALL ON FUNCTION public.timekeeping_report_rows_v2(p_from date, p_through date, p_employee uuid, p_job uuid) TO service_role;


--
-- Name: FUNCTION timekeeping_report_rows_v3(p_from date, p_through date, p_employee uuid, p_job uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.timekeeping_report_rows_v3(p_from date, p_through date, p_employee uuid, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.timekeeping_report_rows_v3(p_from date, p_through date, p_employee uuid, p_job uuid) TO authenticated;
GRANT ALL ON FUNCTION public.timekeeping_report_rows_v3(p_from date, p_through date, p_employee uuid, p_job uuid) TO service_role;


--
-- Name: FUNCTION timekeeping_set_period_status(p_start date, p_end date, p_action text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.timekeeping_set_period_status(p_start date, p_end date, p_action text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.timekeeping_set_period_status(p_start date, p_end date, p_action text) TO authenticated;
GRANT ALL ON FUNCTION public.timekeeping_set_period_status(p_start date, p_end date, p_action text) TO service_role;


--
-- Name: FUNCTION training_role_rank(p_role text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.training_role_rank(p_role text) TO anon;
GRANT ALL ON FUNCTION public.training_role_rank(p_role text) TO authenticated;
GRANT ALL ON FUNCTION public.training_role_rank(p_role text) TO service_role;


--
-- Name: FUNCTION update_company_man_hour_rate(p_required_rate numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_company_man_hour_rate(p_required_rate numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_company_man_hour_rate(p_required_rate numeric) TO authenticated;
GRANT ALL ON FUNCTION public.update_company_man_hour_rate(p_required_rate numeric) TO service_role;


--
-- Name: FUNCTION update_company_settings(p_name text, p_contact_email text, p_contact_phone text, p_logo_url text, p_primary_color text, p_timezone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_company_settings(p_name text, p_contact_email text, p_contact_phone text, p_logo_url text, p_primary_color text, p_timezone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_company_settings(p_name text, p_contact_email text, p_contact_phone text, p_logo_url text, p_primary_color text, p_timezone text) TO authenticated;
GRANT ALL ON FUNCTION public.update_company_settings(p_name text, p_contact_email text, p_contact_phone text, p_logo_url text, p_primary_color text, p_timezone text) TO service_role;


--
-- Name: FUNCTION update_company_week_start(p_week_start_day smallint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_company_week_start(p_week_start_day smallint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_company_week_start(p_week_start_day smallint) TO authenticated;
GRANT ALL ON FUNCTION public.update_company_week_start(p_week_start_day smallint) TO service_role;


--
-- Name: FUNCTION update_contract_job(p_job_id uuid, p_contract_id uuid, p_job_number text, p_job_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_contract_job(p_job_id uuid, p_contract_id uuid, p_job_number text, p_job_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_contract_job(p_job_id uuid, p_contract_id uuid, p_job_number text, p_job_name text) TO authenticated;
GRANT ALL ON FUNCTION public.update_contract_job(p_job_id uuid, p_contract_id uuid, p_job_number text, p_job_name text) TO service_role;


--
-- Name: FUNCTION update_daily_report(p_report_id uuid, p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_daily_report(p_report_id uuid, p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_daily_report(p_report_id uuid, p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.update_daily_report(p_report_id uuid, p_job_id uuid, p_work_date date, p_regular_hours numeric, p_overtime_hours numeric, p_crew_name text, p_notes text) TO service_role;


--
-- Name: FUNCTION update_job(p_job_id uuid, p_job_number text, p_job_name text, p_customer_name text, p_utility_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_job(p_job_id uuid, p_job_number text, p_job_name text, p_customer_name text, p_utility_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_job(p_job_id uuid, p_job_number text, p_job_name text, p_customer_name text, p_utility_name text) TO service_role;


--
-- Name: FUNCTION update_my_profile_name(p_full_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_my_profile_name(p_full_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_my_profile_name(p_full_name text) TO authenticated;
GRANT ALL ON FUNCTION public.update_my_profile_name(p_full_name text) TO service_role;


--
-- Name: FUNCTION update_utility_packet_import_row(p_row_id uuid, p_work_point_code text, p_work_type text, p_contractor_unit_code text, p_estimated_quantity numeric, p_include_in_import boolean, p_review_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_utility_packet_import_row(p_row_id uuid, p_work_point_code text, p_work_type text, p_contractor_unit_code text, p_estimated_quantity numeric, p_include_in_import boolean, p_review_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_utility_packet_import_row(p_row_id uuid, p_work_point_code text, p_work_type text, p_contractor_unit_code text, p_estimated_quantity numeric, p_include_in_import boolean, p_review_note text) TO authenticated;
GRANT ALL ON FUNCTION public.update_utility_packet_import_row(p_row_id uuid, p_work_point_code text, p_work_type text, p_contractor_unit_code text, p_estimated_quantity numeric, p_include_in_import boolean, p_review_note text) TO service_role;


--
-- Name: FUNCTION update_utility_packet_import_rows_bulk(p_import_id uuid, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_utility_packet_import_rows_bulk(p_import_id uuid, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_utility_packet_import_rows_bulk(p_import_id uuid, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION upsert_leadership_employee_time(p_employee_id uuid, p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_leadership_employee_time(p_employee_id uuid, p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_leadership_employee_time(p_employee_id uuid, p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_leadership_employee_time(p_employee_id uuid, p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) TO service_role;


--
-- Name: FUNCTION upsert_my_leadership_time(p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_my_leadership_time(p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_my_leadership_time(p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_my_leadership_time(p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) TO service_role;


--
-- Name: FUNCTION validate_job_package_import(p_package_id uuid, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_job_package_import(p_package_id uuid, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_job_package_import(p_package_id uuid, p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.validate_job_package_import(p_package_id uuid, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION validate_timekeeping_employee_admin_assignment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_timekeeping_employee_admin_assignment() FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_timekeeping_employee_admin_assignment() TO service_role;


--
-- Name: FUNCTION validate_timekeeping_employee_assignment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_timekeeping_employee_assignment() FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_timekeeping_employee_assignment() TO service_role;


--
-- Name: TABLE app_error_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_error_events TO service_role;


--
-- Name: SEQUENCE app_error_events_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.app_error_events_id_seq TO anon;
GRANT ALL ON SEQUENCE public.app_error_events_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.app_error_events_id_seq TO service_role;


--
-- Name: TABLE assistant_memories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.assistant_memories TO service_role;
GRANT SELECT ON TABLE public.assistant_memories TO authenticated;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.audit_log TO anon;
GRANT ALL ON TABLE public.audit_log TO authenticated;
GRANT ALL ON TABLE public.audit_log TO service_role;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.audit_log_id_seq TO anon;
GRANT ALL ON SEQUENCE public.audit_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.audit_log_id_seq TO service_role;


--
-- Name: TABLE beta_applications; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.beta_applications TO service_role;


--
-- Name: TABLE billing_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.billing_events TO service_role;


--
-- Name: TABLE billing_export_attachments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.billing_export_attachments TO service_role;


--
-- Name: TABLE billing_export_batches; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.billing_export_batches TO service_role;


--
-- Name: TABLE billing_export_lines; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.billing_export_lines TO service_role;


--
-- Name: TABLE companies; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.companies TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.companies TO authenticated;
GRANT ALL ON TABLE public.companies TO service_role;


--
-- Name: TABLE company_crew_usage_daily; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.company_crew_usage_daily TO service_role;


--
-- Name: TABLE company_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.company_settings TO anon;
GRANT ALL ON TABLE public.company_settings TO authenticated;
GRANT ALL ON TABLE public.company_settings TO service_role;


--
-- Name: TABLE contract_field_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contract_field_settings TO service_role;


--
-- Name: TABLE contracts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contracts TO anon;
GRANT ALL ON TABLE public.contracts TO authenticated;
GRANT ALL ON TABLE public.contracts TO service_role;


--
-- Name: TABLE crews; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.crews TO anon;
GRANT ALL ON TABLE public.crews TO authenticated;
GRANT ALL ON TABLE public.crews TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT ALL ON TABLE public.customers TO service_role;


--
-- Name: TABLE daily_production_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_production_items TO anon;
GRANT ALL ON TABLE public.daily_production_items TO authenticated;
GRANT ALL ON TABLE public.daily_production_items TO service_role;


--
-- Name: TABLE daily_production_unit_locations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_production_unit_locations TO service_role;


--
-- Name: TABLE daily_production_units; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_production_units TO service_role;


--
-- Name: TABLE daily_report_audit_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_report_audit_events TO service_role;


--
-- Name: TABLE daily_report_jsas; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_report_jsas TO authenticated;
GRANT ALL ON TABLE public.daily_report_jsas TO service_role;


--
-- Name: TABLE daily_report_units; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_report_units TO anon;
GRANT ALL ON TABLE public.daily_report_units TO authenticated;
GRANT ALL ON TABLE public.daily_report_units TO service_role;


--
-- Name: TABLE daily_reports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.daily_reports TO anon;
GRANT ALL ON TABLE public.daily_reports TO authenticated;
GRANT ALL ON TABLE public.daily_reports TO service_role;


--
-- Name: TABLE employees; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.employees TO anon;
GRANT ALL ON TABLE public.employees TO authenticated;
GRANT ALL ON TABLE public.employees TO service_role;


--
-- Name: TABLE gf_foreman_assignments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.gf_foreman_assignments TO service_role;


--
-- Name: TABLE job_assignment_audit_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.job_assignment_audit_events TO service_role;


--
-- Name: SEQUENCE job_assignment_audit_events_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.job_assignment_audit_events_id_seq TO anon;
GRANT ALL ON SEQUENCE public.job_assignment_audit_events_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.job_assignment_audit_events_id_seq TO service_role;


--
-- Name: TABLE job_closeout_history; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.job_closeout_history TO service_role;


--
-- Name: TABLE job_leader_assignments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.job_leader_assignments TO authenticated;
GRANT ALL ON TABLE public.job_leader_assignments TO service_role;


--
-- Name: TABLE job_package_authorized_units; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.job_package_authorized_units TO service_role;


--
-- Name: TABLE job_package_work_points; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.job_package_work_points TO service_role;


--
-- Name: TABLE job_packages; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.job_packages TO service_role;


--
-- Name: TABLE jobs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.jobs TO anon;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.jobs TO authenticated;
GRANT ALL ON TABLE public.jobs TO service_role;


--
-- Name: TABLE jsa_upload_attachments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.jsa_upload_attachments TO anon;
GRANT ALL ON TABLE public.jsa_upload_attachments TO authenticated;
GRANT ALL ON TABLE public.jsa_upload_attachments TO service_role;


--
-- Name: TABLE pilot_feedback; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.pilot_feedback TO service_role;


--
-- Name: TABLE platform_owner_audit_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.platform_owner_audit_events TO service_role;


--
-- Name: TABLE platform_owners; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.platform_owners TO service_role;


--
-- Name: TABLE platform_support_users; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.platform_support_users TO service_role;


--
-- Name: TABLE price_book_items; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.price_book_items TO anon;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE public.price_book_items TO authenticated;
GRANT ALL ON TABLE public.price_book_items TO service_role;


--
-- Name: COLUMN price_book_items.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.company_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(company_id) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.price_book_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(price_book_id) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.item_code; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(item_code) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.item_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(item_name) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.description; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(description) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.unit_of_measure; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(unit_of_measure) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.category; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(category) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.extra_data; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(extra_data) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.active; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(active) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.price_book_items TO authenticated;


--
-- Name: COLUMN price_book_items.updated_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(updated_at) ON TABLE public.price_book_items TO authenticated;


--
-- Name: TABLE price_books; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.price_books TO anon;
GRANT ALL ON TABLE public.price_books TO authenticated;
GRANT ALL ON TABLE public.price_books TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO anon;
GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: TABLE report_units; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.report_units TO anon;
GRANT ALL ON TABLE public.report_units TO authenticated;
GRANT ALL ON TABLE public.report_units TO service_role;


--
-- Name: TABLE storm_mode_assignments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.storm_mode_assignments TO service_role;


--
-- Name: TABLE support_access_requests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.support_access_requests TO service_role;


--
-- Name: TABLE support_audit_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.support_audit_events TO service_role;


--
-- Name: SEQUENCE support_audit_events_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.support_audit_events_id_seq TO anon;
GRANT ALL ON SEQUENCE public.support_audit_events_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.support_audit_events_id_seq TO service_role;


--
-- Name: TABLE team_invitations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.team_invitations TO service_role;


--
-- Name: TABLE timekeeping_edit_audit; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.timekeeping_edit_audit TO service_role;
GRANT SELECT ON TABLE public.timekeeping_edit_audit TO authenticated;


--
-- Name: TABLE timekeeping_employees; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.timekeeping_employees TO anon;
GRANT ALL ON TABLE public.timekeeping_employees TO authenticated;
GRANT ALL ON TABLE public.timekeeping_employees TO service_role;


--
-- Name: TABLE timekeeping_entries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.timekeeping_entries TO anon;
GRANT ALL ON TABLE public.timekeeping_entries TO authenticated;
GRANT ALL ON TABLE public.timekeeping_entries TO service_role;


--
-- Name: TABLE timekeeping_entry_history; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.timekeeping_entry_history TO anon;
GRANT ALL ON TABLE public.timekeeping_entry_history TO authenticated;
GRANT ALL ON TABLE public.timekeeping_entry_history TO service_role;


--
-- Name: TABLE timekeeping_equipment; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.timekeeping_equipment TO authenticated;
GRANT ALL ON TABLE public.timekeeping_equipment TO service_role;


--
-- Name: TABLE timekeeping_pay_period_audit; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.timekeeping_pay_period_audit TO authenticated;
GRANT ALL ON TABLE public.timekeeping_pay_period_audit TO service_role;


--
-- Name: TABLE timekeeping_pay_periods; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.timekeeping_pay_periods TO authenticated;
GRANT ALL ON TABLE public.timekeeping_pay_periods TO service_role;


--
-- Name: TABLE training_progress; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.training_progress TO anon;
GRANT ALL ON TABLE public.training_progress TO authenticated;
GRANT ALL ON TABLE public.training_progress TO service_role;


--
-- Name: TABLE training_videos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.training_videos TO anon;
GRANT ALL ON TABLE public.training_videos TO authenticated;
GRANT ALL ON TABLE public.training_videos TO service_role;


--
-- Name: TABLE unit_prices; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.unit_prices TO anon;
GRANT ALL ON TABLE public.unit_prices TO authenticated;
GRANT ALL ON TABLE public.unit_prices TO service_role;


--
-- Name: TABLE user_dashboard_preferences; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_dashboard_preferences TO authenticated;
GRANT ALL ON TABLE public.user_dashboard_preferences TO service_role;


--
-- Name: TABLE utility_packet_import_rows; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.utility_packet_import_rows TO service_role;


--
-- Name: TABLE utility_packet_imports; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.utility_packet_imports TO service_role;


--
-- Name: TABLE utility_packet_unit_aliases; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.utility_packet_unit_aliases TO service_role;


--
-- Name: TABLE work_points; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.work_points TO service_role;


--
-- PostgreSQL database dump complete
--



--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: objects billing attachment company delete; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "billing attachment company delete" ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'billing-export-attachments'::text) AND public.linecrew_can_use_billing_exports_internal() AND (EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND p.active AND ((p.company_id)::text = (storage.foldername(objects.name))[1]))))));


--
-- Name: objects billing attachment company read; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "billing attachment company read" ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'billing-export-attachments'::text) AND public.linecrew_can_use_billing_exports_internal() AND (EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND p.active AND ((p.company_id)::text = (storage.foldername(objects.name))[1]))))));


--
-- Name: objects billing attachment company upload; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "billing attachment company upload" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'billing-export-attachments'::text) AND public.linecrew_can_use_billing_exports_internal() AND (EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND p.active AND ((p.company_id)::text = (storage.foldername(objects.name))[1]))))));


--
-- Name: objects company_logo_company_settings_delete; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY company_logo_company_settings_delete ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'company-logos'::text) AND ((storage.foldername(name))[1] = ( SELECT (p.company_id)::text AS company_id
   FROM public.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND (p.active IS TRUE)))) AND public.linecrew_has_capability('company_settings'::text)));


--
-- Name: objects company_logo_company_settings_insert; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY company_logo_company_settings_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'company-logos'::text) AND ((storage.foldername(name))[1] = ( SELECT (p.company_id)::text AS company_id
   FROM public.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND (p.active IS TRUE)))) AND public.linecrew_has_capability('company_settings'::text)));


--
-- Name: objects daily_report_storage_company_insert; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY daily_report_storage_company_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'daily-report-attachments'::text) AND ((storage.foldername(name))[1] = (public.my_company_id())::text) AND (EXISTS ( SELECT 1
   FROM public.daily_reports report
  WHERE (((report.id)::text = (storage.foldername(objects.name))[2]) AND (report.company_id = public.my_company_id()))))));


--
-- Name: objects daily_report_storage_company_select; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY daily_report_storage_company_select ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'daily-report-attachments'::text) AND ((storage.foldername(name))[1] = (public.my_company_id())::text) AND (EXISTS ( SELECT 1
   FROM public.daily_reports report
  WHERE (((report.id)::text = (storage.foldername(objects.name))[2]) AND (report.company_id = public.my_company_id()))))));


--
-- Name: objects daily_report_storage_owner_or_lead_delete; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY daily_report_storage_owner_or_lead_delete ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'daily-report-attachments'::text) AND ((storage.foldername(name))[1] = (public.my_company_id())::text) AND (EXISTS ( SELECT 1
   FROM public.daily_reports report
  WHERE (((report.id)::text = (storage.foldername(objects.name))[2]) AND (report.company_id = public.my_company_id())))) AND ((owner_id = (auth.uid())::text) OR public.can_review_daily_reports())));


--
-- Name: objects jsa uploads company delete; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "jsa uploads company delete" ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'jsa-uploads'::text) AND ((storage.foldername(name))[1] = (public.my_company_id())::text) AND (EXISTS ( SELECT 1
   FROM public.daily_report_jsas jsa
  WHERE (((jsa.id)::text = (storage.foldername(objects.name))[2]) AND (jsa.company_id = public.my_company_id()) AND ((jsa.created_by = auth.uid()) OR (public.my_role() = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((public.my_role() = 'superintendent'::text) AND public.linecrew_has_capability('safety_records'::text))))))));


--
-- Name: objects jsa uploads company insert; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "jsa uploads company insert" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'jsa-uploads'::text) AND ((storage.foldername(name))[1] = (public.my_company_id())::text) AND (EXISTS ( SELECT 1
   FROM public.daily_report_jsas jsa
  WHERE (((jsa.id)::text = (storage.foldername(objects.name))[2]) AND (jsa.company_id = public.my_company_id()) AND (jsa.created_by = auth.uid()))))));


--
-- Name: objects jsa uploads company read; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "jsa uploads company read" ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'jsa-uploads'::text) AND ((storage.foldername(name))[1] = (public.my_company_id())::text) AND (EXISTS ( SELECT 1
   FROM public.daily_report_jsas jsa
  WHERE (((jsa.id)::text = (storage.foldername(objects.name))[2]) AND (jsa.company_id = public.my_company_id()) AND ((jsa.created_by = auth.uid()) OR (public.my_role() = ANY (ARRAY['owner'::text, 'admin'::text, 'gf'::text])) OR ((public.my_role() = 'superintendent'::text) AND public.linecrew_has_capability('safety_records'::text))))))));


--
-- Name: objects linecrew_active_profile_required_for_company_files; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY linecrew_active_profile_required_for_company_files ON storage.objects AS RESTRICTIVE TO authenticated USING (((NOT (bucket_id = ANY (ARRAY['billing-export-attachments'::text, 'daily-report-attachments'::text, 'jsa-uploads'::text]))) OR public.current_user_has_active_profile())) WITH CHECK (((NOT (bucket_id = ANY (ARRAY['billing-export-attachments'::text, 'daily-report-attachments'::text, 'jsa-uploads'::text]))) OR public.current_user_has_active_profile()));


--
-- Name: objects linecrew_privileged_mfa_storage_delete; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY linecrew_privileged_mfa_storage_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated USING (( SELECT public.linecrew_privileged_mfa_satisfied() AS linecrew_privileged_mfa_satisfied));


--
-- Name: objects linecrew_privileged_mfa_storage_insert; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY linecrew_privileged_mfa_storage_insert ON storage.objects AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (( SELECT public.linecrew_privileged_mfa_satisfied() AS linecrew_privileged_mfa_satisfied));


--
-- Name: objects linecrew_privileged_mfa_storage_select; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY linecrew_privileged_mfa_storage_select ON storage.objects AS RESTRICTIVE FOR SELECT TO authenticated USING (( SELECT public.linecrew_privileged_mfa_satisfied() AS linecrew_privileged_mfa_satisfied));


--
-- Name: objects linecrew_privileged_mfa_storage_update; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY linecrew_privileged_mfa_storage_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated USING (( SELECT public.linecrew_privileged_mfa_satisfied() AS linecrew_privileged_mfa_satisfied)) WITH CHECK (( SELECT public.linecrew_privileged_mfa_satisfied() AS linecrew_privileged_mfa_satisfied));


--
-- Name: objects training_videos_role_subscriber_select; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY training_videos_role_subscriber_select ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'training-videos'::text) AND (EXISTS ( SELECT 1
   FROM (public.training_videos tv
     JOIN LATERAL public.current_training_access() a(company_id, role, subscription_status, can_train) ON (true))
  WHERE ((tv.storage_path = objects.name) AND (tv.active IS TRUE) AND (a.can_train IS TRUE) AND (public.training_role_rank(a.role) >= public.training_role_rank(tv.minimum_role)))))));


--
-- PostgreSQL database dump complete
--


