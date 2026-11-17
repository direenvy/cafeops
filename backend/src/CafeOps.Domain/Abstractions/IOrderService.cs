using CafeOps.Domain.Orders;
using CafeOps.Domain.Stock;

namespace CafeOps.Domain.Abstractions;

/// <summary>An order as it exists once it has been written.</summary>
public sealed record PlacedOrder(
    Guid Id,
    string OrderNumber,
    string TableLabel,
    OrderStatus Status,
    OrderTotals Totals,
    IReadOnlyList<PricedLine> Lines,
    DateTimeOffset CreatedAt);

/// <summary>What a paid order produced.</summary>
public sealed record Receipt(
    Guid OrderId,
    string OrderNumber,
    string TableLabel,
    OrderTotals Totals,
    IReadOnlyList<PricedLine> Lines,
    DateTimeOffset PaidAt,
    string ServedBy);

/// <summary>
/// Carries the shortages back to the edge so the till can list everything that
/// is missing, rather than just saying "out of stock".
/// </summary>
public sealed record InsufficientStock(IReadOnlyList<StockShortage> Shortages)
{
    public string Describe() => string.Join("; ", Shortages.Select(s => s.ToString()));
}

/// <summary>
/// Operations that move money or stock.
/// </summary>
/// <remarks>
/// These are the operations the database refuses to accept from a client
/// directly (see <c>20261117000004_rls_policies.sql</c>). Each one is a single
/// transaction: an order that cannot be stocked is not written at all, and a
/// stock balance never drifts from the ledger that explains it.
/// </remarks>
public interface IOrderService
{
    /// <summary>
    /// Validates, prices, stock-checks and writes an order in one transaction.
    /// </summary>
    Task<Result<PlacedOrder>> PlaceOrderAsync(
        NewOrderRequest request,
        Guid actorId,
        CancellationToken cancellationToken = default);

    /// <summary>Settles an order as paid and closes it.</summary>
    Task<Result<Receipt>> CheckoutAsync(
        Guid orderId,
        Guid actorId,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Cancels an order and returns its ingredients to the stock room.
    /// </summary>
    Task<Result<PlacedOrder>> CancelAsync(
        Guid orderId,
        string reason,
        Guid actorId,
        CancellationToken cancellationToken = default);
}
