namespace CafeOps.Infrastructure.Database;

/// <summary>
/// Converts Postgres timestamps into the types the domain uses.
/// </summary>
/// <remarks>
/// Npgsql materialises <c>timestamptz</c> as a <see cref="DateTime"/> with
/// <see cref="DateTimeKind.Utc"/>, not as a <see cref="DateTimeOffset"/>. A row
/// record that declares <c>DateTimeOffset</c> therefore has no constructor
/// Dapper can match, and the failure appears at runtime on the first real
/// query rather than at compile time.
///
/// So the row records mirror what the driver actually returns, and the
/// conversion to the domain's <c>DateTimeOffset</c> happens here, once.
/// </remarks>
internal static class Timestamps
{
    public static DateTimeOffset AsUtc(this DateTime value) =>
        new(DateTime.SpecifyKind(value, DateTimeKind.Utc), TimeSpan.Zero);
}
