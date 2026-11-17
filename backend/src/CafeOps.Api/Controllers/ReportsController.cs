using CafeOps.Api.Auth;
using CafeOps.Domain.Abstractions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CafeOps.Api.Controllers;

/// <summary>
/// Sales reporting.
/// </summary>
/// <remarks>
/// Reports aggregate across every order, which is precisely what a single
/// member of staff's row-level view should not be able to do. Keeping them
/// behind a manager-only endpoint means the aggregate never has to be
/// reachable by the client's own database credentials.
/// </remarks>
[ApiController]
[Route("api/reports")]
[Produces("application/json")]
public sealed class ReportsController(IReportService reports) : ControllerBase
{
    /// <summary>
    /// Takings between two dates, inclusive, in the shop's own timezone.
    /// </summary>
    /// <param name="from">First business day. Defaults to 7 days ago.</param>
    /// <param name="to">Last business day. Defaults to today.</param>
    [HttpGet("sales")]
    [Authorize(Policy = Policies.Manager)]
    [ProducesResponseType(typeof(SalesSummary), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<SalesSummary>> Sales(
        [FromQuery] DateOnly? from,
        [FromQuery] DateOnly? to,
        CancellationToken cancellationToken)
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var start = from ?? today.AddDays(-7);
        var end = to ?? today;

        try
        {
            return Ok(await reports.GetSalesSummaryAsync(start, end, cancellationToken));
        }
        catch (ArgumentOutOfRangeException exception)
        {
            // The only expected rejection: a range so wide it would scan the
            // whole table. Surfaced as a 400 rather than a 500.
            return ValidationProblem(exception.Message);
        }
    }
}
