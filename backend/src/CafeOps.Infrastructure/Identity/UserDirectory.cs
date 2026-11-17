using CafeOps.Domain.Abstractions;
using CafeOps.Infrastructure.Database;
using Dapper;
using Microsoft.Extensions.Caching.Memory;

namespace CafeOps.Infrastructure.Identity;

/// <summary>
/// Reads profiles from Postgres, with a short in-memory cache.
/// </summary>
/// <remarks>
/// <para>
/// Every authorized request needs the caller's role, so this would otherwise be
/// one extra query on every call. The cache window is deliberately short:
/// demoting someone should take effect in seconds, not when their token expires.
/// </para>
/// <para>
/// An in-process cache is the right size of solution here. It would need to
/// become a distributed cache only if the API ran as more than one instance and
/// the window mattered, and at that point the window should probably just be
/// shortened instead.
/// </para>
/// </remarks>
public sealed class UserDirectory(
    IDbConnectionFactory connectionFactory,
    IMemoryCache cache) : IUserDirectory
{
    private static readonly TimeSpan CacheWindow = TimeSpan.FromSeconds(30);

    public async Task<UserProfile?> GetProfileAsync(
        Guid userId,
        CancellationToken cancellationToken = default)
    {
        if (userId == Guid.Empty)
        {
            return null;
        }

        var key = $"profile:{userId}";

        if (cache.TryGetValue(key, out UserProfile? cached))
        {
            return cached;
        }

        await using var connection = await connectionFactory.OpenAsync(cancellationToken);

        var profile = await connection.QuerySingleOrDefaultAsync<UserProfile>(new CommandDefinition(
            """
            select id,
                   full_name as fullname,
                   role,
                   is_active as isactive
              from public.profiles
             where id = @id;
            """,
            new { id = userId },
            cancellationToken: cancellationToken));

        // A miss is cached too, briefly, so a flood of requests carrying a token
        // for a deleted user cannot turn into a flood of queries.
        cache.Set(key, profile, CacheWindow);

        return profile;
    }
}
