-- Row-level security.
--
-- The split that defines this project's architecture lives here:
--
--   * Reads are open to the client under RLS, so Flutter can subscribe to
--     realtime changes directly and the order board updates with no polling.
--   * Writes that move money or stock have NO policy for the `authenticated`
--     role, so PostgREST refuses them outright. They are only reachable through
--     the ASP.NET Core API, which connects with the service role and wraps the
--     whole operation in one transaction.
--
-- Column-level intent that RLS cannot express is enforced by the guard triggers
-- at the bottom of this file.

alter table public.profiles        enable row level security;
alter table public.suppliers       enable row level security;
alter table public.ingredients     enable row level security;
alter table public.menu_categories enable row level security;
alter table public.menu_items      enable row level security;
alter table public.recipe_items    enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;
alter table public.stock_movements enable row level security;
alter table public.order_counters  enable row level security;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;

-- ---------------------------------------------------------------- profiles --

create policy profiles_select_self_or_manager on public.profiles
    for select to authenticated
    using (id = auth.uid() or public.is_manager());

create policy profiles_update_self on public.profiles
    for update to authenticated
    using (id = auth.uid())
    with check (id = auth.uid());

create policy profiles_update_any_by_owner on public.profiles
    for update to authenticated
    using (public.is_owner())
    with check (public.is_owner());

grant update on public.profiles to authenticated;

-- ------------------------------------------------- catalogue and inventory --

create policy suppliers_read on public.suppliers
    for select to authenticated using (true);
create policy suppliers_write on public.suppliers
    for all to authenticated using (public.is_manager()) with check (public.is_manager());

create policy ingredients_read on public.ingredients
    for select to authenticated using (true);
create policy ingredients_write on public.ingredients
    for all to authenticated using (public.is_manager()) with check (public.is_manager());

create policy menu_categories_read on public.menu_categories
    for select to authenticated using (true);
create policy menu_categories_write on public.menu_categories
    for all to authenticated using (public.is_manager()) with check (public.is_manager());

create policy menu_items_read on public.menu_items
    for select to authenticated using (true);
create policy menu_items_write on public.menu_items
    for all to authenticated using (public.is_manager()) with check (public.is_manager());

create policy recipe_items_read on public.recipe_items
    for select to authenticated using (true);
create policy recipe_items_write on public.recipe_items
    for all to authenticated using (public.is_manager()) with check (public.is_manager());

grant insert, update, delete on public.suppliers       to authenticated;
grant insert, update, delete on public.ingredients     to authenticated;
grant insert, update, delete on public.menu_categories to authenticated;
grant insert, update, delete on public.menu_items      to authenticated;
grant insert, update, delete on public.recipe_items    to authenticated;

-- ---------------------------------------------------- orders and the board --

-- Anyone on shift can watch the board.
create policy orders_read on public.orders
    for select to authenticated using (true);
create policy order_items_read on public.order_items
    for select to authenticated using (true);

-- Deliberately no INSERT policy: placing an order is an API-only operation.

-- Staff advance the kitchen state of a line. The guard trigger below limits
-- this to the status column, so this cannot be used to re-price a sale.
create policy order_items_advance_status on public.order_items
    for update to authenticated using (true) with check (true);

-- Managers move an order through the board. The guard trigger blocks the
-- transition to paid, which belongs to the API checkout transaction.
create policy orders_update_status on public.orders
    for update to authenticated
    using (public.is_manager())
    with check (public.is_manager());

grant update on public.order_items to authenticated;
grant update on public.orders      to authenticated;

-- --------------------------------------------------------- stock movements --

-- Read-only, and only for managers: the ledger is written by the API alone.
create policy stock_movements_read on public.stock_movements
    for select to authenticated using (public.is_manager());

revoke select on public.order_counters from authenticated;

-- ---------------------------------------------------------- guard triggers --

-- True when the statement arrives without an end-user JWT, i.e. from the API
-- service-role connection or from a migration. Client requests always carry a
-- sub claim, so auth.uid() is non-null for them.
create function public.is_trusted_server()
returns boolean
language sql
stable
as $$
    select auth.uid() is null;
$$;

create function public.guard_profile_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.role is distinct from old.role
       and not public.is_trusted_server()
       and not public.is_owner() then
        raise exception 'only an owner may change a user role'
            using errcode = 'insufficient_privilege';
    end if;
    return new;
end;
$$;

create trigger profiles_guard_role
    before update on public.profiles
    for each row execute function public.guard_profile_role();

create function public.guard_ingredient_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.stock_qty is distinct from old.stock_qty and not public.is_trusted_server() then
        raise exception 'stock_qty is a derived balance; post a stock movement through the API instead'
            using errcode = 'insufficient_privilege';
    end if;
    return new;
end;
$$;

create trigger ingredients_guard_stock
    before update on public.ingredients
    for each row execute function public.guard_ingredient_stock();

create function public.guard_order_item_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if public.is_trusted_server() then
        return new;
    end if;

    if new.order_id         is distinct from old.order_id
       or new.menu_item_id  is distinct from old.menu_item_id
       or new.qty           is distinct from old.qty
       or new.unit_price    is distinct from old.unit_price
       or new.line_total    is distinct from old.line_total
       or new.name_snapshot is distinct from old.name_snapshot then
        raise exception 'a client may only change order_items.status'
            using errcode = 'insufficient_privilege';
    end if;

    return new;
end;
$$;

create trigger order_items_guard_update
    before update on public.order_items
    for each row execute function public.guard_order_item_update();

create function public.guard_order_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if public.is_trusted_server() then
        return new;
    end if;

    if new.status = 'paid' and old.status <> 'paid' then
        raise exception 'checkout is handled by the API so that payment and stock settle together'
            using errcode = 'insufficient_privilege';
    end if;

    if new.subtotal          is distinct from old.subtotal
       or new.service_charge is distinct from old.service_charge
       or new.tax            is distinct from old.tax
       or new.total          is distinct from old.total
       or new.order_number   is distinct from old.order_number
       or new.placed_by      is distinct from old.placed_by then
        raise exception 'a client may only change an order status or note'
            using errcode = 'insufficient_privilege';
    end if;

    return new;
end;
$$;

create trigger orders_guard_update
    before update on public.orders
    for each row execute function public.guard_order_update();
