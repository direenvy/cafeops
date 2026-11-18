using CafeOps.Infrastructure;
using CafeOps.Infrastructure.Database;
using Dapper;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;

namespace CafeOps.Tests;

/// <summary>
/// Tries to break the row-level security policies from the outside.
/// </summary>
/// <remarks>
/// <para>
/// <c>docs/ARCHITECTURE.md</c> claims the database itself refuses the writes
/// that move money or stock, and that this — not the API's own checks, and
/// certainly not the hidden tab in the UI — is the security boundary. Until
/// these tests existed, nothing verified that claim. A migration could have
/// dropped a policy and every other test would still have passed.
/// </para>
/// <para>
/// Each test impersonates a signed-in client the way PostgREST does: switch to
/// the <c>authenticated</c> role and set <c>request.jwt.claims</c>, which is
/// where <c>auth.uid()</c> reads the user id from. The policies then apply
/// exactly as they do to a real request from the Flutter app.
/// </para>
/// <para>
/// Everything runs inside a transaction that is always rolled back, including
/// the throwaway users, so the tests leave nothing behind. They no-op without
/// a connection string, which is the same compromise as the other database
/// tests and the reason Testcontainers is still worth doing.
/// </para>
/// </remarks>
public sealed class RowLevelSecurityTests
{
    /// <summary>Postgres raises this for both a missing grant and an RLS refusal.</summary>
    private const string InsufficientPrivilege = "42501";

    private static ServiceProvider? BuildProvider()
    {
        var configuration = new ConfigurationBuilder()
            .AddUserSecrets(typeof(Api.Controllers.HealthController).Assembly, optional: true)
            .AddEnvironmentVariables()
            .Build();

        if (string.IsNullOrWhiteSpace(configuration["Supabase:ConnectionString"]))
        {
            return null;
        }

        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCafeOpsInfrastructure(configuration);

        return services.BuildServiceProvider();
    }

    /// <summary>
    /// Opens a transaction, creates a user with the given role, and hands back
    /// a connection already acting as that signed-in client.
    /// </summary>
    /// <remarks>
    /// The privileged setup has to happen before the role switch, because
    /// afterwards the session has no more rights than a browser does.
    /// </remarks>
    private sealed class Client : IAsyncDisposable
    {
        private Client(
            ServiceProvider provider,
            NpgsqlConnection connection,
            NpgsqlTransaction transaction,
            Guid userId)
        {
            _provider = provider;
            Connection = connection;
            Transaction = transaction;
            UserId = userId;
        }

        private readonly ServiceProvider _provider;

        public NpgsqlConnection Connection { get; }

        public NpgsqlTransaction Transaction { get; }

        public Guid UserId { get; }

        public static async Task<Client?> SignInAsync(string role)
        {
            var provider = BuildProvider();

            if (provider is null)
            {
                return null;
            }

            var factory = provider.GetRequiredService<IDbConnectionFactory>();
            var connection = await factory.OpenAsync();
            var transaction = await connection.BeginTransactionAsync();

            var userId = Guid.NewGuid();

            // The on_auth_user_created trigger writes the profile for us, so
            // this exercises that too.
            await connection.ExecuteAsync(
                "insert into auth.users (id, email) values (@id, @email);",
                new { id = userId, email = $"rls-{userId:N}@example.test" },
                transaction);

            await connection.ExecuteAsync(
                "update public.profiles set role = @role::public.user_role where id = @id;",
                new { id = userId, role },
                transaction);

            // Become the client. set_config with is_local = true keeps both
            // settings inside this transaction.
            await connection.ExecuteAsync(
                "select set_config('request.jwt.claims', @claims, true);",
                new { claims = $"{{\"sub\":\"{userId}\",\"role\":\"authenticated\"}}" },
                transaction);

            await connection.ExecuteAsync("set local role authenticated;", transaction: transaction);

            return new Client(provider, connection, transaction, userId);
        }

        /// <summary>Runs SQL and returns the Postgres error, or null if it succeeded.</summary>
        public async Task<PostgresException?> TryAsync(string sql, object? parameters = null)
        {
            try
            {
                await Connection.ExecuteAsync(sql, parameters, Transaction);
                return null;
            }
            catch (PostgresException exception)
            {
                return exception;
            }
        }

        public Task<T> QueryAsync<T>(string sql, object? parameters = null) =>
            Connection.ExecuteScalarAsync<T>(sql, parameters, Transaction)!;

