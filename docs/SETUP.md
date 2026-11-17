# Setup

From a fresh clone to a running app.

## What you need

- .NET SDK 10
- Flutter 3.50 or newer
- A Supabase project

Check the first two:

```bash
dotnet --version && flutter --version
```

## 1. The database

The schema lives in `supabase/migrations/`, numbered in the order it must be
applied. Those files are the source of truth — not the live database, and not
any ORM's model.

### If the project is already provisioned

Nothing to do; skip to step 2.

### From scratch

Create a project at [supabase.com](https://supabase.com), then apply each
migration in filename order. Either paste them into the dashboard's SQL editor
one at a time, or use the CLI:

```bash
supabase link --project-ref <your-project-ref> && supabase db push
```

Then load the demo data, which is idempotent and safe to re-run:

```bash
supabase db execute --file supabase/seed.sql
```

The seed deliberately leaves two ingredients below their reorder level, so the
low-stock screen has something to show the first time you open it.

## 2. The API's credentials

The API needs two values. Neither is committed, and the API refuses to start
without them rather than failing later on the first request.

**Project URL** — in the dashboard under *Project Settings → API*. It looks like
`https://abcdefghijklmnop.supabase.co`.

**Postgres connection string** — in the dashboard under *Project Settings →
Database → Connection string → .NET*, using the **session pooler**. It contains
your database password. If you have never set that password, or do not have it,
use *Reset database password* on the same page and take the new one.

> This is the one step nobody else can do for you, and the reason is the point:
> that connection string is the credential that lets the API bypass row-level
> security. It belongs to you, it never goes in the repository, and anything
> holding it can write anything.

Store both with user-secrets, which keeps them outside the project directory:

```bash
cd backend/src/CafeOps.Api
```

```bash
dotnet user-secrets init
```

```bash
dotnet user-secrets set "Supabase:ProjectUrl" "https://<your-ref>.supabase.co"
```

```bash
dotnet user-secrets set "Supabase:ConnectionString" "Host=aws-0-<region>.pooler.supabase.com;Port=5432;Database=postgres;Username=postgres.<your-ref>;Password=<your-password>;SSL Mode=Require;Trust Server Certificate=true"
```

In production, set the same two keys as environment variables instead:
`Supabase__ProjectUrl` and `Supabase__ConnectionString`.

## 3. Run the API

```bash
dotnet run --project backend/src/CafeOps.Api
```

It listens on `http://localhost:5081`. Check it:

```bash
curl http://localhost:5081/api/health/ready
```

`{"status":"ready","database":"up"}` means the connection string works. A 503
means it does not.

## 4. Run the app

The Supabase URL and publishable key are compiled in as defaults, so for the
project this repository was built against:

```bash
cd app && flutter run -d chrome
```

Pointing it elsewhere, or at a deployed API:

```bash
flutter run -d chrome \
  --dart-define=SUPABASE_URL=https://<your-ref>.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_... \
  --dart-define=API_BASE_URL=https://your-api.example.com
```

The publishable key is meant to be shipped in a client — it identifies the
project and authorises nothing. What a client can actually reach is decided by
the policies in `20261117000004_rls_policies.sql`.

## 5. Your first accounts

Sign up in the app. **New accounts are always created as staff**: the role is
never read from anything the client sends, so a sign-up form cannot make itself
a manager.

Two things to know:

**Email confirmation is on by default.** Sign-up will return "check your email"
rather than signing you straight in. For a demo, turn it off under
*Authentication → Sign In / Providers → Email → Confirm email*, and sign up
again.

**Promote yourself to owner.** There is no first-run bootstrap; the first owner
is made by hand, on purpose. Run this in the SQL editor after signing up:

```sql
update public.profiles
   set role = 'owner'
 where id = (select id from auth.users where email = 'you@example.com');
```

Sign out and back in. You should now see the Reports tab.

For a realistic demo, make a second account and leave it as staff — then you can
see the role gate working, and watch an order placed on one appear live on the
other.

## 6. See it work

1. Sign in as the owner. **New order** → pick a few items → type a table → send.
2. Switch to **Board**. The ticket is there. Tap its lines to advance them.
3. Open the app in a second browser window signed in as the staff account. Place
   an order in one and watch it appear in the other without a refresh.
4. Go to **Stock**. The ingredients that order consumed have gone down. Open one
   and read its ledger — there is a `sale` row explaining the change.
5. Back on the board, **Pay** an order, then check **Reports**.
6. Try to break it: order 99 of something that needs milk. The API refuses with
   exactly what is short, and nothing is written.

## Running the tests

Neither suite needs a database or any configuration.

```bash
dotnet test backend/CafeOps.slnx
```

```bash
cd app && flutter test
```

## Deploying

**API** — any container host. It expects TLS to be terminated by the platform's
proxy, so it does no HTTPS redirection of its own. Set
`Supabase__ProjectUrl`, `Supabase__ConnectionString`, and
`Cors__AllowedOrigins__0` to wherever the web app is served from. Without that
last one the browser will block every request, since the CORS policy allows
nothing by default rather than everything.

**App** — `flutter build web --release` produces `app/build/web`, which is static
files. Build it with the `--dart-define` flags pointing at the deployed API.

## If something is wrong

**"Supabase configuration is missing"** — step 2 did not take. Run
`dotnet user-secrets list` in `backend/src/CafeOps.Api`.

**`/api/health/ready` returns 503** — the connection string is wrong, or the
password is stale. Reset it and set it again.

**The app shows "Cannot reach the API"** — the API is not running, or
`API_BASE_URL` points somewhere else. The error on screen names the URL it
tried.

**Signed in, but every screen is empty** — the profile row is missing or
`is_active` is false. Check `select * from public.profiles`.

**"Your account has no profile row yet"** — the account was created before the
`on_auth_user_created` trigger existed. Insert the row by hand, or delete the
user and sign up again.

**No Reports tab** — that account is still staff. Re-read step 5, and remember
to sign out and back in.

**The board does not update live** — realtime is per-table. Confirm
`20261117000005_views_and_realtime.sql` was applied; it is what adds `orders`
and `order_items` to the publication.
