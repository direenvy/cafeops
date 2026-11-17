namespace CafeOps.Domain.Abstractions;

/// <summary>Takings for one business day.</summary>
public sealed record DailySales(
    DateOnly BusinessDay,
    int OrdersPaid,
    decimal Subtotal,
    decimal ServiceCharge,
    decimal Tax,
    decimal Total,
    decimal AverageOrderValue);

/// <summary>How much of one item sold over a period.</summary>
public sealed record ItemSales(
    Guid MenuItemId,
    string Name,
    string CategoryName,
    int UnitsSold,
    decimal Revenue);

/// <summary>Headline numbers for a period, plus its best sellers.</summary>
public sealed record SalesSummary(
    DateOnly From,
    DateOnly To,
    int OrdersPaid,
    decimal Revenue,
    decimal AverageOrderValue,
    IReadOnlyList<DailySales> ByDay,
    IReadOnlyList<ItemSales> TopItems);

/// <summary>
/// Read-only reporting. Kept behind the API rather than exposed to the client
/// because these aggregate across every user's orders, which no single staff
/// member's RLS view should be able to do.
/// </summary>
public interface IReportService
{
    Task<SalesSummary> GetSalesSummaryAsync(
        DateOnly from,
        DateOnly to,
        CancellationToken cancellationToken = default);
}
