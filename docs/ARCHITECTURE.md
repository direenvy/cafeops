# Architectural decisions

The reasoning behind the choices in this project, including the ones that could
reasonably have gone the other way.

---

## 1. Why both Supabase and a C# API

**Decision.** Reads and realtime go from Flutter straight to Supabase under
row-level security. Writes that move money or stock go through ASP.NET Core,
which connects as a role that bypasses RLS.

**The alternatives, and why not.**

*Everything through the C# API.* Clean to explain, and it throws away the main
reason to use Supabase. The order board would have to poll, or the API would
have to hold its own websocket fan-out, and auth, session refresh and token
rotation would all have to be rebuilt. A lot of work to end up with less.

*Only Supabase, with Edge Functions.* Also viable, and it would have left the
pricing and stock arithmetic either in the client — where it cannot be trusted —
or in TypeScript functions that lose the transaction boundary that makes the
whole thing correct.

**Why the split is the right one.** The question to ask of any write is "what
happens if the client lies, or disconnects halfway?" For "mark this latte as
ready", nothing much: it is one column, and a guard trigger stops a client
touching anything else. For "place this order", everything: prices could be
forged, stock could go negative, a balance could end up with no ledger row
explaining it. The first belongs on the fast path. The second does not.

**What it costs.** Two deployables, two auth paths to keep in step, and two JSON
conventions meeting in the client (PostgREST's snake_case and the API's
camelCase). The models say which convention each constructor expects, and the
parsing is tested, because that boundary is exactly where a silent zero would
appear on screen.

---

## 2. Order placement is one transaction

**Decision.** `OrderService.PlaceOrderAsync` does all of this inside a single
transaction: load prices, price the order, load recipes, lock the affected
ingredient rows `FOR UPDATE` ordered by id, check for shortages, insert the
order, insert its lines, decrement the balances, and append a `sale` ledger row
per ingredient.

**Why the lock.** Without it, checking stock and decrementing it are two
decisions, and two tills can both pass the check and both sell the last of
something. The lock makes them one decision.

**Why ordered by id.** Two concurrent orders sharing ingredients would otherwise
be able to take the same locks in opposite orders and deadlock. A consistent
order removes that. `StockMath.RequirementsFor` returns its requirements sorted
for this reason, and there is a test that holds it to it.

**Why the balance and the ledger row are written by one statement.** The
`UPDATE … RETURNING` feeds the `INSERT`, so `balance_after` is the balance the
update actually produced. Two statements could drift, and then the ledger no
longer explains the balance, which is the one thing the ledger is for.

---

## 3. Prices are never accepted from the client

**Decision.** `NewOrderRequest` has no price field anywhere in it. The server
looks every price up itself.

A till that sends prices is a till that can be told to sell at any price. The
order lines also *store* the price at the moment of sale rather than referencing
the menu, because re-reading `menu_items.price` later would silently rewrite the
history of every past receipt the next time someone raises a price. The item
name is snapshotted for the same reason.

---

## 4. Roles live in the database, not in the token

**Decision.** The JWT proves identity. The role is read from
`public.profiles` on each authorized request, cached in-process for 30 seconds.

A role baked into a token cannot be taken away until the token expires, which is
the wrong behaviour for "remove this person's access now". The cost is a lookup
per request, which the cache makes negligible.

The cache is in-process, which is honest about the deployment this is built for.
More than one API instance would want a shared cache or a shorter window — and
of those two, the shorter window is probably the better answer.

**Also.** Sign-up never reads a role from client metadata. Everyone starts as
staff, and the first owner is promoted by hand (see SETUP.md). A self-service
form that accepted a role would let anyone register as an owner.

---

## 5. Security is enforced twice, deliberately

RLS policies decide what the client role can do. The API checks roles again in
its authorization policies. The Flutter app hides the Reports tab from staff.

Only the first of those is a security boundary. The second is defence in depth
for the path that bypasses RLS by design. The third is a courtesy, so nobody
taps a tab to be told no — and `HomeShell` says so in a comment, because a
reader should not have to guess which layer is load-bearing.

What RLS cannot express is column-level intent: "a client may update
`order_items.status` and nothing else". That is what the guard triggers in
`20261117000004_rls_policies.sql` are for. They also distinguish a client from
the API by whether the statement carries a user JWT — `auth.uid() is null` is
true for the API's connection and for migrations, and never for a client.

---

## 6. SQL migrations, not ORM migrations

**Decision.** The schema is hand-written SQL in `supabase/migrations/`. EF Core
is not used; the data layer is Npgsql with Dapper.

