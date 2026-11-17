using System.Data;
using CafeOps.Infrastructure.Configuration;
using Microsoft.Extensions.Options;
using Npgsql;

namespace CafeOps.Infrastructure.Database;

/// <summary>Hands out open connections to the project database.</summary>
public interface IDbConnectionFactory
{
    Task<NpgsqlConnection> OpenAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Opens connections from a single shared <see cref="NpgsqlDataSource"/>.
/// </summary>
/// <remarks>
/// The data source is built once and registered as a singleton. Building one
/// per request would discard the connection pool each time and turn every call
/// into a fresh TCP and TLS handshake to the database.
/// </remarks>
public sealed class NpgsqlConnectionFactory : IDbConnectionFactory, IAsyncDisposable
{
    private readonly NpgsqlDataSource _dataSource;

    public NpgsqlConnectionFactory(IOptions<SupabaseOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var builder = new NpgsqlDataSourceBuilder(options.Value.ConnectionString);

        // Postgres enums arrive as their snake_case labels. Mapping them here
        // means the rest of the code reads and writes real C# enums.
        builder.MapEnum<Domain.UserRole>("user_role");
        builder.MapEnum<Domain.OrderStatus>("order_status");
        builder.MapEnum<Domain.OrderItemStatus>("order_item_status");
        builder.MapEnum<Domain.StockReason>("stock_reason");

        _dataSource = builder.Build();
    }

    public async Task<NpgsqlConnection> OpenAsync(CancellationToken cancellationToken = default)
    {
        var connection = await _dataSource.OpenConnectionAsync(cancellationToken);

        if (connection.State != ConnectionState.Open)
        {
            throw new InvalidOperationException("Could not open a database connection.");
        }

        return connection;
    }

    public ValueTask DisposeAsync() => _dataSource.DisposeAsync();
}
