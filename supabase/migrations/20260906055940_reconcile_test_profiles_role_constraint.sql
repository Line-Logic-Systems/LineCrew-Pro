-- Test-only drift repair authorized for Utility Portal v4.
-- Production does not contain this obsolete constraint. Its intersection with
-- profiles_role_supported prevents valid owner and superintendent roles.
alter table public.profiles
  drop constraint if exists profiles_role_check;
