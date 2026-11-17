using CafeOps.Domain.Catalog;
using CafeOps.Domain.Orders;

namespace CafeOps.Domain.Stock;

/// <summary>How much of one ingredient an order consumes in total.</summary>
public sealed record StockRequirement(Guid IngredientId, decimal RequiredQty);

/// <summary>An ingredient there is not enough of to fulfil an order.</summary>
public sealed record StockShortage(
    Guid IngredientId,
    string IngredientName,
    string Unit,
    decimal Required,
    decimal Available)
{
    public decimal Deficit => Required - Available;

    public override string ToString() =>
        $"{IngredientName}: need {Required}{Unit}, have {Available}{Unit}";
}

/// <summary>
/// The arithmetic that connects a sale to the stock room.
/// </summary>
/// <remarks>
/// Pure functions over plain data. The transaction that actually writes the
/// ledger lives in the infrastructure layer; what to write is decided here,
/// where it can be tested without a database.
/// </remarks>
public static class StockMath
{
    /// <summary>
    /// Totals up what an order will draw from the stock room.
    /// </summary>
    /// <remarks>
    /// Requirements are aggregated across lines, which matters: a latte and a
    /// cappuccino both pull fresh milk, and checking each line separately could
    /// pass both while the stock room can only cover one.
    /// </remarks>
    public static IReadOnlyList<StockRequirement> RequirementsFor(
        IEnumerable<PricedLine> lines,
        IEnumerable<RecipeLine> recipes)
    {
        ArgumentNullException.ThrowIfNull(lines);
        ArgumentNullException.ThrowIfNull(recipes);

        var byMenuItem = recipes
            .GroupBy(recipe => recipe.MenuItemId)
            .ToDictionary(group => group.Key, group => group.ToArray());

        var totals = new Dictionary<Guid, decimal>();

        foreach (var line in lines)
        {
            if (!byMenuItem.TryGetValue(line.MenuItemId, out var recipeLines))
            {
                // An item with no recipe (a bottled drink resold as-is) simply
                // consumes nothing. That is a legitimate configuration, not an
                // error, so it must not block the sale.
                continue;
            }

            foreach (var recipe in recipeLines)
            {
                var required = recipe.QtyPerServing * line.Qty;
                totals[recipe.IngredientId] = totals.GetValueOrDefault(recipe.IngredientId) + required;
            }
        }

        return totals
            .Select(entry => new StockRequirement(entry.Key, entry.Value))
            .OrderBy(requirement => requirement.IngredientId)
            .ToArray();
    }

    /// <summary>
    /// Returns every ingredient that cannot cover its requirement.
    /// </summary>
    /// <remarks>
    /// All shortages are reported, not just the first one, so the person at the
    /// till is told everything that is missing in one go.
    /// </remarks>
    public static IReadOnlyList<StockShortage> ShortagesFor(
        IEnumerable<StockRequirement> requirements,
        IReadOnlyDictionary<Guid, Ingredient> ingredients)
    {
        ArgumentNullException.ThrowIfNull(requirements);
        ArgumentNullException.ThrowIfNull(ingredients);

        var shortages = new List<StockShortage>();

        foreach (var requirement in requirements)
        {
            if (!ingredients.TryGetValue(requirement.IngredientId, out var ingredient))
            {
                // A recipe pointing at an ingredient that no longer exists is a
                // data fault, not a stock problem. Surfacing it as a shortage
                // with zero available makes it visible instead of silent.
                shortages.Add(new StockShortage(
                    requirement.IngredientId,
                    $"Unknown ingredient {requirement.IngredientId}",
                    string.Empty,
                    requirement.RequiredQty,
                    0m));
                continue;
            }

            if (ingredient.StockQty < requirement.RequiredQty)
            {
                shortages.Add(new StockShortage(
                    ingredient.Id,
                    ingredient.Name,
                    ingredient.Unit,
                    requirement.RequiredQty,
                    ingredient.StockQty));
            }
        }

        return shortages;
    }
}
