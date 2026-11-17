using CafeOps.Api.Auth;
using CafeOps.Domain.Abstractions;
using CafeOps.Domain.Orders;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CafeOps.Api.Controllers;

/// <summary>
/// The write side of orders.
/// </summary>
/// <remarks>
/// There is deliberately no GET here. Reading orders and watching the board go
/// straight from the Flutter client to Supabase, under row-level security, which
/// is what makes the board update in realtime. Only the operations the database
/// refuses to accept from a client live behind this controller.
/// </remarks>
[ApiController]
[Route("api/orders")]
[Produces("application/json")]
public sealed class OrdersController(IOrderService orders) : ControllerBase
{
    /// <summary>Places an order: prices it, checks stock, and writes it.</summary>
    /// <response code="200">The order was placed.</response>
    /// <response code="400">The request was malformed.</response>
    /// <response code="404">A menu item in the request does not exist.</response>
    /// <response code="409">An item is unavailable, or there is not enough stock.</response>
    [HttpPost]
    [Authorize(Policy = Policies.Staff)]
    [ProducesResponseType(typeof(PlacedOrder), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Place(
        [FromBody] NewOrderRequest request,
        CancellationToken cancellationToken)
    {
        var actorId = User.GetUserId();

        if (actorId is null)
        {
            return Unauthorized();
        }

        var result = await orders.PlaceOrderAsync(request, actorId.Value, cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Settles an order as paid and returns its receipt.</summary>
    [HttpPost("{orderId:guid}/checkout")]
    [Authorize(Policy = Policies.Manager)]
    [ProducesResponseType(typeof(Receipt), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Checkout(Guid orderId, CancellationToken cancellationToken)
    {
        var actorId = User.GetUserId();

        if (actorId is null)
        {
            return Unauthorized();
        }

        var result = await orders.CheckoutAsync(orderId, actorId.Value, cancellationToken);

        return result.ToActionResult(this);
    }

    /// <summary>Cancels an order and returns its ingredients to stock.</summary>
    [HttpPost("{orderId:guid}/cancel")]
    [Authorize(Policy = Policies.Manager)]
    [ProducesResponseType(typeof(PlacedOrder), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Cancel(
        Guid orderId,
        [FromBody] CancelOrderRequest request,
        CancellationToken cancellationToken)
    {
        var actorId = User.GetUserId();

        if (actorId is null)
        {
            return Unauthorized();
        }

        var result = await orders.CancelAsync(
            orderId,
            request?.Reason ?? string.Empty,
            actorId.Value,
            cancellationToken);

        return result.ToActionResult(this);
    }
}

/// <summary>Why an order is being cancelled. Required, so the stock credit can be explained.</summary>
public sealed record CancelOrderRequest(string Reason);
