-- Orders, their lines, and the stock ledger they move.

create type public.order_status      as enum ('open', 'preparing', 'ready', 'served', 'paid', 'cancelled');
create type public.order_item_status as enum ('queued', 'preparing', 'ready', 'served', 'cancelled');
create type public.stock_reason      as enum ('delivery', 'sale', 'waste', 'adjustment', 'stock_count', 'void');

-- Human-friendly, per-day order numbers (e.g. 20261117-007). A plain sequence
-- would leak lifetime volume and restart awkwardly; this counter is atomic
-- because the upsert takes a row lock for the day it touches.
create table public.order_counters (
    day        date primary key,
    last_value integer not null default 0
);

create function public.next_order_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
    seq   integer;
begin
    insert into public.order_counters (day, last_value)
    values (today, 1)
    on conflict (day) do update set last_value = public.order_counters.last_value + 1
    returning last_value into seq;

    return to_char(today, 'YYYYMMDD') || '-' || lpad(seq::text, 3, '0');
end;
$$;

create table public.orders (
    id             uuid primary key default gen_random_uuid(),
    order_number   text not null unique default public.next_order_number(),
    table_label    text not null check (length(trim(table_label)) between 1 and 20),
    status         public.order_status not null default 'open',
    note           text,
    subtotal       numeric(10, 2) not null default 0 check (subtotal >= 0),
    service_charge numeric(10, 2) not null default 0 check (service_charge >= 0),
    tax            numeric(10, 2) not null default 0 check (tax >= 0),
    total          numeric(10, 2) not null default 0 check (total >= 0),
    placed_by      uuid references public.profiles (id) on delete set null,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    closed_at      timestamptz,
    constraint orders_closed_when_final check (
        (status in ('paid', 'cancelled')) = (closed_at is not null)
    )
);

create index orders_status_idx     on public.orders (status) where status not in ('paid', 'cancelled');
create index orders_created_at_idx on public.orders (created_at desc);
create index orders_placed_by_idx  on public.orders (placed_by);

create table public.order_items (
    id            uuid primary key default gen_random_uuid(),
    order_id      uuid not null references public.orders (id) on delete cascade,
    menu_item_id  uuid not null references public.menu_items (id) on delete restrict,
    name_snapshot text not null,
    qty           integer not null check (qty > 0),
    unit_price    numeric(10, 2) not null check (unit_price >= 0),
    line_total    numeric(10, 2) not null check (line_total >= 0),
    status        public.order_item_status not null default 'queued',
    note          text,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

comment on column public.order_items.unit_price is
    'Price captured at the moment of sale. Re-reading menu_items.price later would silently rewrite history when prices change.';
comment on column public.order_items.name_snapshot is
    'Item name at the moment of sale, so a renamed or deleted menu item does not corrupt old receipts.';

create index order_items_order_idx  on public.order_items (order_id);
create index order_items_status_idx on public.order_items (status) where status in ('queued', 'preparing');

-- Append-only ledger. ingredients.stock_qty is the running balance; this table
-- is why that balance can be explained and audited.
create table public.stock_movements (
    id            uuid primary key default gen_random_uuid(),
    ingredient_id uuid not null references public.ingredients (id) on delete restrict,
    delta         numeric(12, 3) not null check (delta <> 0),
    balance_after numeric(12, 3) not null check (balance_after >= 0),
    reason        public.stock_reason not null,
    order_id      uuid references public.orders (id) on delete set null,
    supplier_id   uuid references public.suppliers (id) on delete set null,
    unit_cost     numeric(12, 4) check (unit_cost is null or unit_cost >= 0),
    note          text,
    created_by    uuid references public.profiles (id) on delete set null,
    created_at    timestamptz not null default now()
);

create index stock_movements_ingredient_idx on public.stock_movements (ingredient_id, created_at desc);
create index stock_movements_order_idx      on public.stock_movements (order_id);
create index stock_movements_created_at_idx on public.stock_movements (created_at desc);

create trigger orders_touch_updated_at
    before update on public.orders
    for each row execute function public.touch_updated_at();

create trigger order_items_touch_updated_at
    before update on public.order_items
    for each row execute function public.touch_updated_at();
