# Deploying

Two pieces: a static web build on GitHub Pages, and the API in a container.

Budget about forty minutes the first time. Nothing here needs a credit card or
an AWS account.

## The shape of it

```
https://direenvy.github.io/cafeops/     Flutter web, served by GitHub Pages
            │
            ├──────── reads + realtime ────────►  Supabase (already live)
            │
            └──────── writes ─────────────────►  https://<your-api>/api/...
                                                   container, Dockerfile in backend/
```

Both halves must be served over **HTTPS**. A browser refuses to let an HTTPS
page call an HTTP API, blocks it as mixed content, and reports it to the app as
an ordinary network failure — so a half-secure deployment fails in a way that
looks like the server being down. GitHub Pages is HTTPS automatically; pick an
API host that is too.

## 1. Deploy the API

Any host that builds a Dockerfile will do. Render is used below because it reads
the repository directly.

1. [render.com](https://render.com) → **New** → **Web Service**, and connect the
   `cafeops` repository.
2. Settings:

   | Field | Value |
   |---|---|
   | Root directory | `backend` |
   | Runtime | Docker |
   | Health check path | `/api/health` |
   | Region | Singapore, if offered — the database is in `ap-southeast-1` |

3. Environment variables. The double underscore is how .NET reads nested
   configuration from the environment; it is not a typo.

   | Key | Value |
   |---|---|
   | `Supabase__ProjectUrl` | `https://<your-ref>.supabase.co` |
   | `Supabase__ConnectionString` | the session-pooler string, in either form below |
   | `Cors__AllowedOrigins__0` | `https://direenvy.github.io` |

   The connection string is accepted either as Npgsql keyword form
   (`Host=…;Port=5432;Database=postgres;Username=…;Password=…`) or as the URI
   the dashboard shows (`postgresql://user:password@host:5432/postgres`). Both
   carry the same information, and Supabase offers both a few clicks apart, so
   the app converts rather than refusing one of them.

   The CORS value is the **origin only** — scheme and host, no path and no
   trailing slash. `https://direenvy.github.io/cafeops/` will not match, and the
   failure looks exactly like the API being unreachable.

4. Deploy, then confirm:

   ```bash
   curl https://<your-api>.onrender.com/api/health/ready
   ```

   `{"status":"ready","database":"up"}` means the container is up and the
   database credential survived the trip.

**On free tiers:** most spin a container down after a few minutes idle, and the
next request pays a cold start of up to a minute. For a link a recruiter opens
once, that reads as broken. Check the current plan before relying on it; a few
dollars a month for an instance that stays awake is usually the right trade for
a demo.

## 2. Turn on GitHub Pages

Repository → **Settings** → **Pages** → **Source: GitHub Actions**.

That is all — `.github/workflows/deploy-web.yml` does the rest.

## 3. Point the app at the API

Repository → **Settings** → **Secrets and variables** → **Actions** →
**Variables** → **New repository variable**:

| Name | Value |
|---|---|
| `API_BASE_URL` | `https://<your-api>.onrender.com` |

A variable, not a secret: it is a public URL, and the build has to be able to
read it back. `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` can be set the same
way, but both already default to this project's own instance, so leave them
unless you are pointing a fork elsewhere.

Without `API_BASE_URL` the build still succeeds and warns: the app will sign in
and read fine, because that goes straight to Supabase, and only writes will
fail. That is a genuinely confusing half-working state, so set it.

## 4. Build and publish

Actions → **Deploy web** → **Run workflow**. Or push anything to `main`; it runs
on every push, so the demo never drifts from the code.

The site appears at `https://direenvy.github.io/cafeops/`.

## 5. Check it end to end

1. Open the Pages URL and sign in.
2. Place an order. If it goes through, every layer is talking to every other
   layer.
3. If it fails with "cannot reach the API", open the browser console. A CORS
   complaint means step 1's `Cors__AllowedOrigins__0` does not match the Pages
   origin exactly.

## Afterwards

Put the live link at the top of the README, next to the repository link. It is
the first thing a reader wants and the one thing a README cannot show them.

If you re-enable email confirmation in Supabase, set **Authentication → URL
Configuration → Site URL** to the Pages URL as well, or the confirmation links
in those emails will point at `localhost`.

## Moving to AWS later

The Dockerfile is the portable part, and it is what makes this a config change
rather than a rewrite.

Elastic Beanstalk, single-instance, takes the same image. Two things to plan
for: choose **single-instance** rather than load-balanced, because the load
balancer is roughly $17/month and would be distributing traffic across exactly
one server; and a single-instance environment serves plain HTTP, so it needs
CloudFront in front of it to give the API a certificate — otherwise the mixed
content rule at the top of this page blocks every call from the Pages site.
