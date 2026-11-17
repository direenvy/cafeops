using System.ComponentModel.DataAnnotations;

namespace CafeOps.Infrastructure.Configuration;

/// <summary>
/// Everything the API needs to talk to Supabase.
/// </summary>
/// <remarks>
/// None of these have defaults and none are committed. They are supplied by
/// user-secrets in development and by environment variables in production; the
/// API refuses to start without them rather than falling back to something that
/// half-works (see <c>Program.cs</c>).
/// </remarks>
public sealed class SupabaseOptions
{
    public const string SectionName = "Supabase";

    /// <summary>
    /// Postgres connection string for the project, using the session pooler.
    /// </summary>
    /// <remarks>
    /// The API connects as a database role that bypasses RLS, which is exactly
    /// why only the API may perform the writes the client is refused. Treat this
    /// string as a production credential.
    /// </remarks>
    [Required(AllowEmptyStrings = false)]
    public string ConnectionString { get; init; } = string.Empty;

    /// <summary>Project base URL, e.g. <c>https://abcdefgh.supabase.co</c>.</summary>
    [Required(AllowEmptyStrings = false)]
    [Url]
    public string ProjectUrl { get; init; } = string.Empty;

    /// <summary>
    /// Audience claim Supabase puts on a signed-in user's access token.
    /// </summary>
    public string Audience { get; init; } = "authenticated";

    /// <summary>
    /// Token issuer, which doubles as the OIDC authority.
    /// </summary>
    /// <remarks>
    /// This project signs access tokens with ES256 and publishes the public key
    /// at <c>{Issuer}/.well-known/jwks.json</c>, so the API validates signatures
    /// against that key set and never holds a shared secret at all. Verified
    /// against the live project rather than assumed: the older symmetric
    /// JWT-secret approach would reject every real token here.
    /// </remarks>
    public string Issuer => $"{ProjectUrl.TrimEnd('/')}/auth/v1";

    /// <summary>OIDC discovery document, from which the JWKS URI is read.</summary>
    public string MetadataAddress => $"{Issuer}/.well-known/openid-configuration";
}
