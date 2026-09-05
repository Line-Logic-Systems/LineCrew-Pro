begin;

do $$
begin
  if to_regprocedure('public.set_job_active(uuid,boolean)') is not null then
    execute 'revoke all on function public.set_job_active(uuid,boolean) from public, anon, authenticated';
    execute 'drop function public.set_job_active(uuid,boolean)';
  end if;
end;
$$;

commit;
