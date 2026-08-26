alter function public.plan_monthly_cents(text) set search_path = '';
alter function public.recommended_crew_plan(integer) set search_path = '';
alter function public.create_daily_report(uuid,date,numeric,numeric,text,text) set search_path = '';
alter function public.return_daily_report(uuid,text) set search_path = '';
alter function public.timekeeping_period_state(date,date) set search_path = '';
alter function public.timekeeping_set_period_status(date,date,text) set search_path = '';
alter function public.linecrew_set_member_role(uuid,text) set search_path = '';
alter function public.linecrew_set_superintendent_permissions(uuid,jsonb) set search_path = '';
