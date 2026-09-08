alter table public.beta_applications
  add column if not exists sales_notification_status text not null default 'pending',
  add column if not exists sales_notification_attempts integer not null default 0,
  add column if not exists sales_notification_last_attempt_at timestamptz,
  add column if not exists sales_notification_sent_at timestamptz,
  add column if not exists sales_notification_provider_id text,
  add column if not exists sales_notification_error text;

alter table public.beta_applications
  drop constraint if exists beta_applications_sales_notification_status_check,
  add constraint beta_applications_sales_notification_status_check
    check (sales_notification_status in ('pending', 'sent', 'failed')),
  drop constraint if exists beta_applications_sales_notification_attempts_check,
  add constraint beta_applications_sales_notification_attempts_check
    check (sales_notification_attempts >= 0);

comment on column public.beta_applications.sales_notification_status is
  'Latest Resend acceptance result for the internal sales notification.';
comment on column public.beta_applications.sales_notification_provider_id is
  'Resend email ID returned when the provider accepts the notification.';
comment on column public.beta_applications.sales_notification_error is
  'Sanitized provider/configuration error from the latest attempt; never contains an API key.';
