using CafeOps.Api.Auth;
using CafeOps.Domain.Abstractions;
using CafeOps.Domain.Catalog;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CafeOps.Api.Controllers;

/// <summary>
/// Stock movements. Balances change only through these endpoints.
/// </summary>
[ApiController]
[Route("api/stock")]
[Produces("application/json")]
public sealed class StockController(IStockService stock) : ControllerBase
{
    /// <summary>Books in a delivery from a supplier.</summary>
    [HttpPost("deliveries")]
    [Authorize(Policy = Policies.Manager)]
    [ProducesResponseType(typeof(IReadOnlyList<StockMovement>), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> ReceiveDelivery(
        [FromBody] DeliveryRequest request,
        CancellationToken cancellationToken)
    {
        var actorId = User.GetUserId();

        if (actorId is null)
        {
            return Unauthorized();
        }

        var result = await stock.ReceiveDeliveryAsync(request, actorId.Value, cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>
    /// Records waste, a correction, or the result of a physical stock count.
    /// </summary>
    [HttpPost("adjustments")]
    [Authorize(Policy = Policies.Manager)]
    [ProducesResponseType(typeof(StockMovement), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Adjust(
        [FromBody] StockAdjustmentRequest request,
        CancellationToken cancellationToken)
    {
        var actorId = User.GetUserId();

        if (actorId is null)
        {
            return Unauthorized();
        }

        var result = await stock.AdjustAsync(request, actorId.Value, cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Ingredients at or below their reorder level.</summary>
    [HttpGet("low")]
    [Authorize(Policy = Policies.Staff)]
    [ProducesResponseType(typeof(IReadOnlyList<Ingredient>), StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<Ingredient>>> LowStock(
        CancellationToken cancellationToken)
        => Ok(await stock.GetLowStockAsync(cancellationToken));

    /// <summary>The ledger for one ingredient, most recent first.</summary>
    [HttpGet("{ingredientId:guid}/history")]
    [Authorize(Policy = Policies.Manager)]
    [ProducesResponseType(typeof(IReadOnlyList<StockMovement>), StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<StockMovement>>> History(
        Guid ingredientId,
        [FromQuery] int limit = 50,
        CancellationToken cancellationToken = default)
        => Ok(await stock.GetHistoryAsync(ingredientId, limit, cancellationToken));
}
