using CafeOps.Infrastructure.Database;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CafeOps.Api.Controllers;

/// <summary>Liveness and readiness, for the platform's health checks.</summary>
[ApiController]
[Route("api/health")]
[Produces("application/json")]
public sealed class HealthController(IDbConnectionFactory connectionFactory) : ControllerBase
{
    /// <summary>Confirms the process is up. Does not touch the database.</summary>
    [HttpGet]
    [AllowAnonymous]
    public ActionResult<object> Live() => Ok(new
    {
        status = "ok",
        service = "cafeops-api",
        utc = DateTimeOffset.UtcNow,
    });

    /// <summary>
    /// Confirms the database is reachable.
    /// </summary>
    /// <remarks>
    /// Kept separate from liveness on purpose: a platform that restarts the
    /// container when the database blips makes an outage worse rather than
    /// better.
    /// </remarks>
    [HttpGet("ready")]
    [AllowAnonymous]
    public async Task<ActionResult<object>> Ready(CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await connectionFactory.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = "select 1;";
            await command.ExecuteScalarAsync(cancellationToken);

            return Ok(new { status = "ready", database = "up" });
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new
            {
                status = "degraded",
                database = "unreachable",
            });
        }
    }
}
