-- Last function left reachable over RPC. Harmless in itself (it only reports
-- whether the current statement carries a user JWT) but there is no reason for
-- a client to be able to ask, so it is closed for consistency.

revoke execute on function public.is_trusted_server() from public, anon, authenticated;

comment on function public.is_trusted_server() is
    'True when a statement arrives without an end-user JWT, i.e. from the API service connection or a migration. Used by the guard triggers; not callable by clients.';
