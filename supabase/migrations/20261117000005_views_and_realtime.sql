-- Reporting views and realtime wiring.

-- security_invoker = true makes these views run with the privileges of the
-- caller rather than the view owner, so the RLS policies on the underlying
-- tables still apply. Without it a view is a hole straight through RLS.

create view public.v_low_stock
with (security_invoker = true)
as
select i.id,
       i.name,
       i.unit,
       i.stock_qty,
       i.reorder_level,
       i.stock_qty - i.reorder_level as headroom,
       s.name                        as supplier_name,
       s.contact_email               as supplier_email
from public.ingredients i
left join public.suppliers s on s.id = i.supplier_id
where i.stock_qty <= i.reorder_level
order by (i.stock_qty - i.reorder_level) asc, i.name asc;

comment on view public.v_low_stock is
    'Ingredients at or below their reorder level, worst first.';

create view public.v_active_orders
with (security_invoker = true)
as
select o.id,
       o.order_number,
       o.table_label,
       o.status,
       o.note,
       o.total,
       o.created_at,
       p.full_name                                   as placed_by_name,
       count(oi.id)                                  as line_count,
       count(oi.id) filter (where oi.status = 'ready') as ready_count,
       min(oi.created_at)                            as first_line_at,
       extract(epoch from (now() - o.created_at))::int as age_seconds
from public.orders o
left join public.order_items oi on oi.order_id = o.id and oi.status <> 'cancelled'
left join public.profiles p     on p.id = o.placed_by
where o.status in ('open', 'preparing', 'ready', 'served')
group by o.id, p.full_name
order by o.created_at asc;

comment on view public.v_active_orders is
    'The kitchen board: every order still in play, oldest first, with its line progress.';

create view public.v_daily_sales
with (security_invoker = true)
as
select (o.closed_at at time zone 'Asia/Kuala_Lumpur')::date as business_day,
       count(*)                                             as orders_paid,
       sum(o.subtotal)                                      as subtotal,
       sum(o.service_charge)                                as service_charge,
       sum(o.tax)                                           as tax,
       sum(o.total)                                         as total,
       round(avg(o.total), 2)                               as average_order_value
from public.orders o
where o.status = 'paid'
group by 1
order by 1 desc;

comment on view public.v_daily_sales is
    'Paid orders rolled up by business day in the shop timezone, not UTC.';

grant select on public.v_low_stock     to authenticated;
grant select on public.v_active_orders to authenticated;
grant select on public.v_daily_sales   to authenticated;

-- Realtime needs the full old row to evaluate RLS on a change event and to
-- hand the client the previous values on an update.
alter table public.orders      replica identity full;
alter table public.order_items replica identity full;

alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.order_items;
