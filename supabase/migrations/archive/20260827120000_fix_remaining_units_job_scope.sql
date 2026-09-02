begin;

-- LB-2: get_remaining_job_units_for_field counted production that does not
-- belong to this job.
--
-- daily_production_unit_locations has no job_id, so the original query matched
-- location rows on (company_id, price_book_item_id, normalized work point) and
-- then LEFT JOINed daily_reports carrying the job/archived/rejected filters in
-- its ON clause. A location row that failed those filters was not discarded --
-- it survived with every report column NULL, and the draft branch then matched
-- on those NULLs:
--
--   lower(coalesce(report.status, 'draft')) = 'draft'        -- NULL -> 'draft'
--   report.reviewed_at is null                               -- NULL -> true
--   nullif(trim(coalesce(report.review_notes, '')), '') is null   -- -> true
--
-- So production from a different job, an archived report, or a rejected report
-- was counted as draft_quantity and subtracted from remaining_quantity. Work
-- point codes repeat across jobs and normalize_work_point_key collapses
-- 'Pole 20', 'WP-20', '0020' and '20' to the same key, so collisions are the
-- normal case, not the edge case. Foremen saw authorized work as exhausted,
-- stopped reporting it, and the company under-billed.
--
-- The usage side is now INNER JOINed and scoped to this job through both the
-- parent production line (daily_production_units.job_id, NOT NULL) and the
-- owning daily report. An authorized unit with no production still appears with
-- zero usage via the final LEFT JOIN, so no row disappears from the result.
--
-- Nothing else changes: matching semantics, role gates, output columns and
-- ordering are all identical to 20260826234242_foreman_remaining_job_units.sql.

create or replace function public.get_remaining_job_units_for_field(
  p_job_id uuid
)
returns table (
  package_id uuid,
  package_name text,
  work_point_id uuid,
  work_point_code text,
  work_point_description text,
  authorized_unit_id uuid,
  unit_code text,
  unit_name text,
  unit_description text,
  work_type text,
  authorized_quantity numeric,
  draft_quantity numeric,
  submitted_quantity numeric,
  approved_quantity numeric,
  remaining_quantity numeric
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
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using errcode = '42501',
      message = 'An active company field or leadership profile is required.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('job_packages') then
    raise exception using errcode = '42501',
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
    raise exception using errcode = 'P0002',
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
            and report.reviewed_at is null
            and nullif(trim(coalesce(report.review_notes, '')), '') is null
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
     and report.archived is not true
     and lower(coalesce(report.status, 'draft')) <> 'rejected'
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

revoke all on function public.get_remaining_job_units_for_field(uuid)
  from public, anon;
grant execute on function public.get_remaining_job_units_for_field(uuid)
  to authenticated;

commit;
