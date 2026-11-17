namespace CafeOps.Domain;

/// <summary>
/// Money rounding, in one place.
/// </summary>
/// <remarks>
/// Two rules worth being explicit about, because getting either wrong produces
/// receipts that are off by a cent and are very hard to explain afterwards:
/// <list type="bullet">
/// <item>
/// Everything is <see cref="decimal"/>. A <c>double</c> cannot hold 0.1 exactly,
/// so float arithmetic on prices drifts.
/// </item>
/// <item>
/// Rounding is away-from-zero (what a till does), not .NET's default
/// banker's rounding, which would round 2.675 down to 2.67.
/// </item>
/// </list>
/// </remarks>
public static class Money
{
    /// <summary>Rounds a monetary amount to cents the way a till does.</summary>
    public static decimal Round(decimal amount) =>
        Math.Round(amount, 2, MidpointRounding.AwayFromZero);

    /// <summary>Applies a rate (e.g. 0.06m) to a base amount and rounds the result.</summary>
    public static decimal Apply(decimal amount, decimal rate) => Round(amount * rate);
}
