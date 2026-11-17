namespace CafeOps.Domain.Orders;

/// <summary>One line as the client asks for it. Note there is no price here.</summary>
/// <remarks>
/// The client sends what it wants and how many, never what it costs. Accepting a
/// price from the client is the classic way a till gets robbed; the server looks
/// every price up itself.
/// </remarks>
public sealed record OrderLineRequest(Guid MenuItemId, int Qty, string? Note = null);

/// <summary>A whole order as the client asks for it.</summary>
public sealed record NewOrderRequest(
    string TableLabel,
    IReadOnlyList<OrderLineRequest> Lines,
    string? Note = null);

/// <summary>A line after the server has priced it.</summary>
public sealed record PricedLine(
    Guid MenuItemId,
    string NameSnapshot,
    int Qty,
    decimal UnitPrice,
    decimal LineTotal,
    string? Note);

/// <summary>The money on an order, each component rounded to cents.</summary>
public sealed record OrderTotals(
    decimal Subtotal,
    decimal ServiceCharge,
    decimal Tax,
    decimal Total)
{
    public static OrderTotals Zero { get; } = new(0m, 0m, 0m, 0m);
}

/// <summary>A validated, priced order, ready to be written in one transaction.</summary>
public sealed record PricedOrder(
    string TableLabel,
    string? Note,
    IReadOnlyList<PricedLine> Lines,
    OrderTotals Totals);
