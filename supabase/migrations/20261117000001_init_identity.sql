-- Identity, roles, and the profile mirror of auth.users.
-- Design note: role is NEVER taken from signup metadata. A self-service client
-- could otherwise register itself as 'owner'. Everyone starts as 'staff' and is
-- promoted by an owner (see 20261117000004_rls_policies.sql).

create type public.user_role as enum ('owner', 'manager', 'staff');

create table public.profiles (
    id          uuid primary key references auth.users (id) on delete cascade,
    full_name   text        not null check (length(trim(full_name)) between 1 and 120),
    role        public.user_role not null default 'staff',
    is_active   boolean     not null default true,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.profiles is
    'Application-facing user record. Mirrors auth.users so the app can join on identity without granting access to the auth schema.';

-- Keep updated_at honest without trusting the client to send it.
create function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger profiles_touch_updated_at
    before update on public.profiles
    for each row execute function public.touch_updated_at();

-- Every new auth user gets a profile automatically, so the app never has to
-- cope with a signed-in user that has no profile row.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, full_name)
    values (
        new.id,
        coalesce(
            nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
            split_part(new.email, '@', 1)
        )
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- Role helpers. SECURITY DEFINER with a pinned search_path so that RLS policies
-- on public.profiles can call them without recursing into their own policy.
create function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
    select role from public.profiles where id = auth.uid() and is_active;
$$;

create function public.is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(public.current_user_role() in ('owner', 'manager'), false);
$$;

create function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(public.current_user_role() = 'owner', false);
$$;

revoke execute on function public.handle_new_user() from public;
revoke execute on function public.touch_updated_at() from public;
