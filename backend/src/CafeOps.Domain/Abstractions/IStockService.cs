using CafeOps.Domain.Catalog;

namespace CafeOps.Domain.Abstractions;

/// <summary>One ingredient on an incoming delivery.</summary>
public sealed record DeliveryLine(Guid IngredientId, decimal Qty, decimal? UnitCost = null);

/// <summary>Goods arriving from a supplier.</summary>
public sealed record DeliveryRequest(
    Guid SupplierId,
    IReadOnlyList<DeliveryLine> Lines,
    string? Note = null);

/// <summary>A correction to a balance: waste, a stock count, or a fix.</summary>
public sealed record StockAdjustmentRequest(
    Guid IngredientId,
    decimal Delta,
    StockReason Reason,
    string? Note = null);

/// <summary>A single row of the stock ledger.</summary>
public sealed record StockMovement(
    Guid Id,
    Guid IngredientId,
    string IngredientName,
    decimal Delta,
    decimal BalanceAfter,
    StockReason Reason,
    string? Note,
    string? CreatedByName,
    DateTimeOffset CreatedAt);

/// <summary>
/// Writes to the stock ledger. Balances are only ever changed here, in the same
/// transaction as the movement that explains the change.
/// </summary>
public interface IStockService
{
    /// <summary>Books in a delivery and raises the affected balances.</summary>
    Task<Result<IReadOnlyList<StockMovement>>> ReceiveDeliveryAsync(
        DeliveryRequest request,
        Guid actorId,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Applies a manual correction. A <see cref="StockReason.StockCount"/>
    /// delta is treated as the counted balance rather than a difference.
    /// </summary>
    Task<Result<StockMovement>> AdjustAsync(
        StockAdjustmentRequest request,
        Guid actorId,
        CancellationToken cancellationToken = default);

    /// <summary>Ingredients at or below their reorder level.</summary>
    Task<IReadOnlyList<Ingredient>> GetLowStockAsync(
        CancellationToken cancellationToken = default);

    /// <summary>Recent ledger rows for one ingredient.</summary>
    Task<IReadOnlyList<StockMovement>> GetHistoryAsync(
        Guid ingredientId,
        int limit = 50,
        CancellationToken cancellationToken = default);
}
