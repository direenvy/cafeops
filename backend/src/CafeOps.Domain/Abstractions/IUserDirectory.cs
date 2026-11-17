namespace CafeOps.Domain.Abstractions;

/// <summary>The application's view of a signed-in person.</summary>
public sealed record UserProfile(
    Guid Id,
    string FullName,
    UserRole Role,
    bool IsActive);

/// <summary>
/// Looks up who a caller is, beyond what their access token says.
/// </summary>
/// <remarks>
/// A Supabase access token proves identity but carries no application role: the
/// role lives in <c>public.profiles</c>, where an owner can change it and have
/// that take effect without waiting for tokens to expire. The cost is a lookup
/// per request, which is why implementations cache it briefly.
/// </remarks>
public interface IUserDirectory
{
    Task<UserProfile?> GetProfileAsync(Guid userId, CancellationToken cancellationToken = default);
}
