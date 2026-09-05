-- Caller-facing detailed readers mask Field Money columns server-side.

create or replace function public.get_price_book_items_visible(p_price_book_id uuid)
returns table (
  id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text,
  description text, install_price numeric, transfer_price numeric,
  retirement_price numeric, unit_of_measure text, category text, extra_data jsonb,
  active boolean, created_at timestamptz, updated_at timestamptz,
  actual_install_price numeric, actual_transfer_price numeric,
  actual_retirement_price numeric, adjusted_install_price numeric,
  adjusted_transfer_price numeric, adjusted_retirement_price numeric,
  has_adjustment boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select item.id, item.company_id, item.price_book_id, item.item_code,
    item.item_name, item.description,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.install_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.transfer_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.retirement_price else null end,
    item.unit_of_measure, item.category, item.extra_data, item.active,
    item.created_at, item.updated_at,
    item.actual_install_price, item.actual_transfer_price,
    item.actual_retirement_price,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_install_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_transfer_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_retirement_price else null end,
    item.has_adjustment
  from public.get_price_book_items_for_user(p_price_book_id) item;
$$;

create or replace function public.get_daily_report_unit_catalog_visible(p_report_id uuid)
returns table (
  price_book_item_id uuid, item_code text, item_name text, description text,
  unit_of_measure text, category text, install_price numeric,
  retirement_price numeric, actual_install_price numeric,
  actual_retirement_price numeric, adjusted_install_price numeric,
  adjusted_retirement_price numeric, has_adjustment boolean,
  install_quantity numeric, retirement_quantity numeric,
  actual_line_value numeric, adjusted_line_value numeric,
  visible_line_value numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  select item.price_book_item_id, item.item_code, item.item_name,
    item.description, item.unit_of_measure, item.category,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.install_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.retirement_price else null end,
    item.actual_install_price, item.actual_retirement_price,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_install_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_retirement_price else null end,
    item.has_adjustment, item.install_quantity, item.retirement_quantity,
    item.actual_line_value,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_line_value else null end,
    case
      when public.linecrew_has_capability('actual_pricing') then item.actual_line_value
      when public.linecrew_has_capability('field_pricing') then item.adjusted_line_value
      else null
    end
  from public.get_daily_report_unit_catalog(p_report_id) item;
$$;

create or replace function public.get_daily_report_unit_locations_visible_v2(p_report_id uuid)
returns table (
  location_line_id uuid, price_book_item_id uuid, item_code text, item_name text,
  description text, unit_of_measure text, category text, pole_location text,
  install_price numeric, retirement_price numeric, actual_install_price numeric,
  actual_retirement_price numeric, adjusted_install_price numeric,
  adjusted_retirement_price numeric, has_adjustment boolean,
  install_quantity numeric, transfer_quantity numeric, retirement_quantity numeric,
  actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric,
  authorization_status text, authorization_note text
)
language sql
stable
security definer
set search_path = ''
as $$
  select item.location_line_id, item.price_book_item_id, item.item_code,
    item.item_name, item.description, item.unit_of_measure, item.category,
    item.pole_location,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.install_price else null end,
    case when public.linecrew_has_capability('actual_pricing') or
                   public.linecrew_has_capability('field_pricing')
      then item.retirement_price else null end,
    item.actual_install_price, item.actual_retirement_price,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_install_price else null end,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_retirement_price else null end,
    item.has_adjustment, item.install_quantity, item.transfer_quantity,
    item.retirement_quantity, item.actual_line_value,
    case when public.linecrew_has_capability('field_pricing')
      then item.adjusted_line_value else null end,
    case
      when public.linecrew_has_capability('actual_pricing') then item.actual_line_value
      when public.linecrew_has_capability('field_pricing') then item.adjusted_line_value
      else null
    end,
    item.authorization_status, item.authorization_note
  from public.get_daily_report_unit_locations_v2(p_report_id) item;
$$;

revoke all on function public.get_price_book_items_visible(uuid) from public, anon;
revoke all on function public.get_daily_report_unit_catalog_visible(uuid) from public, anon;
revoke all on function public.get_daily_report_unit_locations_visible_v2(uuid) from public, anon;
grant execute on function public.get_price_book_items_visible(uuid) to authenticated;
grant execute on function public.get_daily_report_unit_catalog_visible(uuid) to authenticated;
grant execute on function public.get_daily_report_unit_locations_visible_v2(uuid) to authenticated;
