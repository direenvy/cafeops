using System.Text.Json;
using System.Text.Json.Serialization;
using CafeOps.Api.Auth;
using CafeOps.Infrastructure;
using CafeOps.Infrastructure.Configuration;

var builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------- configuration

// Read once at startup so authentication can be wired against it. Missing
// configuration stops the process here with a message that says what to do,
// rather than producing a service that starts and then 500s on first use.
var supabase = builder.Configuration
    .GetSection(SupabaseOptions.SectionName)
    .Get<SupabaseOptions>();

if (supabase is null
    || string.IsNullOrWhiteSpace(supabase.ProjectUrl)
    || string.IsNullOrWhiteSpace(supabase.ConnectionString))
{
    throw new InvalidOperationException(
        """
        Supabase configuration is missing.

        Set Supabase:ProjectUrl and Supabase:ConnectionString. In development:

            cd backend/src/CafeOps.Api
            dotnet user-secrets set "Supabase:ProjectUrl" "https://<ref>.supabase.co"
            dotnet user-secrets set "Supabase:ConnectionString" "<postgres connection string>"

        See docs/SETUP.md. These values are never committed.
        """);
}

// ------------------------------------------------------------------- services

builder.Services.AddCafeOpsInfrastructure(builder.Configuration);
builder.Services.AddCafeOpsAuth(supabase);

builder.Services
    .AddControllers()
    .AddJsonOptions(options =>
    {
        var json = options.JsonSerializerOptions;

        // camelCase in, camelCase out, and enums as readable strings. Dart's
        // json_serializable and C# then agree on the wire format without either
        // side needing per-field annotations.
        json.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
        json.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
        json.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
    });

builder.Services.AddProblemDetails();
builder.Services.AddOpenApi();

// Flutter web runs on a different origin, so the browser will preflight every
// call. Origins are configuration, never a wildcard: credentialed requests and
// "*" are mutually exclusive anyway, and listing them keeps a stray deployment
// from talking to this API.
var allowedOrigins = builder.Configuration
    .GetSection("Cors:AllowedOrigins")
    .Get<string[]>() ?? [];

const string CorsPolicy = "cafeops-clients";

builder.Services.AddCors(options => options.AddPolicy(CorsPolicy, policy =>
{
    if (builder.Environment.IsDevelopment())
    {
        // `flutter run -d chrome` serves the app from a fresh random port on
        // every launch, so a fixed allow-list is unusable in development: the
        // browser blocks the call, and a blocked call is indistinguishable
        // from an unreachable server to the app. Any loopback origin is
        // accepted here, and only here.
        policy.SetIsOriginAllowed(origin =>
                  Uri.TryCreate(origin, UriKind.Absolute, out var uri) && uri.IsLoopback)
              .AllowAnyHeader()
              .WithMethods("GET", "POST", "OPTIONS");
        return;
    }

    if (allowedOrigins.Length == 0)
    {
        // Nothing configured in production: allow nothing rather than
        // everything, so a missing setting fails visibly instead of opening
        // the API to any origin.
        policy.WithOrigins();
        return;
    }

    policy.WithOrigins(allowedOrigins)
          .AllowAnyHeader()
          .WithMethods("GET", "POST", "OPTIONS");
}));

var app = builder.Build();

// -------------------------------------------------------------------- pipeline

// Turns an unhandled exception into problem details instead of a stack trace,
// and logs it. Order matters: this has to be first to catch what follows.
app.UseExceptionHandler();
app.UseStatusCodePages();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

// No HTTPS redirection on purpose. In production this runs behind a platform
// proxy that terminates TLS; redirecting here would either double-redirect or
// bounce health checks that arrive over plain HTTP inside the private network.
app.UseCors(CorsPolicy);

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.Run();
