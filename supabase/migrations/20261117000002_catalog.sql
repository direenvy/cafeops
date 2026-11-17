-- Menu catalogue and the ingredient inventory it consumes.

create table public.suppliers (
    id            uuid primary key default gen_random_uuid(),
    name          text not null unique check (length(trim(name)) between 1 and 120),
    contact_name  text,
    contact_email text check (contact_email is null or contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    phone         text,
    notes         text,
    is_active     boolean not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

create table public.ingredients (
    id             uuid primary key default gen_random_uuid(),
    name           text not null unique check (length(trim(name)) between 1 and 120),
    unit           text not null check (unit in ('g', 'kg', 'ml', 'l', 'pc', 'shot')),
    stock_qty      numeric(12, 3) not null default 0 check (stock_qty >= 0),
    reorder_level  numeric(12, 3) not null default 0 check (reorder_level >= 0),
    cost_per_unit  numeric(12, 4) not null default 0 check (cost_per_unit >= 0),
    supplier_id    uuid references public.suppliers (id) on delete set null,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

comment on column public.ingredients.stock_qty is
    'Derived balance. Only ever written by the API inside the same transaction that writes stock_movements, never by a client.';

create index ingredients_supplier_idx on public.ingredients (supplier_id);
create index ingredients_low_stock_idx on public.ingredients (id) where stock_qty <= reorder_level;

create table public.menu_categories (
    id         uuid primary key default gen_random_uuid(),
    name       text not null unique check (length(trim(name)) between 1 and 60),
    sort_order integer not null default 0,
    created_at timestamptz not null default now()
);

create table public.menu_items (
    id           uuid primary key default gen_random_uuid(),
    category_id  uuid not null references public.menu_categories (id) on delete restrict,
    name         text not null check (length(trim(name)) between 1 and 120),
    description  text,
    price        numeric(10, 2) not null check (price >= 0),
    image_url    text,
    is_available boolean not null default true,
    sort_order   integer not null default 0,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (category_id, name)
);

create index menu_items_category_idx on public.menu_items (category_id);

-- The recipe is what makes an order a stock event rather than just a row:
-- selling one latte has to draw down espresso beans and milk.
create table public.recipe_items (
    menu_item_id     uuid not null references public.menu_items (id) on delete cascade,
    ingredient_id    uuid not null references public.ingredients (id) on delete restrict,
    qty_per_serving  numeric(12, 3) not null check (qty_per_serving > 0),
    primary key (menu_item_id, ingredient_id)
);

create index recipe_items_ingredient_idx on public.recipe_items (ingredient_id);

create trigger suppliers_touch_updated_at
    before update on public.suppliers
    for each row execute function public.touch_updated_at();

create trigger ingredients_touch_updated_at
    before update on public.ingredients
    for each row execute function public.touch_updated_at();

create trigger menu_items_touch_updated_at
    before update on public.menu_items
    for each row execute function public.touch_updated_at();
