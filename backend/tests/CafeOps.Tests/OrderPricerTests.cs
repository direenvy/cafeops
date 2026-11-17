using CafeOps.Domain;
using CafeOps.Domain.Catalog;
using CafeOps.Domain.Orders;

namespace CafeOps.Tests;

public sealed class OrderPricerTests
{
    private static readonly Guid LatteId = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly Guid CroissantId = Guid.Parse("22222222-2222-2222-2222-222222222222");
    private static readonly Guid SoldOutId = Guid.Parse("33333333-3333-3333-3333-333333333333");

    private static readonly Dictionary<Guid, MenuItem> Catalog = new()
    {
        [LatteId] = new MenuItem(LatteId, "Latte", 13.00m, IsAvailable: true),
        [CroissantId] = new MenuItem(CroissantId, "Butter Croissant", 8.50m, IsAvailable: true),
        [SoldOutId] = new MenuItem(SoldOutId, "Banana Bread", 9.00m, IsAvailable: false),
    };

    private static OrderPricer Pricer => new(PricingPolicy.Default);

    private static NewOrderRequest Request(params OrderLineRequest[] lines) =>
        new("T1", lines);

    [Fact]
    public void Prices_lines_from_the_catalogue_not_the_request()
    {
        var result = Pricer.Price(Request(new OrderLineRequest(LatteId, 2)), Catalog);

        Assert.True(result.IsSuccess);

        var line = Assert.Single(result.Value.Lines);
        Assert.Equal(13.00m, line.UnitPrice);
        Assert.Equal(26.00m, line.LineTotal);
        Assert.Equal("Latte", line.NameSnapshot);
    }

    [Fact]
    public void Captures_the_item_name_so_a_later_rename_cannot_rewrite_history()
    {
        var result = Pricer.Price(Request(new OrderLineRequest(CroissantId, 1)), Catalog);

        Assert.Equal("Butter Croissant", Assert.Single(result.Value.Lines).NameSnapshot);
    }

    [Fact]
    public void Merges_repeated_items_into_one_line()
    {
        var result = Pricer.Price(
            Request(
                new OrderLineRequest(LatteId, 1),
                new OrderLineRequest(LatteId, 2)),
            Catalog);

        var line = Assert.Single(result.Value.Lines);
        Assert.Equal(3, line.Qty);
        Assert.Equal(39.00m, line.LineTotal);
    }

    [Fact]
    public void Totals_cover_every_line()
    {
        var result = Pricer.Price(
            Request(
                new OrderLineRequest(LatteId, 1),
                new OrderLineRequest(CroissantId, 1)),
            Catalog);

        Assert.Equal(21.50m, result.Value.Totals.Subtotal);
        Assert.Equal(2.15m, result.Value.Totals.ServiceCharge);
        Assert.Equal(1.42m, result.Value.Totals.Tax);
        Assert.Equal(25.07m, result.Value.Totals.Total);
    }

    [Fact]
    public void Rejects_an_empty_order()
    {
        var result = Pricer.Price(Request(), Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("order.empty", result.Error!.Code);
        Assert.Equal(ErrorKind.Validation, result.Error.Kind);
    }

    [Fact]
    public void Rejects_an_unknown_menu_item_as_not_found()
    {
        var result = Pricer.Price(Request(new OrderLineRequest(Guid.NewGuid(), 1)), Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("menu_item.not_found", result.Error!.Code);
        Assert.Equal(ErrorKind.NotFound, result.Error.Kind);
    }

    [Fact]
    public void Rejects_an_unavailable_item_as_a_conflict_not_a_validation_error()
    {
        // The request is perfectly well formed; it is the current state of the
        // menu that refuses it, which is a 409 rather than a 400.
        var result = Pricer.Price(Request(new OrderLineRequest(SoldOutId, 1)), Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("menu_item.unavailable", result.Error!.Code);
        Assert.Equal(ErrorKind.Conflict, result.Error.Kind);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void Rejects_a_non_positive_quantity(int qty)
    {
        var result = Pricer.Price(Request(new OrderLineRequest(LatteId, qty)), Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("order.qty_invalid", result.Error!.Code);
    }

    [Fact]
    public void Rejects_a_quantity_above_the_per_line_cap()
    {
        var result = Pricer.Price(
            Request(new OrderLineRequest(LatteId, OrderPricer.MaxQtyPerLine + 1)),
            Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("order.qty_too_large", result.Error!.Code);
    }

    [Fact]
    public void Applies_the_cap_to_the_merged_quantity_not_each_line()
    {
        // Two lines of 60 are each under the cap but together exceed it. Checking
        // before merging would let a fat-fingered 120-latte order through.
        var result = Pricer.Price(
            Request(
                new OrderLineRequest(LatteId, 60),
                new OrderLineRequest(LatteId, 60)),
            Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("order.qty_too_large", result.Error!.Code);
    }

    [Fact]
    public void Rejects_a_missing_table_label()
    {
        var result = Pricer.Price(
            new NewOrderRequest("   ", [new OrderLineRequest(LatteId, 1)]),
            Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("order.table_required", result.Error!.Code);
    }

    [Fact]
    public void Trims_whitespace_from_the_table_label_and_notes()
    {
        var result = Pricer.Price(
            new NewOrderRequest(
                "  T7  ",
                [new OrderLineRequest(LatteId, 1, "  oat milk  ")],
                "  birthday  "),
            Catalog);

        Assert.Equal("T7", result.Value.TableLabel);
        Assert.Equal("birthday", result.Value.Note);
        Assert.Equal("oat milk", Assert.Single(result.Value.Lines).Note);
    }

    [Fact]
    public void Turns_a_blank_note_into_null_rather_than_storing_whitespace()
    {
        var result = Pricer.Price(
            new NewOrderRequest("T1", [new OrderLineRequest(LatteId, 1, "   ")], "  "),
            Catalog);

        Assert.Null(result.Value.Note);
        Assert.Null(Assert.Single(result.Value.Lines).Note);
    }

    [Fact]
    public void Rejects_more_lines_than_the_cap_allows()
    {
        var lines = Enumerable
            .Range(0, OrderPricer.MaxLinesPerOrder + 1)
            .Select(_ => new OrderLineRequest(LatteId, 1))
            .ToArray();

        var result = Pricer.Price(Request(lines), Catalog);

        Assert.False(result.IsSuccess);
        Assert.Equal("order.too_many_lines", result.Error!.Code);
    }

    [Fact]
    public void Reading_the_value_of_a_failed_result_throws_rather_than_returning_a_default()
    {
        var result = Pricer.Price(Request(), Catalog);

        Assert.Throws<InvalidOperationException>(() => result.Value);
    }
}
