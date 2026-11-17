using System.Security.Claims;
using CafeOps.Domain;
using CafeOps.Domain.Abstractions;
using CafeOps.Infrastructure.Configuration;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;

namespace CafeOps.Api.Auth;

/// <summary>Named authorization policies used by the controllers.</summary>
public static class Policies
{
    /// <summary>Any active member of staff.</summary>
    public const string Staff = "staff";

    /// <summary>Managers and owners.</summary>
    public const string Manager = "manager";

    /// <summary>Owners only.</summary>
    public const string Owner = "owner";
}

/// <summary>Requires the caller's profile to hold at least a given role.</summary>
public sealed class MinimumRoleRequirement(UserRole minimum) : IAuthorizationRequirement
{
    public UserRole Minimum { get; } = minimum;
}

/// <summary>
/// Decides role-based authorization by reading the caller's profile.
/// </summary>
/// <remarks>
/// The access token proves identity only; the role comes from the database.
/// That means a demotion takes effect within the directory's cache window
/// rather than when the token expires, and a deactivated account stops working
/// immediately.
/// </remarks>
public sealed class MinimumRoleHandler(IUserDirectory directory)
    : AuthorizationHandler<MinimumRoleRequirement>
{
    protected override async Task HandleRequirementAsync(
        AuthorizationHandlerContext context,
        MinimumRoleRequirement requirement)
    {
        var userId = context.User.GetUserId();

        if (userId is null)
        {
            return;
        }

        var profile = await directory.GetProfileAsync(userId.Value);

        if (profile is null || !profile.IsActive)
        {
            return;
        }

        if (Rank(profile.Role) >= Rank(requirement.Minimum))
        {
            context.Succeed(requirement);
        }
    }

    private static int Rank(UserRole role) => role switch
    {
        UserRole.Staff => 0,
        UserRole.Manager => 1,
        UserRole.Owner => 2,
        _ => -1,
    };
}

public static class CallerExtensions
{
    /// <summary>
    /// Reads the Supabase user id from the <c>sub</c> claim.
    /// </summary>
    public static Guid? GetUserId(this ClaimsPrincipal? principal)
    {
        var sub = principal?.FindFirst(ClaimTypes.NameIdentifier)?.Value
                  ?? principal?.FindFirst("sub")?.Value;

        return Guid.TryParse(sub, out var id) ? id : null;
    }
}

public static class AuthSetup
{
    /// <summary>
    /// Wires up bearer-token authentication against the Supabase project and
    /// the role policies the controllers use.
    /// </summary>
    public static IServiceCollection AddCafeOpsAuth(
        this IServiceCollection services,
        SupabaseOptions supabase)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(supabase);

        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                // Pointing at the authority lets the handler fetch the JWKS,
                // cache it, and pick the right key up after a rotation without
                // any code here knowing about key ids.
                options.Authority = supabase.Issuer;
                options.MetadataAddress = supabase.MetadataAddress;
                options.RequireHttpsMetadata = true;

                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidIssuer = supabase.Issuer,
                    ValidateAudience = true,
                    ValidAudience = supabase.Audience,
                    ValidateLifetime = true,
                    ValidateIssuerSigningKey = true,

                    // The default five minutes is generous for a till that is
                    // meant to reflect the current shift.
                    ClockSkew = TimeSpan.FromSeconds(30),

                    NameClaimType = "sub",
                };

                options.MapInboundClaims = false;
            });

        services.AddSingleton<IAuthorizationHandler, MinimumRoleHandler>();

        services.AddAuthorizationBuilder()
            .AddPolicy(Policies.Staff, policy => policy
                .RequireAuthenticatedUser()
                .AddRequirements(new MinimumRoleRequirement(UserRole.Staff)))
            .AddPolicy(Policies.Manager, policy => policy
                .RequireAuthenticatedUser()
                .AddRequirements(new MinimumRoleRequirement(UserRole.Manager)))
            .AddPolicy(Policies.Owner, policy => policy
                .RequireAuthenticatedUser()
                .AddRequirements(new MinimumRoleRequirement(UserRole.Owner)))
            // Nothing is reachable without a valid token unless a controller
            // opts out explicitly with [AllowAnonymous].
            .SetFallbackPolicy(new AuthorizationPolicyBuilder()
                .RequireAuthenticatedUser()
                .Build());

        return services;
    }
}
