create or replace function public.get_daily_report_unit_catalog_visible_v2(p_report_id uuid)
returns table(
  price_book_item_id uuid,
  item_code text,
  item_name text,
  description text,
  unit_of_measure text,
  category text,
  install_price numeric,
  transfer_price numeric,
  retirement_price numeric,
  actual_install_price numeric,
  actual_transfer_price numeric,
  actual_retirement_price numeric,
  adjusted_install_price numeric,
  adjusted_transfer_price numeric,
  adjusted_retirement_price numeric,
  has_adjustment boolean,
  install_quantity numeric,
  retirement_quantity numeric,
  actual_line_value numeric,
  adjusted_line_value numeric,
  visible_line_value numeric
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
begin
  -- The existing guarded catalog establishes the report's immutable Price Book
  -- and field-value snapshots before transfer prices are projected.
  perform 1
  from public.get_daily_report_unit_catalog_visible(p_report_id)
  limit 1;

  return query
  select
    catalog.price_book_item_id,
    catalog.item_code,
    catalog.item_name,
    catalog.description,
    catalog.unit_of_measure,
    catalog.category,
    catalog.install_price,
    case
      when catalog.actual_install_price is not null then
        coalesce(saved.actual_transfer_price, item.transfer_price)
      when catalog.adjusted_install_price is not null then
        coalesce(
          saved.adjusted_transfer_price,
          round(item.transfer_price * coalesce(report.field_value_percent_snapshot, 100) / 100, 2)
        )
      else null
    end,
    catalog.retirement_price,
    catalog.actual_install_price,
    case when catalog.actual_install_price is not null
      then coalesce(saved.actual_transfer_price, item.transfer_price)
      else null
    end,
    catalog.actual_retirement_price,
    catalog.adjusted_install_price,
    case when catalog.adjusted_install_price is not null
      then coalesce(
        saved.adjusted_transfer_price,
        round(item.transfer_price * coalesce(report.field_value_percent_snapshot, 100) / 100, 2)
      )
      else null
    end,
    catalog.adjusted_retirement_price,
    catalog.has_adjustment,
    catalog.install_quantity,
    catalog.retirement_quantity,
    catalog.actual_line_value,
    catalog.adjusted_line_value,
    catalog.visible_line_value
  from public.get_daily_report_unit_catalog_visible(p_report_id) catalog
  join public.daily_reports report
    on report.id = p_report_id
  join public.price_book_items item
    on item.id = catalog.price_book_item_id
   and item.company_id = report.company_id
   and item.price_book_id = report.price_book_id
  left join public.daily_production_units saved
    on saved.daily_report_id = report.id
   and saved.company_id = report.company_id
   and saved.price_book_item_id = item.id;
end;
$$;

revoke all on function public.get_daily_report_unit_catalog_visible_v2(uuid) from public, anon;
grant execute on function public.get_daily_report_unit_catalog_visible_v2(uuid) to authenticated;
grant execute on function public.get_daily_report_unit_catalog_visible_v2(uuid) to service_role;
