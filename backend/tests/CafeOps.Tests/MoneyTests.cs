using CafeOps.Domain;

namespace CafeOps.Tests;

public sealed class MoneyTests
{
    [Theory]
    [InlineData(2.675, 2.68)]  // Banker's rounding would give 2.67 here.
    [InlineData(2.665, 2.67)]
    [InlineData(0.005, 0.01)]
    [InlineData(1.004, 1.00)]
    [InlineData(10.000, 10.00)]
    public void Round_goes_away_from_zero_like_a_till(double input, double expected)
    {
        Assert.Equal((decimal)expected, Money.Round((decimal)input));
    }

    [Fact]
    public void Round_handles_negatives_symmetrically()
    {
        // Refunds and waste are negative, and must not round differently from
        // the sale that created them.
        Assert.Equal(-2.68m, Money.Round(-2.675m));
    }

    [Fact]
    public void Apply_rounds_the_result_of_the_rate()
    {
        Assert.Equal(0.70m, Money.Apply(7.00m, 0.10m));

        // 6% of 7.70 is 0.462, which must land on 0.46 and not leak a third
        // decimal place into a total.
        Assert.Equal(0.46m, Money.Apply(7.70m, 0.06m));
    }

    [Fact]
    public void Decimal_arithmetic_does_not_drift()
    {
        // The reason every amount in this project is a decimal: this sum is
        // exact here and is 0.30000000000000004 with doubles.
        var sum = 0.1m + 0.1m + 0.1m;

        Assert.Equal(0.30m, Money.Round(sum));
    }
}
