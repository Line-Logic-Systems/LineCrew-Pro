-- Supabase can apply explicit API-role grants when functions are created.
-- Keep the owner-only subscription mutation unavailable to anonymous callers.

revoke execute on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text,integer) from anon;
revoke execute on function public.linecrew_monthly_cents(integer) from anon;
