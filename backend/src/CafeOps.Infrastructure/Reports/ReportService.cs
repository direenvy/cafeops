using CafeOps.Domain.Abstractions;
using CafeOps.Infrastructure.Database;
using Dapper;

namespace CafeOps.Infrastructure.Reports;

/// <summary>
/// Read-only sales reporting, aggregated in Postgres rather than in C#.
/// </summary>
/// <remarks>
/// The grouping and summing happen in SQL because the database can do it over
/// an index without sending every order row across the network. Pulling the
/// rows back and using LINQ would work on seed data and fall over on a year of
/// trading.
/// </remarks>
public sealed class ReportService(IDbConnectionFactory connectionFactory) : IReportService
{
    /// <summary>A report may not span more than this many days.</summary>
    public const int MaxRangeDays = 366;

    public async Task<SalesSummary> GetSalesSummaryAsync(
        DateOnly from,
        DateOnly to,
        CancellationToken cancellationToken = default)
    {
        if (to < from)
        {
            (from, to) = (to, from);
        }

        if (to.DayNumber - from.DayNumber > MaxRangeDays)
        {
            throw new ArgumentOutOfRangeException(
                nameof(to),
                $"A sales report may span at most {MaxRangeDays} days.");
        }

        await using var connection = await connectionFactory.OpenAsync(cancellationToken);

        var byDay = (await connection.QueryAsync<DailySales>(new CommandDefinition(
                Sql.ByDay,
                new { from, to },
                cancellationToken: cancellationToken)))
            .ToArray();

        var topItems = (await connection.QueryAsync<ItemSales>(new CommandDefinition(
                Sql.TopItems,
                new { from, to },
                cancellationToken: cancellationToken)))
            .ToArray();

        var ordersPaid = byDay.Sum(day => day.OrdersPaid);
        var revenue = byDay.Sum(day => day.Total);

        return new SalesSummary(
            From: from,
            To: to,
            OrdersPaid: ordersPaid,
            Revenue: revenue,
            // Guarded rather than assumed: a range with no sales is a perfectly
            // normal answer, not a divide-by-zero.
            AverageOrderValue: ordersPaid == 0 ? 0m : Domain.Money.Round(revenue / ordersPaid),
            ByDay: byDay,
            TopItems: topItems);
    }

    private static class Sql
    {
        public const string ByDay = """
            select business_day        as businessday,
                   -- count(*) in the view is a bigint; DailySales.OrdersPaid
                   -- is an int, and Dapper will not narrow it for us.
                   orders_paid::int    as orderspaid,
                   subtotal,
                   service_charge      as servicecharge,
                   tax,
                   total,
                   average_order_value as averageordervalue
              from public.v_daily_sales
             where business_day between @from and @to
             order by business_day;
            """;

        // Joins through to the category so the report reads the way a manager
        // thinks ("Espresso is 60% of revenue"), and uses the price captured on
        // the line rather than the current menu price.
        public const string TopItems = """
            select oi.menu_item_id as menuitemid,
                   oi.name_snapshot as name,
                   coalesce(c.name, 'Uncategorised') as categoryname,
                   sum(oi.qty)::int as unitssold,
                   sum(oi.line_total) as revenue
              from public.order_items oi
              join public.orders o on o.id = oi.order_id
              left join public.menu_items m on m.id = oi.menu_item_id
              left join public.menu_categories c on c.id = m.category_id
             where o.status = 'paid'::public.order_status
               and oi.status <> 'cancelled'::public.order_item_status
               and (o.closed_at at time zone 'Asia/Kuala_Lumpur')::date between @from and @to
             group by oi.menu_item_id, oi.name_snapshot, c.name
             order by sum(oi.line_total) desc, sum(oi.qty) desc
             limit 10;
            """;
    }
}
