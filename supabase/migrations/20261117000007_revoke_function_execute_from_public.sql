-- Follow-up to the hardening pass.
--
-- Revoking EXECUTE from anon and authenticated was not enough: Postgres grants
-- EXECUTE on every new function to the pseudo-role PUBLIC, which both of those
-- roles inherit. The grant has to be taken away from PUBLIC itself.
--
-- Worth keeping as its own migration rather than folding into the previous one:
-- the first attempt looked correct and the linter still reported the finding,
-- which is the whole reason to re-run the linter after a fix instead of
-- assuming it worked.

revoke execute on function public.next_order_number()       from public, anon, authenticated;
revoke execute on function public.guard_profile_role()      from public, anon, authenticated;
revoke execute on function public.guard_ingredient_stock()  from public, anon, authenticated;
revoke execute on function public.guard_order_item_update() from public, anon, authenticated;
revoke execute on function public.guard_order_update()      from public, anon, authenticated;

-- These three are required by the RLS policies that call them. A policy
-- expression runs with the privileges of the querying role, so authenticated
-- must keep EXECUTE or every policy using them fails closed and the app sees
-- an empty database. anon has no business calling them.
revoke execute on function public.current_user_role() from public, anon;
revoke execute on function public.is_manager()        from public, anon;
revoke execute on function public.is_owner()          from public, anon;

grant execute on function public.current_user_role() to authenticated;
grant execute on function public.is_manager()        to authenticated;
grant execute on function public.is_owner()          to authenticated;

comment on function public.is_manager() is
    'Used by RLS policies. Deliberately executable by authenticated; it only reports the caller''s own role.';
