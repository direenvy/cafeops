using CafeOps.Domain.Catalog;
using CafeOps.Domain.Orders;
using CafeOps.Domain.Stock;

namespace CafeOps.Tests;

public sealed class StockMathTests
{
    private static readonly Guid Latte = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid Cappuccino = Guid.Parse("22222222-2222-2222-2222-222222222222");
    private static readonly Guid BottledWater = Guid.Parse("33333333-3333-3333-3333-333333333333");

    private static readonly Guid Beans = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    private static readonly Guid Milk = Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");

    private static readonly RecipeLine[] Recipes =
    [
        new(Latte, Beans, 18m),
        new(Latte, Milk, 210m),
        new(Cappuccino, Beans, 18m),
        new(Cappuccino, Milk, 170m),
    ];

    private static PricedLine Sold(Guid menuItemId, int qty) =>
        new(menuItemId, "Item", qty, 10m, 10m * qty, null);

    private static Dictionary<Guid, Ingredient> Stock(decimal beans, decimal milk) => new()
    {
        [Beans] = new Ingredient(Beans, "Espresso beans", "g", beans, 2000m),
        [Milk] = new Ingredient(Milk, "Fresh milk", "ml", milk, 8000m),
    };

    [Fact]
    public void Multiplies_the_recipe_by_the_quantity_sold()
    {
        var requirements = StockMath.RequirementsFor([Sold(Latte, 3)], Recipes);

        Assert.Equal(54m, requirements.Single(r => r.IngredientId == Beans).RequiredQty);
        Assert.Equal(630m, requirements.Single(r => r.IngredientId == Milk).RequiredQty);
    }

    [Fact]
    public void Aggregates_a_shared_ingredient_across_different_items()
    {
        // The case that makes per-line checking wrong: a latte and a cappuccino
        // both draw milk, and only the combined figure tells you whether the
        // stock room can cover the order.
        var requirements = StockMath.RequirementsFor(
            [Sold(Latte, 1), Sold(Cappuccino, 1)],
            Recipes);

        Assert.Equal(36m, requirements.Single(r => r.IngredientId == Beans).RequiredQty);
        Assert.Equal(380m, requirements.Single(r => r.IngredientId == Milk).RequiredQty);
    }

    [Fact]
    public void An_item_with_no_recipe_consumes_nothing_and_does_not_fail()
    {
        // A resold bottled drink has no recipe. That is valid configuration and
        // must not block the sale.
        var requirements = StockMath.RequirementsFor([Sold(BottledWater, 5)], Recipes);

        Assert.Empty(requirements);
    }

    [Fact]
    public void No_shortages_when_everything_is_covered()
    {
        var requirements = StockMath.RequirementsFor([Sold(Latte, 2)], Recipes);

        var shortages = StockMath.ShortagesFor(requirements, Stock(beans: 1000m, milk: 5000m));

        Assert.Empty(shortages);
    }

    [Fact]
    public void Exactly_enough_stock_is_not_a_shortage()
    {
        // Boundary worth pinning: selling the last of something must succeed.
        var requirements = StockMath.RequirementsFor([Sold(Latte, 1)], Recipes);

        var shortages = StockMath.ShortagesFor(requirements, Stock(beans: 18m, milk: 210m));

        Assert.Empty(shortages);
    }

    [Fact]
    public void One_unit_short_is_a_shortage()
    {
        var requirements = StockMath.RequirementsFor([Sold(Latte, 1)], Recipes);

        var shortages = StockMath.ShortagesFor(requirements, Stock(beans: 18m, milk: 209m));

        var shortage = Assert.Single(shortages);
        Assert.Equal(Milk, shortage.IngredientId);
        Assert.Equal(210m, shortage.Required);
        Assert.Equal(209m, shortage.Available);
        Assert.Equal(1m, shortage.Deficit);
    }

    [Fact]
    public void Reports_every_shortage_not_just_the_first()
    {
        // The person at the till should be told everything that is missing in
        // one go, rather than discovering them one retry at a time.
        var requirements = StockMath.RequirementsFor([Sold(Latte, 10)], Recipes);

        var shortages = StockMath.ShortagesFor(requirements, Stock(beans: 10m, milk: 100m));

        Assert.Equal(2, shortages.Count);
    }

    [Fact]
    public void A_recipe_pointing_at_a_missing_ingredient_surfaces_instead_of_passing_silently()
    {
        var requirements = StockMath.RequirementsFor([Sold(Latte, 1)], Recipes);

        // Milk is absent from the stock dictionary entirely.
        var onlyBeans = new Dictionary<Guid, Ingredient>
        {
            [Beans] = new Ingredient(Beans, "Espresso beans", "g", 1000m, 0m),
        };

        var shortage = Assert.Single(StockMath.ShortagesFor(requirements, onlyBeans));

        Assert.Equal(Milk, shortage.IngredientId);
        Assert.Equal(0m, shortage.Available);
    }

    [Fact]
    public void Shortage_text_names_the_ingredient_and_both_quantities()
    {
        var shortage = new StockShortage(Milk, "Fresh milk", "ml", 210m, 50m);

        var text = shortage.ToString();

        Assert.Contains("Fresh milk", text);
        Assert.Contains("210", text);
        Assert.Contains("50", text);
    }

    [Fact]
    public void Requirements_are_ordered_so_the_lock_order_is_deterministic()
    {
        // The order service locks ingredient rows in this order. A stable order
        // is what stops two concurrent orders sharing ingredients from
        // deadlocking against each other.
        var requirements = StockMath.RequirementsFor(
            [Sold(Cappuccino, 1), Sold(Latte, 1)],
            Recipes);

        Assert.Equal(
            requirements.Select(r => r.IngredientId).OrderBy(id => id),
            requirements.Select(r => r.IngredientId));
    }
}
