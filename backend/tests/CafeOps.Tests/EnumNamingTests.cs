using CafeOps.Domain;

namespace CafeOps.Tests;

public sealed class EnumNamingTests
{
    [Theory]
    [InlineData(StockReason.Sale, "sale")]
    [InlineData(StockReason.Delivery, "delivery")]
    [InlineData(StockReason.StockCount, "stock_count")]
    [InlineData(StockReason.Adjustment, "adjustment")]
    public void Writes_postgres_enum_labels_in_snake_case(StockReason reason, string expected)
    {
        Assert.Equal(expected, reason.ToPostgres());
    }

    [Theory]
    [InlineData("stock_count", StockReason.StockCount)]
    [InlineData("sale", StockReason.Sale)]
    [InlineData("void", StockReason.Void)]
    public void Reads_postgres_enum_labels_back(string label, StockReason expected)
    {
        Assert.Equal(expected, EnumNaming.FromPostgres<StockReason>(label));
    }

    [Theory]
    [InlineData(StockReason.StockCount)]
    [InlineData(StockReason.Sale)]
    [InlineData(StockReason.Void)]
    [InlineData(StockReason.Waste)]
    [InlineData(StockReason.Delivery)]
    [InlineData(StockReason.Adjustment)]
    public void Round_trips_every_reason(StockReason reason)
    {
        Assert.Equal(reason, EnumNaming.FromPostgres<StockReason>(reason.ToPostgres()));
    }

    [Theory]
    [InlineData(OrderStatus.Open)]
    [InlineData(OrderStatus.Preparing)]
    [InlineData(OrderStatus.Cancelled)]
    public void Round_trips_order_statuses(OrderStatus status)
    {
        Assert.Equal(status, EnumNaming.FromPostgres<OrderStatus>(status.ToPostgres()));
    }

    [Fact]
    public void Rejects_a_label_that_is_not_a_member()
    {
        Assert.Throws<ArgumentException>(
            () => EnumNaming.FromPostgres<StockReason>("teleported_away"));
    }
}
