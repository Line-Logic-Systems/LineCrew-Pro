-- Keep legacy billing implementations available only for trusted server-side
-- composition. Client billing must enter through the guarded v3 RPC.

revoke execute on function public.create_billing_export_batch(
  uuid,
  date,
  date,
  boolean,
  text
) from public, anon, authenticated;

revoke execute on function public.create_billing_export_batch_v2(
  uuid,
  date,
  date,
  boolean,
  text,
  boolean
) from public, anon, authenticated;

-- Reassert the intended public API explicitly. v3 performs the current
-- authorization and Final Bill safeguards before calling the legacy helpers.
revoke execute on function public.create_billing_export_batch_v3(
  uuid,
  date,
  date,
  boolean,
  text,
  boolean,
  text
) from public, anon;

grant execute on function public.create_billing_export_batch_v3(
  uuid,
  date,
  date,
  boolean,
  text,
  boolean,
  text
) to authenticated, service_role;
