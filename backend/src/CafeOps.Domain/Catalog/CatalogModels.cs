namespace CafeOps.Domain.Catalog;

/// <summary>A sellable item, as the pricing and stock rules need to see it.</summary>
public sealed record MenuItem(
    Guid Id,
    string Name,
    decimal Price,
    bool IsAvailable);

/// <summary>A stock-keeping unit and its current balance.</summary>
public sealed record Ingredient(
    Guid Id,
    string Name,
    string Unit,
    decimal StockQty,
    decimal ReorderLevel)
{
    public bool IsLow => StockQty <= ReorderLevel;
}

/// <summary>
/// How much of one ingredient a single serving of one menu item consumes.
/// </summary>
public sealed record RecipeLine(
    Guid MenuItemId,
    Guid IngredientId,
    decimal QtyPerServing);
