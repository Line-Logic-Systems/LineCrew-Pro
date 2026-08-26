create index if not exists billing_events_company_id_idx on public.billing_events(company_id);
create index if not exists platform_owner_audit_events_actor_user_id_idx on public.platform_owner_audit_events(actor_user_id);
create index if not exists platform_owners_created_by_idx on public.platform_owners(created_by);
