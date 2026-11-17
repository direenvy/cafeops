using CafeOps.Api.Auth;
using CafeOps.Domain.Abstractions;
using CafeOps.Infrastructure;
using CafeOps.Infrastructure.Configuration;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace CafeOps.Tests;

/// <summary>
/// Checks that the dependency graph is coherent.
/// </summary>
/// <remarks>
/// <para>
/// This exists because of a real failure: the role authorization handler was
/// registered as a singleton while depending on <see cref="IUserDirectory"/>,
/// which is scoped because it holds a per-request database connection. The
/// whole API refused to start, and nothing caught it until it was run by hand.
/// </para>
/// <para>
/// A unit test cannot catch a wiring mistake, because wiring is not logic. What
/// it can do is build the container the same way the application does and let
/// it validate itself. That is all this is — and it has to go through
/// <see cref="WebApplication"/> rather than a bare
/// <see cref="ServiceCollection"/>, because ASP.NET's own authorization
/// services depend on routing, which only a web host registers.
/// </para>
/// </remarks>
public sealed class ServiceRegistrationTests
{
    /// <summary>
    /// Shaped like a real connection string so the data source can be built.
    /// Nothing ever connects: <c>NpgsqlDataSourceBuilder.Build()</c> only
    /// parses, so this test needs no database.
    /// </summary>
    private const string FakeConnectionString =
        "Host=localhost;Port=5432;Database=postgres;Username=postgres;Password=not-a-real-password";

    private static Dictionary<string, string?> Settings(
        string? serviceCharge = null,
        string? serviceTax = null) =>
        new()
        {
            ["Supabase:ProjectUrl"] = "https://example.supabase.co",
            ["Supabase:ConnectionString"] = FakeConnectionString,
            ["Pricing:ServiceChargeRate"] = serviceCharge,
            ["Pricing:ServiceTaxRate"] = serviceTax,
        };

    /// <summary>
    /// Builds the app exactly as <c>Program.cs</c> does, in the Development
    /// environment.
    /// </summary>
    /// <remarks>
    /// Development is the point: it is what turns on <c>ValidateScopes</c> and
    /// <c>ValidateOnBuild</c>, so <see cref="WebApplicationBuilder.Build"/>
    /// throws on a singleton capturing a scoped service instead of leaking one
    /// request's connection for the life of the process.
    /// </remarks>
    private static WebApplication BuildApp(Dictionary<string, string?>? settings = null)
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            EnvironmentName = Environments.Development,
        });

        builder.Configuration.AddInMemoryCollection(settings ?? Settings());

        var supabase = builder.Configuration
            .GetSection(SupabaseOptions.SectionName)
            .Get<SupabaseOptions>()!;

        builder.Services.AddCafeOpsInfrastructure(builder.Configuration);
        builder.Services.AddCafeOpsAuth(supabase);

        return builder.Build();
    }

    [Fact]
    public void The_container_builds_and_validates()
    {
        var exception = Record.Exception(() => BuildApp().DisposeAsync().AsTask().Wait());

        Assert.Null(exception);
    }

    [Theory]
    [InlineData(typeof(IOrderService))]
    [InlineData(typeof(IStockService))]
    [InlineData(typeof(IReportService))]
    [InlineData(typeof(IUserDirectory))]
    public async Task Every_service_the_controllers_need_can_be_resolved(Type serviceType)
    {
        await using var app = BuildApp();

        // Resolved from a scope, the way a request would be, because all four
        // are scoped — and asking the root provider for them is itself the
        // mistake this file is about.
        using var scope = app.Services.CreateScope();

        Assert.NotNull(scope.ServiceProvider.GetService(serviceType));
    }

    [Fact]
    public async Task Pricing_defaults_to_the_malaysian_rates_when_unconfigured()
    {
        await using var app = BuildApp();

        var policy = app.Services.GetRequiredService<Domain.Orders.PricingPolicy>();

        Assert.Equal(0.10m, policy.ServiceChargeRate);
        Assert.Equal(0.06m, policy.ServiceTaxRate);
    }

    [Fact]
    public async Task Pricing_rates_can_be_overridden_by_configuration()
    {
        // A venue that charges no service charge and sits under a different tax
        // rate should need a config change, not a rebuild.
        await using var app = BuildApp(Settings(serviceCharge: "0", serviceTax: "0.08"));

        var policy = app.Services.GetRequiredService<Domain.Orders.PricingPolicy>();

        Assert.Equal(0m, policy.ServiceChargeRate);
        Assert.Equal(0.08m, policy.ServiceTaxRate);
    }

    [Fact]
    public async Task Options_validation_rejects_a_missing_project_url()
    {
        // ValidateDataAnnotations plus ValidateOnStart is what turns a missing
        // setting into a startup failure rather than a 500 on the first
        // request that happens to need it.
        var settings = Settings();
        settings["Supabase:ProjectUrl"] = string.Empty;

        await using var app = BuildApp(settings);

        Assert.Throws<Microsoft.Extensions.Options.OptionsValidationException>(
            () => app.Services
                .GetRequiredService<Microsoft.Extensions.Options.IOptions<SupabaseOptions>>()
                .Value);
    }
}
