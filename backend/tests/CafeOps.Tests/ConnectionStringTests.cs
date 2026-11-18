using Npgsql;

namespace CafeOps.Tests;

/// <summary>
/// Tests for accepting either connection-string form.
/// </summary>
/// <remarks>
/// Written after a deployment failed on this. The container built, started and
/// bound its port correctly, then threw "Format of the initialization string
/// does not conform to specification starting at index 0" on every request —
/// because the connection string had been copied from the provider's dashboard
/// in URI form rather than keyword form. Both carry the same information.
/// </remarks>
public sealed class ConnectionStringTests
{
    // Internal to the infrastructure assembly, reached here through the
    // InternalsVisibleTo in its csproj.
    private static string Normalize(string? value) =>
        CafeOps.Infrastructure.Database.ConnectionStrings.Normalize(value);

    private static NpgsqlConnectionStringBuilder Parse(string value) => new(value);

    [Fact]
    public void Keyword_form_is_passed_through_unchanged()
    {
        const string original =
            "Host=db.example.com;Port=5432;Database=postgres;Username=admin;Password=secret";

        Assert.Equal(original, Normalize(original));
    }

    [Theory]
    [InlineData("postgresql://")]
    [InlineData("postgres://")]
    public void A_uri_is_converted_to_keyword_form(string scheme)
    {
        var result = Normalize(
            $"{scheme}postgres.abcdefgh:hunter2@aws-1-ap-southeast-1.pooler.supabase.com:5432/postgres");

        var parsed = Parse(result);

        Assert.Equal("aws-1-ap-southeast-1.pooler.supabase.com", parsed.Host);
        Assert.Equal(5432, parsed.Port);
        Assert.Equal("postgres", parsed.Database);
        Assert.Equal("postgres.abcdefgh", parsed.Username);
        Assert.Equal("hunter2", parsed.Password);
    }

    [Fact]
    public void A_uri_without_a_port_gets_the_postgres_default()
    {
        // Not the scheme default, which for an unknown scheme is -1 and would
        // produce a connection string nothing can use.
        var parsed = Parse(Normalize("postgresql://user:pass@db.example.com/postgres"));

        Assert.Equal(5432, parsed.Port);
    }

    [Fact]
    public void A_percent_encoded_password_is_decoded()
    {
        // A password with @ or / must be encoded in a URI. Passing the encoded
        // form through would fail to authenticate with nothing to say why.
        var parsed = Parse(Normalize("postgresql://user:p%40ss%2Fword@db.example.com:5432/postgres"));

        Assert.Equal("p@ss/word", parsed.Password);
    }

    [Fact]
    public void TLS_is_required_by_default_for_a_uri()
    {
        // Supabase requires TLS and its URI form usually omits sslmode.
        // Asserted on the parsed value rather than the rendered text, because
        // how Npgsql spells the keyword is its business, not this test's.
        var parsed = Parse(Normalize("postgresql://user:pass@db.example.com:5432/postgres"));

        Assert.Equal(SslMode.Require, parsed.SslMode);
    }

    [Fact]
    public void An_explicit_sslmode_in_the_uri_is_respected()
    {
        var parsed = Parse(Normalize(
            "postgresql://user:pass@db.example.com:5432/postgres?sslmode=disable"));

        Assert.Equal(SslMode.Disable, parsed.SslMode);
    }

    [Fact]
    public void A_missing_database_falls_back_to_postgres()
    {
        var parsed = Parse(Normalize("postgresql://user:pass@db.example.com:5432/"));

        Assert.Equal("postgres", parsed.Database);
    }

    [Fact]
    public void An_unrecognised_query_parameter_does_not_stop_the_app_starting()
    {
        // Providers append their own tracking parameters; refusing to start
        // over one would be a poor trade.
        var parsed = Parse(Normalize(
            "postgresql://user:pass@db.example.com:5432/postgres?pgbouncer=true&application_name=cafeops"));

        Assert.Equal("db.example.com", parsed.Host);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void An_empty_connection_string_names_the_setting_to_fix(string? value)
    {
        var exception = Assert.Throws<InvalidOperationException>(() => Normalize(value));

        Assert.Contains("Supabase:ConnectionString", exception.Message);
    }

    [Fact]
    public void A_malformed_value_explains_both_accepted_forms()
    {
        // The whole point: the replacement for "index 0".
        var exception = Assert.Throws<InvalidOperationException>(
            () => Normalize("this is not a connection string"));

        Assert.Contains("Host=", exception.Message);
        Assert.Contains("postgresql://", exception.Message);
    }
}
