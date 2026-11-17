using CafeOps.Domain.Orders;

namespace CafeOps.Tests;

public sealed class PricingPolicyTests
{
    private static PricedLine Line(decimal lineTotal) =>
        new(Guid.NewGuid(), "Item", 1, lineTotal, lineTotal, null);

    [Fact]
    public void Tax_is_charged_on_subtotal_plus_service_charge()
    {
        var policy = new PricingPolicy(ServiceChargeRate: 0.10m, ServiceTaxRate: 0.06m);

        var totals = policy.TotalFor([Line(100.00m)]);

        Assert.Equal(100.00m, totals.Subtotal);
        Assert.Equal(10.00m, totals.ServiceCharge);

        // 6% of 110.00, not 6% of 100.00. Taxing only the subtotal is the
        // common shortcut and it under-charges by 60 cents on every RM100.
        Assert.Equal(6.60m, totals.Tax);
        Assert.Equal(116.60m, totals.Total);
    }

    [Fact]
    public void Total_is_the_sum_of_its_parts()
    {
        var policy = PricingPolicy.Default;

        var totals = policy.TotalFor([Line(13.00m), Line(8.50m), Line(15.50m)]);

        Assert.Equal(
            totals.Subtotal + totals.ServiceCharge + totals.Tax,
            totals.Total);
    }

    [Fact]
    public void Rates_of_zero_leave_the_subtotal_alone()
    {
        var totals = PricingPolicy.None.TotalFor([Line(21.50m)]);

        Assert.Equal(21.50m, totals.Subtotal);
        Assert.Equal(0m, totals.ServiceCharge);
        Assert.Equal(0m, totals.Tax);
        Assert.Equal(21.50m, totals.Total);
    }

    [Fact]
    public void An_order_with_no_lines_totals_zero()
    {
        var totals = PricingPolicy.Default.TotalFor([]);

        Assert.Equal(OrderTotals.Zero, totals);
    }

    [Theory]
    // Each component is rounded to cents, so no sub-cent value can survive into
    // a total that a customer is asked to pay.
    [InlineData(7.00, 0.70, 0.46, 8.16)]
    [InlineData(12.50, 1.25, 0.83, 14.58)]
    [InlineData(0.05, 0.01, 0.00, 0.06)]
    public void Components_are_rounded_to_cents(
        double subtotal,
        double expectedService,
        double expectedTax,
        double expectedTotal)
    {
        var totals = PricingPolicy.Default.TotalFor([Line((decimal)subtotal)]);

        Assert.Equal((decimal)expectedService, totals.ServiceCharge);
        Assert.Equal((decimal)expectedTax, totals.Tax);
        Assert.Equal((decimal)expectedTotal, totals.Total);
    }

    [Fact]
    public void Rates_are_configurable_for_a_venue_that_charges_neither()
    {
        var takeaway = new PricingPolicy(0m, 0.06m);

        var totals = takeaway.TotalFor([Line(10.00m)]);

        Assert.Equal(0m, totals.ServiceCharge);
        Assert.Equal(0.60m, totals.Tax);
        Assert.Equal(10.60m, totals.Total);
    }
}
