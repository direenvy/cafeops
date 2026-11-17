-- Hardening pass, driven by the Supabase database linter.
--
-- Two classes of finding, both real:
--
-- 1. Mutable search_path on functions. Without a pinned search_path, a caller
--    can prepend a schema of their own and shadow an unqualified name the
--    function relies on. Pinned to '' here, so every reference must be
--    schema-qualified and nothing can be shadowed.
--
-- 2. SECURITY DEFINER functions reachable over the REST API. Supabase grants
--    EXECUTE on public functions to anon and authenticated by default, which
--    exposed the trigger guards and the order-number generator as callable
--    RPC endpoints. None of them is meant to be called directly.

alter function public.touch_updated_at()  set search_path = '';
alter function public.is_trusted_server() set search_path = '';

-- Trigger functions: Postgres does not check EXECUTE when firing a trigger,
-- so revoking this costs nothing and closes the RPC route.
revoke execute on function public.touch_updated_at()        from anon, authenticated;
revoke execute on function public.handle_new_user()         from anon, authenticated;
revoke execute on function public.guard_profile_role()      from anon, authenticated;
revoke execute on function public.guard_ingredient_stock()  from anon, authenticated;
revoke execute on function public.guard_order_item_update() from anon, authenticated;
revoke execute on function public.guard_order_update()      from anon, authenticated;
revoke execute on function public.is_trusted_server()       from anon, authenticated;

-- Only the API inserts orders, and it connects as a role that owns the table,
-- so no client needs to generate an order number.
revoke execute on function public.next_order_number() from anon, authenticated;

-- These three stay executable by authenticated on purpose: RLS policies are
-- evaluated with the privileges of the querying role, so revoking EXECUTE here
-- would break every policy that calls them. They are safe to expose because
-- each one only ever reports the caller's own role.
revoke execute on function public.current_user_role() from anon;
revoke execute on function public.is_manager()        from anon;
revoke execute on function public.is_owner()          from anon;

-- RLS is enabled on this table with no policy, which the linter reports as
-- INFO. That is the intent: no policy means no client can read or write it,
-- while the API's role bypasses RLS entirely.
comment on table public.order_counters is
    'Server-only daily order-number counter. RLS on with no policy = deny all clients by design.';
