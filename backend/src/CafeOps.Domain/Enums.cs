namespace CafeOps.Domain;

/// <summary>
/// Mirrors the <c>public.user_role</c> Postgres enum.
/// </summary>
public enum UserRole
{
    Staff,
    Manager,
    Owner,
}

/// <summary>
/// Mirrors the <c>public.order_status</c> Postgres enum.
/// </summary>
public enum OrderStatus
{
    Open,
    Preparing,
    Ready,
    Served,
    Paid,
    Cancelled,
}

/// <summary>
/// Mirrors the <c>public.order_item_status</c> Postgres enum.
/// </summary>
public enum OrderItemStatus
{
    Queued,
    Preparing,
    Ready,
    Served,
    Cancelled,
}

/// <summary>
/// Mirrors the <c>public.stock_reason</c> Postgres enum. Every row in the stock
/// ledger carries one, so any change in a balance can be explained.
/// </summary>
public enum StockReason
{
    Delivery,
    Sale,
    Waste,
    Adjustment,
    StockCount,
    Void,
}

public static class EnumNaming
{
    /// <summary>
    /// Converts an enum member to the snake_case label Postgres stores, so that
    /// <see cref="StockReason.StockCount"/> is written as <c>stock_count</c>.
    /// </summary>
    public static string ToPostgres<TEnum>(this TEnum value) where TEnum : struct, Enum
    {
        var name = value.ToString()!;
        var builder = new System.Text.StringBuilder(name.Length + 4);

        for (var i = 0; i < name.Length; i++)
        {
            if (char.IsUpper(name[i]))
            {
                if (i > 0)
                {
                    builder.Append('_');
                }

                builder.Append(char.ToLowerInvariant(name[i]));
            }
            else
            {
                builder.Append(name[i]);
            }
        }

        return builder.ToString();
    }

    /// <summary>
    /// Parses a snake_case Postgres enum label back into <typeparamref name="TEnum"/>.
    /// </summary>
    public static TEnum FromPostgres<TEnum>(string label) where TEnum : struct, Enum
    {
        var pascal = string.Concat(
            label.Split('_', StringSplitOptions.RemoveEmptyEntries)
                 .Select(part => char.ToUpperInvariant(part[0]) + part[1..]));

        return Enum.Parse<TEnum>(pascal, ignoreCase: true);
    }
}
