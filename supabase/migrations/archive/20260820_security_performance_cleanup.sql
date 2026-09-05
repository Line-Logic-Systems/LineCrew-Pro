begin;

-- Security cleanup from Supabase advisor review.
revoke all on function public.create_standalone_jsa_v2(uuid,date,text,text,text,text,text,text,text,text,text,boolean,jsonb) from public;
revoke all on function public.create_standalone_jsa_v2(uuid,date,text,text,text,text,text,text,text,text,text,boolean,jsonb) from anon;
grant execute on function public.create_standalone_jsa_v2(uuid,date,text,text,text,text,text,text,text,text,text,boolean,jsonb) to authenticated;

revoke all on function public.get_company_jsas_v2() from public;
revoke all on function public.get_company_jsas_v2() from anon;
grant execute on function public.get_company_jsas_v2() to authenticated;

alter function public.training_role_rank(text) set search_path = '';

-- High-value foreign key indexes for common production/reporting paths.
create index if not exists audit_log_company_id_idx on public.audit_log(company_id);
create index if not exists audit_log_user_id_idx on public.audit_log(user_id);
create index if not exists crews_company_id_idx on public.crews(company_id);
create index if not exists crews_foreman_id_idx on public.crews(foreman_id);
create index if not exists employees_company_id_idx on public.employees(company_id);
create index if not exists employees_crew_id_idx on public.employees(crew_id);
create index if not exists daily_reports_crew_id_idx on public.daily_reports(crew_id);
create index if not exists daily_reports_price_book_id_idx on public.daily_reports(price_book_id);
create index if not exists daily_reports_reviewed_by_idx on public.daily_reports(reviewed_by);
create index if not exists daily_reports_approved_by_idx on public.daily_reports(approved_by);
create index if not exists daily_report_attachments_daily_report_id_idx on public.daily_report_attachments(daily_report_id);
create index if not exists daily_report_jsas_job_id_idx on public.daily_report_jsas(job_id);
create index if not exists job_packages_job_id_idx on public.job_packages(job_id);
create index if not exists job_packages_contract_id_idx on public.job_packages(contract_id);
create index if not exists job_package_work_points_job_id_idx on public.job_package_work_points(job_id);
create index if not exists job_package_authorized_units_job_package_id_idx on public.job_package_authorized_units(job_package_id);
create index if not exists job_package_authorized_units_price_book_item_id_idx on public.job_package_authorized_units(price_book_item_id);
create index if not exists daily_production_units_job_id_idx on public.daily_production_units(job_id);
create index if not exists daily_production_units_contract_id_idx on public.daily_production_units(contract_id);
create index if not exists daily_production_units_price_book_id_idx on public.daily_production_units(price_book_id);
create index if not exists daily_production_units_price_book_item_id_idx on public.daily_production_units(price_book_item_id);
create index if not exists daily_production_unit_locations_daily_production_unit_id_idx on public.daily_production_unit_locations(daily_production_unit_id);
create index if not exists daily_production_unit_locations_price_book_item_id_idx on public.daily_production_unit_locations(price_book_item_id);
create index if not exists training_progress_company_id_idx on public.training_progress(company_id);
create index if not exists training_progress_video_id_idx on public.training_progress(video_id);

-- Remove confirmed duplicate indexes while preserving the newer canonical names.
drop index if exists public.idx_reports_company;
drop index if exists public.idx_reports_foreman;
drop index if exists public.idx_reports_job;

commit;