Row-level security policies, guard triggers, `security_invoker` views, partial
indexes and Postgres enums are the substance of this schema, and none of them
expresses well through an ORM's model-first migrations. Since the database
genuinely owns the rules here, the schema is written in the database's own
language.

Dapper over raw Npgsql because the mapping boilerplate is pure cost; Dapper over
EF Core because the valuable queries are things like "one statement that
decrements balances and writes the matching ledger rows", which is clearer as
SQL than as anything generating it.

**What it costs.** No compile-time checking of queries, and column aliases have
to match the record constructors. The aliases are explicit in every query rather
than relying on a naming convention, so a rename fails loudly.

---

## 7. The domain layer has no I/O

**Decision.** `CafeOps.Domain` references nothing but the base library. Pricing,
order validation and stock arithmetic are pure functions over plain records.
Interfaces for persistence are declared there and implemented in
`CafeOps.Infrastructure`.

This is why 59 tests run in 60 milliseconds with no database, no containers and
no secrets in CI. It is also why the rules that matter — tax on the subtotal
plus service charge, away-from-zero rounding, requirements aggregated across
lines — can be tested exhaustively instead of sampled through a stack.

Expected failures are return values, not exceptions. `Result<T>` with a
`DomainError` carrying a stable code (`stock.insufficient`) maps to HTTP at the
edge and lets the Flutter client branch on the code rather than on English text.
Exceptions stay for genuine faults, so the logs mean something.

---

## 8. Tokens are validated against JWKS, not a shared secret

**Decision.** The API points `JwtBearer` at the project's OIDC authority and
validates signatures against its published key set.

This was checked against the live project rather than assumed, and the check
mattered: the project signs access tokens with **ES256**, so the older symmetric
"JWT secret" approach found in most tutorials would have rejected every real
token. Validating against JWKS also means the API holds no shared secret and
picks up a key rotation on its own.

---

## 9. The board re-reads instead of patching

**Decision.** On a Postgres change event the client re-reads the whole board,
debounced by 150ms, rather than applying the change to the row in memory.

A cafe has tens of open orders, not thousands. Re-reading cannot drift out of
sync with the database the way incremental patching can, and the debounce
collapses the burst that one order produces — the order row, then each of its
lines — into a single fetch.

This is the decision most likely to need revisiting first. At a scale where it
hurts, the fix is to patch the changed row and keep the re-read as a periodic
reconciliation.

---

## 10. Hand-written models and a hand-drawn chart

Two places where a dependency was considered and declined.

**JSON parsing.** `json_serializable` would add a build step and a watch process
to save less code than it costs at this size. The parsing is also where the two
naming conventions and Postgres's `numeric`-as-a-string have to be handled
explicitly, which is clearer written out than configured.

**The revenue chart.** One series of at most thirty bars, drawn with layout
widgets. A charting package would be more code to configure than to write, and
the bars stay on the app's own colour scheme in both light and dark for free.

Neither would be the right call for a dozen models with deep nesting, or for
real interactive charting.

---

## 11. Following the linter rather than arguing with it

Two cases where a tool was right and the code changed.

The Supabase database linter found functions with a mutable `search_path` and
`SECURITY DEFINER` functions reachable as RPC endpoints. Both were real. The fix
is `20261117000006`, and `20261117000007` exists because the first fix looked
correct and the linter still reported the problem: revoking `EXECUTE` from
`anon` and `authenticated` does nothing while the implicit grant to `PUBLIC`
remains. The two migrations are kept separate rather than squashed, because the
sequence is the useful part.

One finding is left standing on purpose. `order_counters` has RLS enabled with
no policy, which the linter reports as INFO. That is the intent — no policy
means no client can touch it — and the table carries a comment saying so.

Flutter's analyzer reported that `package:flutter/material.dart` is deprecated
in 3.50 in favour of `package:material_ui/material_ui.dart`. The imports were
migrated rather than suppressed. CI runs `flutter analyze --fatal-infos
--fatal-warnings`, so the repository stays at zero and any new warning belongs
to the change that introduced it.

---

## What I would do next

In the order I would actually do it:

1. **Integration tests against a real Postgres** with Testcontainers. The domain
   layer is covered thoroughly and the SQL is not, which is the real gap. The
   transactions, the RLS policies and the guard triggers all deserve tests that
   exercise them for real.
2. **A payment provider**, so taking money is a payment rather than a state
   change.
3. **Shift reporting** — takings per person per shift, which is the first thing
   an owner asks for after daily totals.
4. **Offline-tolerant ordering.** A cafe's wifi drops. Queueing orders locally
   and reconciling needs idempotency keys on the place-order endpoint, which is
   a real piece of design rather than a tweak.
