using CafeOps.Domain.Catalog;

namespace CafeOps.Domain.Orders;

/// <summary>
/// Turns a client request into a priced order, or an explanation of why not.
/// </summary>
/// <remarks>
/// Pure: hand it a request and the catalogue it should price against, and it
/// returns an answer. No database, no clock, no HTTP context, which is why the
/// pricing and validation rules can be unit-tested exhaustively.
/// </remarks>
public sealed class OrderPricer(PricingPolicy policy)
{
    /// <summary>A single order may not exceed this many of one item.</summary>
    public const int MaxQtyPerLine = 99;

    /// <summary>A single order may not exceed this many distinct lines.</summary>
    public const int MaxLinesPerOrder = 40;

    private readonly PricingPolicy _policy = policy
        ?? throw new ArgumentNullException(nameof(policy));

    public Result<PricedOrder> Price(NewOrderRequest request, IReadOnlyDictionary<Guid, MenuItem> catalog)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(catalog);

        if (string.IsNullOrWhiteSpace(request.TableLabel))
        {
            return DomainError.Validation(
                "order.table_required", "An order needs a table label.");
        }

        if (request.TableLabel.Trim().Length > 20)
        {
            return DomainError.Validation(
                "order.table_too_long", "A table label may be at most 20 characters.");
        }

        if (request.Lines is null || request.Lines.Count == 0)
        {
            return DomainError.Validation(
                "order.empty", "An order needs at least one item.");
        }

        if (request.Lines.Count > MaxLinesPerOrder)
        {
            return DomainError.Validation(
                "order.too_many_lines",
                $"An order may hold at most {MaxLinesPerOrder} lines.");
        }

        // Merge duplicates rather than rejecting them: a till operator tapping
        // the same item twice means "two of these", and two lines for one item
        // would otherwise produce a confusing receipt.
        var merged = new Dictionary<Guid, (int Qty, string? Note)>();

        foreach (var line in request.Lines)
        {
            if (line.Qty <= 0)
            {
                return DomainError.Validation(
                    "order.qty_invalid", "Every line needs a quantity of at least 1.");
            }

            if (!catalog.TryGetValue(line.MenuItemId, out var item))
            {
                return DomainError.NotFound(
                    "menu_item.not_found", $"Menu item {line.MenuItemId} does not exist.");
            }

            if (!item.IsAvailable)
            {
                return DomainError.Conflict(
                    "menu_item.unavailable", $"{item.Name} is marked unavailable.");
            }

            if (merged.TryGetValue(line.MenuItemId, out var existing))
            {
                merged[line.MenuItemId] = (
                    existing.Qty + line.Qty,
                    existing.Note ?? line.Note);
            }
            else
            {
                merged[line.MenuItemId] = (line.Qty, line.Note);
            }
        }

        var priced = new List<PricedLine>(merged.Count);

        foreach (var (menuItemId, (qty, note)) in merged)
        {
            if (qty > MaxQtyPerLine)
            {
                var name = catalog[menuItemId].Name;
                return DomainError.Validation(
                    "order.qty_too_large",
                    $"{name}: a single order may hold at most {MaxQtyPerLine}.");
            }

            var item = catalog[menuItemId];

            priced.Add(new PricedLine(
                MenuItemId: item.Id,
                NameSnapshot: item.Name,
                Qty: qty,
                UnitPrice: item.Price,
                LineTotal: Money.Round(item.Price * qty),
                Note: string.IsNullOrWhiteSpace(note) ? null : note.Trim()));
        }

        return new PricedOrder(
            TableLabel: request.TableLabel.Trim(),
            Note: string.IsNullOrWhiteSpace(request.Note) ? null : request.Note.Trim(),
            Lines: priced,
            Totals: _policy.TotalFor(priced));
    }
}
