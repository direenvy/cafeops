using Npgsql;

namespace CafeOps.Infrastructure.Database;

/// <summary>
/// Accepts a Postgres connection string in either of the two forms in common
/// use, and hands back the one Npgsql understands.
/// </summary>
/// <remarks>
/// <para>
/// Npgsql wants ADO.NET key-value form — <c>Host=…;Username=…</c> — but almost
/// every hosting platform and database provider hands out a URI:
/// <c>postgresql://user:password@host:5432/database</c>. Supabase's dashboard
/// shows both, a few clicks apart.
/// </para>
/// <para>
/// Pasting the URI produces <c>Format of the initialization string does not
/// conform to specification starting at index 0</c>, which says nothing about
/// what is actually wrong or how to fix it. Since both forms carry exactly the
/// same information, refusing one of them is a choice to be unhelpful.
/// </para>
/// </remarks>
internal static class ConnectionStrings
{
    private static readonly string[] UriSchemes = ["postgres://", "postgresql://"];

    public static string Normalize(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException(
                "The Supabase connection string is empty. Set "
                + "Supabase:ConnectionString (or Supabase__ConnectionString as an "
                + "environment variable).");
        }

        var trimmed = value.Trim();

        var isUri = UriSchemes.Any(
            scheme => trimmed.StartsWith(scheme, StringComparison.OrdinalIgnoreCase));

        return isUri ? FromUri(trimmed) : Validate(trimmed);
    }

    /// <summary>
    /// Converts <c>postgresql://user:pass@host:port/db?sslmode=require</c> into
    /// Npgsql's keyword form.
    /// </summary>
    private static string FromUri(string value)
    {
        Uri uri;

        try
        {
            uri = new Uri(value);
        }
        catch (UriFormatException exception)
        {
            throw new InvalidOperationException(
                "The connection string looks like a URI but could not be parsed. "
                + "Expected postgresql://user:password@host:5432/database.",
                exception);
        }

        var credentials = uri.UserInfo.Split(':', 2);

        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = uri.Host,
            // A URI without an explicit port means the Postgres default, not
            // the scheme default, which for an unknown scheme is -1.
            Port = uri.Port > 0 ? uri.Port : 5432,
            Database = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/')),
            Username = Uri.UnescapeDataString(credentials[0]),
        };

        if (credentials.Length > 1)
        {
            // Percent-decoded: a password containing @ or / has to be encoded
            // in a URI, and passing the encoded form on would simply fail to
            // authenticate, with nothing to indicate why.
            builder.Password = Uri.UnescapeDataString(credentials[1]);
        }

        if (string.IsNullOrEmpty(builder.Database))
        {
            builder.Database = "postgres";
        }

        var specified = ApplyQueryString(builder, uri);

        // Supabase requires TLS and its URI form usually omits sslmode, so
        // default it on rather than failing to connect.
        //
        // Whether the URI said so is tracked explicitly, because
        // ContainsKey on a typed builder answers "is this a known keyword",
        // not "did anyone set it" — it returns true for every keyword that has
        // a default, so using it here silently skipped this block.
        if (!specified.Contains("sslmode"))
        {
            builder.SslMode = SslMode.Require;
            builder["Trust Server Certificate"] = true;
        }

        return builder.ToString();
    }

    /// <summary>
    /// Copies the URI's query parameters onto the builder, and reports which
    /// ones the caller actually specified.
    /// </summary>
    private static HashSet<string> ApplyQueryString(
        NpgsqlConnectionStringBuilder builder,
        Uri uri)
    {
        var specified = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        if (string.IsNullOrEmpty(uri.Query))
        {
            return specified;
        }

        foreach (var pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);

            if (parts.Length != 2)
            {
                continue;
            }

            var key = Uri.UnescapeDataString(parts[0]);
            var parameter = Uri.UnescapeDataString(parts[1]);

            try
            {
                builder[key] = parameter;
                // Spaces removed so "SSL Mode" and "sslmode" compare equal.
                specified.Add(key.Replace(" ", string.Empty));
            }
            catch (ArgumentException)
            {
                // An unrecognised query parameter is the provider's business,
                // not ours. Dropping it beats refusing to start over something
                // that may not even be a connection setting.
            }
        }

        return specified;
    }

    /// <summary>
    /// Checks keyword form early, so a malformed value fails with an
    /// explanation rather than Npgsql's "index 0" message.
    /// </summary>
    private static string Validate(string value)
    {
        try
        {
            _ = new NpgsqlConnectionStringBuilder(value);
            return value;
        }
        catch (ArgumentException exception)
        {
            throw new InvalidOperationException(
                "The Supabase connection string could not be parsed. Expected "
                + "either Npgsql keyword form "
                + "(Host=…;Port=5432;Database=postgres;Username=…;Password=…) "
                + "or a URI (postgresql://user:password@host:5432/database). "
                + "A password containing a semicolon will also break the keyword "
                + "form; reset it to one without.",
                exception);
        }
    }
}
