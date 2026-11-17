using CafeOps.Domain.Abstractions;
using CafeOps.Domain.Orders;
using CafeOps.Infrastructure.Configuration;
using CafeOps.Infrastructure.Database;
using CafeOps.Infrastructure.Identity;
using CafeOps.Infrastructure.Orders;
using CafeOps.Infrastructure.Reports;
using CafeOps.Infrastructure.Stock;
using Dapper;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace CafeOps.Infrastructure;

public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers everything that talks to Postgres.
    /// </summary>
    /// <remarks>
    /// Composition lives here rather than in <c>Program.cs</c> so the API
    /// project does not need to know which database is behind the interfaces,
    /// and so the test project can register fakes in their place.
    /// </remarks>
    public static IServiceCollection AddCafeOpsInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        // Lets Dapper bind stock_qty to a StockQty property. The explicit
        // aliases in the SQL do not depend on this, but it stops a future query
        // from failing confusingly if someone forgets one.
        DefaultTypeMap.MatchNamesWithUnderscores = true;

        services.AddOptions<SupabaseOptions>()
            .Bind(configuration.GetSection(SupabaseOptions.SectionName))
            .ValidateDataAnnotations()
            // Fail at startup, not on the first request that needs the database.
            .ValidateOnStart();

        services.AddSingleton<IDbConnectionFactory, NpgsqlConnectionFactory>();

        // Rates come from configuration so a venue can be set up without a
        // rebuild; the default is the Malaysian 10% service charge plus 6% SST.
        services.AddSingleton(_ =>
        {
            var section = configuration.GetSection("Pricing");
            var serviceCharge = section.GetValue<decimal?>("ServiceChargeRate");
            var serviceTax = section.GetValue<decimal?>("ServiceTaxRate");

            return serviceCharge is null && serviceTax is null
                ? PricingPolicy.Default
                : new PricingPolicy(
                    serviceCharge ?? PricingPolicy.Default.ServiceChargeRate,
                    serviceTax ?? PricingPolicy.Default.ServiceTaxRate);
        });

        services.AddMemoryCache();

        services.AddScoped<IUserDirectory, UserDirectory>();
        services.AddScoped<IOrderService, OrderService>();
        services.AddScoped<IStockService, StockService>();
        services.AddScoped<IReportService, ReportService>();

        return services;
    }
}