        /// <summary>Runs SQL and returns how many rows it actually affected.</summary>
        public Task<int> ExecuteAsync(string sql, object? parameters = null) =>
            Connection.ExecuteAsync(sql, parameters, Transaction);

        public async ValueTask DisposeAsync()
        {
            // Rollback, always: the throwaway user and anything a test managed
            // to write both disappear.
            await Transaction.RollbackAsync();
            await Transaction.DisposeAsync();
            await Connection.DisposeAsync();
            await _provider.DisposeAsync();
        }
    }

    private static void AssertRefused(PostgresException? error, string what)
    {
        Assert.True(error is not null, $"SECURITY: a client was allowed to {what}.");
        Assert.Equal(InsufficientPrivilege, error!.SqlState);
    }

    // ------------------------------------------------ what must be refused --

    [Fact]
    public async Task A_client_cannot_insert_an_order()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        // There is deliberately no INSERT policy on orders. This is the single
        // rule the whole architecture rests on: placing an order has to go
        // through the API, because only there is it one transaction.
        var error = await client.TryAsync(
            """
            insert into public.orders (table_label, subtotal, service_charge, tax, total)
            values ('HACK', 0, 0, 0, 0);
            """);

        AssertRefused(error, "insert an order directly");
    }

    [Fact]
    public async Task A_client_cannot_insert_an_order_line()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        var error = await client.TryAsync(
            """
            insert into public.order_items
                   (order_id, menu_item_id, name_snapshot, qty, unit_price, line_total)
            select o.id, m.id, 'Free coffee', 1, 0, 0
              from public.orders o, public.menu_items m
             limit 1;
            """);

        AssertRefused(error, "add a line to an order");
    }

    [Fact]
    public async Task A_client_cannot_write_the_stock_ledger()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        // Even a manager: the ledger is append-only from the API alone, so a
        // balance can never exist that no movement explains.
        var error = await client.TryAsync(
            """
            insert into public.stock_movements
                   (ingredient_id, delta, balance_after, reason)
            select id, 1000, stock_qty + 1000, 'delivery'::public.stock_reason
              from public.ingredients
             limit 1;
            """);

        AssertRefused(error, "write a stock movement");
    }

    [Fact]
    public async Task A_client_cannot_change_a_stock_balance()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        // A manager may edit an ingredient's name or reorder level, but
        // stock_qty is a derived balance and the guard trigger says so.
        var error = await client.TryAsync(
            "update public.ingredients set stock_qty = stock_qty + 9999;");

        AssertRefused(error, "inflate a stock balance");
    }

    [Fact]
    public async Task A_client_cannot_mark_an_order_paid()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        // Checkout belongs to the API so payment and stock settle together.
        var error = await client.TryAsync(
            """
            update public.orders
               set status = 'paid'::public.order_status, closed_at = now()
             where status not in ('paid'::public.order_status,
                                  'cancelled'::public.order_status);
            """);

        AssertRefused(error, "mark an order paid");
    }

    [Fact]
    public async Task A_client_cannot_rewrite_an_order_total()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        var error = await client.TryAsync("update public.orders set total = 0.01;");

        AssertRefused(error, "rewrite an order total");
    }

    [Fact]
    public async Task A_client_cannot_reprice_an_order_line()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        // Staff may advance a line's kitchen status; the guard trigger limits
        // them to exactly that column.
        var error = await client.TryAsync("update public.order_items set unit_price = 0;");

        AssertRefused(error, "re-price an order line");
    }

    [Fact]
    public async Task A_client_cannot_promote_themselves()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        // The most obvious attack on a role system, and the reason sign-up
        // never reads a role from client metadata.
        var error = await client.TryAsync(
            "update public.profiles set role = 'owner'::public.user_role where id = @id;",
            new { id = client.UserId });

        AssertRefused(error, "promote themselves to owner");
    }

    [Fact]
    public async Task A_client_cannot_read_the_order_number_counter()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        var error = await client.TryAsync("select * from public.order_counters;");

        AssertRefused(error, "read the order-number counter");
    }

    [Fact]
    public async Task Staff_cannot_see_the_stock_ledger()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        // Not an error: RLS filters rather than refuses, so this returns
        // nothing at all rather than failing. Worth pinning, because "no rows"
        // and "no policy" look identical from the application.
        var visible = await client.QueryAsync<long>(
            "select count(*) from public.stock_movements;");

        Assert.Equal(0, visible);
    }

    [Fact]
    public async Task Staff_cannot_add_a_menu_item()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        var error = await client.TryAsync(
            """
            insert into public.menu_items (category_id, name, price)
            select id, 'Staff special', 0 from public.menu_categories limit 1;
            """);

        AssertRefused(error, "add a menu item");
    }

    [Fact]
    public async Task A_manager_cannot_change_someone_elses_role()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        // Only an owner may do this. A manager who could promote peers could
        // promote themselves by proxy.
        //
        // Note what "refused" means here, because it is not an error. On an
        // UPDATE, RLS *filters* rather than rejecting: rows the policy does
        // not cover are simply not visible to the statement, so this succeeds
        // and changes nothing. An application checking only for an exception
        // would conclude it had worked.
        var ownersBefore = await client.QueryAsync<long>(
            "select count(*) from public.profiles where role = 'owner'::public.user_role;");

        var affected = await client.ExecuteAsync(
            """
            update public.profiles
               set role = 'owner'::public.user_role
             where id <> @id;
            """,
            new { id = client.UserId });

        Assert.Equal(0, affected);

        var ownersAfter = await client.QueryAsync<long>(
            "select count(*) from public.profiles where role = 'owner'::public.user_role;");

        Assert.Equal(ownersBefore, ownersAfter);
    }

    // ------------------------------------------------ what must still work --

    [Fact]
    public async Task Staff_can_read_the_menu()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        var items = await client.QueryAsync<long>("select count(*) from public.menu_items;");

        Assert.True(items > 0, "Staff must be able to read the menu to take an order.");
    }

    [Fact]
    public async Task Staff_can_read_the_board()
    {
        await using var client = await Client.SignInAsync("staff");
        if (client is null) return;

        // Reads are open on purpose: this is what the realtime subscription
        // rides on, and locking it down would break the board.
        var error = await client.TryAsync("select * from public.orders limit 1;");

        Assert.Null(error);
    }

    [Fact]
    public async Task Staff_can_advance_a_line_through_the_kitchen()
    {
        var provider = BuildProvider();
        if (provider is null) return;

        var factory = provider.GetRequiredService<IDbConnectionFactory>();

        await using var connection = await factory.OpenAsync();
        await using var transaction = await connection.BeginTransactionAsync();

        var userId = Guid.NewGuid();

        await connection.ExecuteAsync(
            "insert into auth.users (id, email) values (@id, @email);",
            new { id = userId, email = $"rls-{userId:N}@example.test" },
            transaction);

        // Seed an order as the server would, before dropping privileges.
        var lineId = await connection.ExecuteScalarAsync<Guid>(
            """
            with o as (
                insert into public.orders (table_label, subtotal, service_charge, tax, total)
                values ('RLS', 10, 1, 0.66, 11.66)
                returning id
            )
            insert into public.order_items
                   (order_id, menu_item_id, name_snapshot, qty, unit_price, line_total)
            select o.id, m.id, m.name, 1, m.price, m.price
              from o, public.menu_items m
             limit 1
            returning id;
            """,
            transaction: transaction);

        await connection.ExecuteAsync(
            "select set_config('request.jwt.claims', @claims, true);",
            new { claims = $"{{\"sub\":\"{userId}\",\"role\":\"authenticated\"}}" },
            transaction);

        await connection.ExecuteAsync("set local role authenticated;", transaction: transaction);

        var updated = await connection.ExecuteAsync(
            """
            update public.order_items
               set status = 'preparing'::public.order_item_status
             where id = @id;
            """,
            new { id = lineId },
            transaction);

        Assert.Equal(1, updated);

        await transaction.RollbackAsync();
        await provider.DisposeAsync();
    }

    [Fact]
    public async Task A_manager_can_read_the_stock_ledger()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        var error = await client.TryAsync("select * from public.stock_movements limit 1;");

        Assert.Null(error);
    }

    [Fact]
    public async Task A_manager_can_take_an_item_off_the_menu()
    {
        await using var client = await Client.SignInAsync("manager");
        if (client is null) return;

        var error = await client.TryAsync(
            "update public.menu_items set is_available = false;");

        Assert.Null(error);
    }

    [Fact]
    public async Task An_owner_can_change_a_role()
    {
        await using var client = await Client.SignInAsync("owner");
        if (client is null) return;

        var error = await client.TryAsync(
            """
            update public.profiles
               set role = 'manager'::public.user_role
             where id = @id;
            """,
            new { id = client.UserId });

        Assert.Null(error);
    }
}
