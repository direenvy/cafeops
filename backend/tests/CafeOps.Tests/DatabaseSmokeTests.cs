using CafeOps.Domain;
using CafeOps.Domain.Abstractions;
using CafeOps.Domain.Orders;
using CafeOps.Infrastructure;
using CafeOps.Infrastructure.Database;
using Dapper;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace CafeOps.Tests;

/// <summary>
/// Runs every query against a real database.
/// </summary>
/// <remarks>
/// <para>
/// These exist because of a failure the rest of the suite could not have
/// caught. Npgsql materialises a Postgres <c>timestamptz</c> as a
/// <see cref="DateTime"/>, but the row records declared
/// <see cref="DateTimeOffset"/>, so Dapper could not find a constructor to
/// match. Everything compiled, 67 tests passed, and the very first real order
/// returned a 500.
/// </para>
/// <para>
/// A column-to-record mismatch is only observable against a live database, so
/// no amount of unit testing would have found it. What these do is exercise
/// each query once and assert that what came back could be materialised.
/// </para>
/// <para>
/// They no-op when no connection string is configured, which is how CI stays
/// free of secrets and service containers. Locally they pick up the same
/// user-secrets the API uses, so they run on a developer machine without any
/// extra setup. The eventual answer is Testcontainers, so that CI gets a
/// disposable Postgres of its own and these stop being conditional.
/// </para>
/// </remarks>
public sealed class DatabaseSmokeTests
{
    private static ServiceProvider? BuildProvider()
    {
        var configuration = new ConfigurationBuilder()
            // Reads the API project's user-secrets store, so the credential
            // lives in exactly one place and never in the repository.
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
    /// Finds a profile to act as, rather than hardcoding an id that only
    /// exists in one database.
    /// </summary>
    private static async Task<Guid?> AnyProfileIdAsync(IServiceProvider provider)
    {
        var factory = provider.GetRequiredService<IDbConnectionFactory>();
        await using var connection = await factory.OpenAsync();

        return await connection.QuerySingleOrDefaultAsync<Guid?>(
            "select id from public.profiles order by created_at limit 1;");
    }

    [Fact]
    public async Task Reads_materialise_against_a_real_database()
    {
        await using var provider = BuildProvider();

        if (provider is null)
        {
            return; // No connection string configured; nothing to check.
        }

        var stock = provider.GetRequiredService<IStockService>();
        var reports = provider.GetRequiredService<IReportService>();

        // Each of these goes through a different row shape, and any one of them
        // throwing means a column does not line up with its record.
        var lowStock = await stock.GetLowStockAsync();
        Assert.NotNull(lowStock);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        // Exercises v_daily_sales, whose count(*) is a bigint that has to be
        // narrowed to an int in SQL, and the top-items query.
        var sales = await reports.GetSalesSummaryAsync(today.AddDays(-30), today);
        Assert.NotNull(sales);
        Assert.True(sales.Revenue >= 0);

        if (lowStock.Count > 0)
        {
            var history = await stock.GetHistoryAsync(lowStock[0].Id, limit: 5);
            Assert.NotNull(history);
        }
    }

    [Fact]
    public async Task A_profile_can_be_read_back()
    {
        await using var provider = BuildProvider();

        if (provider is null)
        {
            return;
        }

        var profileId = await AnyProfileIdAsync(provider);

        if (profileId is null)
        {
            return; // Nobody has signed up yet.
        }

        var directory = provider.GetRequiredService<IUserDirectory>();
        var profile = await directory.GetProfileAsync(profileId.Value);

        Assert.NotNull(profile);
        Assert.False(string.IsNullOrWhiteSpace(profile.FullName));
    }

    [Fact]
    public async Task An_order_can_be_placed_and_cancelled_without_drifting_stock()
    {
        await using var provider = BuildProvider();

        if (provider is null)
        {
            return;
        }

        var profileId = await AnyProfileIdAsync(provider);

        if (profileId is null)
        {
            return;
        }

        var factory = provider.GetRequiredService<IDbConnectionFactory>();
        var orders = provider.GetRequiredService<IOrderService>();

        await using var connection = await factory.OpenAsync();

        // Pick a real item that actually consumes stock, so the sale moves a
        // balance and the ledger has something to reverse.
        var menuItemId = await connection.QuerySingleOrDefaultAsync<Guid?>(
            """
            select m.id
              from public.menu_items m
              join public.recipe_items r on r.menu_item_id = m.id
             where m.is_available
             group by m.id
             order by m.name
             limit 1;
            """);

        if (menuItemId is null)
        {
            return; // Menu not seeded.
        }

        const string BalancesSql =
            """
            select coalesce(sum(stock_qty), 0) from public.ingredients;
            """;

        var before = await connection.ExecuteScalarAsync<decimal>(BalancesSql);

        var placed = await orders.PlaceOrderAsync(
            new NewOrderRequest("SMOKE", [new OrderLineRequest(menuItemId.Value, 1)]),
            profileId.Value);

        Assert.True(
            placed.IsSuccess,
            $"Placing the order failed: {placed.Error?.Code} {placed.Error?.Message}");

        // The materialisation that used to throw.
        Assert.False(string.IsNullOrWhiteSpace(placed.Value.OrderNumber));
        Assert.Equal(OrderStatus.Open, placed.Value.Status);
        Assert.True(placed.Value.Totals.Total > 0);
        Assert.NotEqual(default, placed.Value.CreatedAt);

        var during = await connection.ExecuteScalarAsync<decimal>(BalancesSql);
        Assert.True(during < before, "Placing the order should have consumed stock.");

        var cancelled = await orders.CancelAsync(
            placed.Value.Id,
            "automated smoke test",
            profileId.Value);

        Assert.True(
            cancelled.IsSuccess,
            $"Cancelling failed: {cancelled.Error?.Code} {cancelled.Error?.Message}");

        // The point of reversing from the ledger rather than recomputing from
        // the recipes: what went out comes back exactly.
        var after = await connection.ExecuteScalarAsync<decimal>(BalancesSql);
        Assert.Equal(before, after);
    }

    [Fact]
    public async Task An_order_that_cannot_be_stocked_is_refused_and_writes_nothing()
    {
        await using var provider = BuildProvider();

        if (provider is null)
        {
            return;
        }

        var profileId = await AnyProfileIdAsync(provider);

        if (profileId is null)
        {
            return;
        }

        var factory = provider.GetRequiredService<IDbConnectionFactory>();
        var orders = provider.GetRequiredService<IOrderService>();

        await using var connection = await factory.OpenAsync();

        var menuItemId = await connection.QuerySingleOrDefaultAsync<Guid?>(
            """
            select m.id
              from public.menu_items m
              join public.recipe_items r on r.menu_item_id = m.id
             where m.is_available
             group by m.id
             limit 1;
            """);

        if (menuItemId is null)
        {
            return;
        }

        const string CountsSql =
            """
            select count(*) from public.orders;
            """;

        var ordersBefore = await connection.ExecuteScalarAsync<long>(CountsSql);

        // Far more than any cafe has on hand.
        var result = await orders.PlaceOrderAsync(
            new NewOrderRequest("SMOKE", [new OrderLineRequest(menuItemId.Value, 99)]),
            profileId.Value);

        Assert.False(result.IsSuccess);
        Assert.Equal("stock.insufficient", result.Error!.Code);
        Assert.Equal(ErrorKind.Conflict, result.Error.Kind);

        // The whole point of the transaction: a refused order leaves no trace,
        // not even the order header or a consumed order number.
        var ordersAfter = await connection.ExecuteScalarAsync<long>(CountsSql);
        Assert.Equal(ordersBefore, ordersAfter);
    }
}
