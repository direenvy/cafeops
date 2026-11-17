namespace CafeOps.Domain.Orders;

/// <summary>
/// The rates applied on top of an order subtotal.
/// </summary>
/// <param name="ServiceChargeRate">Service charge, e.g. <c>0.10m</c> for 10%.</param>
/// <param name="ServiceTaxRate">Government service tax, e.g. <c>0.06m</c> for 6%.</param>
/// <remarks>
/// These are configuration, not constants, because they change by law and by
/// venue. The default matches a Malaysian cafe: 10% service charge, then 6%
/// service tax charged on the subtotal <em>plus</em> the service charge, which
/// is how the tax is actually levied. Taxing only the subtotal is a common and
/// quietly wrong shortcut.
/// </remarks>
public sealed record PricingPolicy(decimal ServiceChargeRate, decimal ServiceTaxRate)
{
    /// <summary>10% service charge, 6% service tax.</summary>
    public static PricingPolicy Default { get; } = new(0.10m, 0.06m);

    /// <summary>No service charge and no tax, for takeaway-only venues and tests.</summary>
    public static PricingPolicy None { get; } = new(0m, 0m);

    public OrderTotals TotalFor(IEnumerable<PricedLine> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);

        var subtotal = Money.Round(lines.Sum(line => line.LineTotal));
        var serviceCharge = Money.Apply(subtotal, ServiceChargeRate);
        var tax = Money.Apply(subtotal + serviceCharge, ServiceTaxRate);

        return new OrderTotals(
            Subtotal: subtotal,
            ServiceCharge: serviceCharge,
            Tax: tax,
            Total: Money.Round(subtotal + serviceCharge + tax));
    }
}
