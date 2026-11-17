using CafeOps.Domain;
using CafeOps.Domain.Abstractions;
using CafeOps.Domain.Catalog;
using CafeOps.Infrastructure.Database;
using Dapper;
using Microsoft.Extensions.Logging;

namespace CafeOps.Infrastructure.Stock;

/// <summary>
/// Writes the stock ledger. Every balance change and the row that explains it
/// are written by the same statement, so the two can never disagree.
/// </summary>
public sealed class StockService(
    IDbConnectionFactory connectionFactory,
    ILogger<StockService> logger) : IStockService
{
    public async Task<Result<IReadOnlyList<StockMovement>>> ReceiveDeliveryAsync(
        DeliveryRequest request,
        Guid actorId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.Lines is null || request.Lines.Count == 0)
        {
            return DomainError.Validation("delivery.empty", "A delivery needs at least one line.");
        }

        if (request.Lines.Any(line => line.Qty <= 0))
        {
            return DomainError.Validation(
                "delivery.qty_invalid",
                "Every delivery line needs a quantity above zero. Use an adjustment to reduce stock.");
        }

        // Two lines for the same ingredient are merged rather than rejected, so
        // a delivery note listing a product twice still books in correctly.
        var merged = request.Lines
            .GroupBy(line => line.IngredientId)
            .Select(group => new DeliveryLine(
                group.Key,
                group.Sum(line => line.Qty),
                group.Select(line => line.UnitCost).LastOrDefault(cost => cost is not null)))
            .ToArray();

        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        var supplierExists = await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
            Sql.SupplierExists,
            new { id = request.SupplierId },
            transaction,
            cancellationToken: cancellationToken));

        if (!supplierExists)
        {
            return DomainError.NotFound("supplier.not_found", "That supplier does not exist.");
        }

        var ids = merged.Select(line => line.IngredientId).ToArray();

        var known = (await connection.QueryAsync<Guid>(new CommandDefinition(
                Sql.LockIngredientIds,
                new { ids },
                transaction,
                cancellationToken: cancellationToken)))
            .ToHashSet();

        var unknown = ids.Where(id => !known.Contains(id)).ToArray();

        if (unknown.Length > 0)
        {
            return DomainError.NotFound(
                "ingredient.not_found",
                $"Unknown ingredient(s): {string.Join(", ", unknown)}.");
        }

        var movements = (await connection.QueryAsync<StockMovementRow>(new CommandDefinition(
                Sql.ApplyDelivery,
                new
                {
                    supplierId = request.SupplierId,
                    actorId,
                    note = string.IsNullOrWhiteSpace(request.Note) ? null : request.Note.Trim(),
                    ingredientIds = merged.Select(l => l.IngredientId).ToArray(),
                    quantities = merged.Select(l => l.Qty).ToArray(),
                    unitCosts = merged.Select(l => l.UnitCost).ToArray(),
                },
                transaction,
                cancellationToken: cancellationToken)))
            .ToArray();

        await transaction.CommitAsync(cancellationToken);

        logger.LogInformation(
            "Delivery booked in from supplier {SupplierId}: {Lines} line(s)",
            request.SupplierId,
            movements.Length);

        return movements.Select(Map).ToArray();
    }

    public async Task<Result<StockMovement>> AdjustAsync(
        StockAdjustmentRequest request,
        Guid actorId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.Reason is StockReason.Sale or StockReason.Void)
        {
            return DomainError.Validation(
                "stock.reason_not_manual",
                "Sale and void movements are written by the order flow, not by hand.");
        }

        if (request.Reason == StockReason.Waste && request.Delta >= 0)
        {
            return DomainError.Validation(
                "stock.waste_must_be_negative",
                "Waste reduces stock, so its quantity must be negative.");
        }

        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        var ingredient = await connection.QuerySingleOrDefaultAsync<Ingredient>(new CommandDefinition(
            Sql.LockIngredient,
            new { id = request.IngredientId },
            transaction,
            cancellationToken: cancellationToken));

        if (ingredient is null)
        {
            return DomainError.NotFound("ingredient.not_found", "That ingredient does not exist.");
        }

        // A stock count is an absolute statement about what is on the shelf, not
        // a difference. Treating the number as a delta here is an easy mistake
        // that silently doubles or wipes a balance.
        var delta = request.Reason == StockReason.StockCount
            ? request.Delta - ingredient.StockQty
            : request.Delta;

        if (delta == 0)
        {
            return DomainError.Conflict(
                "stock.no_change",
                request.Reason == StockReason.StockCount
                    ? $"The counted quantity already matches the recorded balance ({ingredient.StockQty}{ingredient.Unit})."
                    : "An adjustment of zero changes nothing.");
        }

        var balanceAfter = ingredient.StockQty + delta;

        if (balanceAfter < 0)
        {
            return DomainError.Conflict(
                "stock.would_go_negative",
                $"{ingredient.Name} would drop to {balanceAfter}{ingredient.Unit}. "
                + $"Only {ingredient.StockQty}{ingredient.Unit} is on hand.");
        }

        var row = await connection.QuerySingleAsync<StockMovementRow>(new CommandDefinition(
            Sql.ApplyAdjustment,
            new
            {
                ingredientId = request.IngredientId,
                delta,
                reason = request.Reason.ToPostgres(),
                note = string.IsNullOrWhiteSpace(request.Note) ? null : request.Note.Trim(),
                actorId,
            },
            transaction,
            cancellationToken: cancellationToken));

        await transaction.CommitAsync(cancellationToken);

        logger.LogInformation(
            "Stock adjusted: {Ingredient} {Delta:+0.###;-0.###} -> {Balance} ({Reason})",
            ingredient.Name,
            delta,
            balanceAfter,
            request.Reason);

        return Map(row);
    }

    public async Task<IReadOnlyList<Ingredient>> GetLowStockAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);

        var rows = await connection.QueryAsync<Ingredient>(new CommandDefinition(
            Sql.LowStock,
            cancellationToken: cancellationToken));

        return rows.ToArray();
    }

    public async Task<IReadOnlyList<StockMovement>> GetHistoryAsync(
        Guid ingredientId,
        int limit = 50,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);

        var rows = await connection.QueryAsync<StockMovementRow>(new CommandDefinition(
            Sql.History,
            new { id = ingredientId, limit = Math.Clamp(limit, 1, 500) },
            cancellationToken: cancellationToken));

        return rows.Select(Map).ToArray();
    }

    private static StockMovement Map(StockMovementRow row) => new(
        Id: row.Id,
        IngredientId: row.IngredientId,
        IngredientName: row.IngredientName ?? string.Empty,
        Delta: row.Delta,
        BalanceAfter: row.BalanceAfter,
        Reason: EnumNaming.FromPostgres<StockReason>(row.Reason),
        Note: row.Note,
        CreatedByName: row.CreatedByName,
        CreatedAt: row.CreatedAt);

    private sealed record StockMovementRow(
        Guid Id,
        Guid IngredientId,
        string? IngredientName,
        decimal Delta,
        decimal BalanceAfter,
        string Reason,
        string? Note,
        string? CreatedByName,
        DateTimeOffset CreatedAt);

    private static class Sql
    {
        public const string SupplierExists = """
            select exists (select 1 from public.suppliers where id = @id);
            """;

        public const string LockIngredientIds = """
            select id from public.ingredients where id = any(@ids) order by id for update;
            """;

        public const string LockIngredient = """
            select id,
                   name,
                   unit,
                   stock_qty     as stockqty,
                   reorder_level as reorderlevel
              from public.ingredients
             where id = @id
               for update;
            """;

        public const string ApplyDelivery = """
            with req as (
                select * from unnest(@ingredientIds::uuid[], @quantities::numeric[], @unitCosts::numeric[])
                            as t(ingredient_id, qty, unit_cost)
            ),
            upd as (
                update public.ingredients i
                   set stock_qty = i.stock_qty + r.qty,
                       -- Keep the costing current when the delivery states a
                       -- price, otherwise leave the last known one alone.
                       cost_per_unit = coalesce(r.unit_cost, i.cost_per_unit)
                  from req r
                 where i.id = r.ingredient_id
                returning i.id, i.name, i.stock_qty
            ),
            ins as (
                insert into public.stock_movements
                       (ingredient_id, delta, balance_after, reason, supplier_id, unit_cost, note, created_by)
                select u.id,
                       r.qty,
                       u.stock_qty,
                       'delivery'::public.stock_reason,
                       @supplierId,
                       r.unit_cost,
                       @note,
                       @actorId
                  from upd u
                  join req r on r.ingredient_id = u.id
                returning id, ingredient_id, delta, balance_after, reason, note, created_by, created_at
            )
            select ins.id,
                   ins.ingredient_id as ingredientid,
                   i.name            as ingredientname,
                   ins.delta,
                   ins.balance_after as balanceafter,
                   ins.reason::text  as reason,
                   ins.note,
                   p.full_name       as createdbyname,
                   ins.created_at    as createdat
              from ins
              join public.ingredients i on i.id = ins.ingredient_id
              left join public.profiles p on p.id = ins.created_by
             order by i.name;
            """;

        public const string ApplyAdjustment = """
            with upd as (
                update public.ingredients
                   set stock_qty = stock_qty + @delta
                 where id = @ingredientId
                returning id, name, stock_qty
            ),
            ins as (
                insert into public.stock_movements
                       (ingredient_id, delta, balance_after, reason, note, created_by)
                select upd.id,
                       @delta,
                       upd.stock_qty,
                       @reason::public.stock_reason,
                       @note,
                       @actorId
                  from upd
                returning id, ingredient_id, delta, balance_after, reason, note, created_by, created_at
            )
            select ins.id,
                   ins.ingredient_id as ingredientid,
                   i.name            as ingredientname,
                   ins.delta,
                   ins.balance_after as balanceafter,
                   ins.reason::text  as reason,
                   ins.note,
                   p.full_name       as createdbyname,
                   ins.created_at    as createdat
              from ins
              join public.ingredients i on i.id = ins.ingredient_id
              left join public.profiles p on p.id = ins.created_by;
            """;

        public const string LowStock = """
            select id,
                   name,
                   unit,
                   stock_qty     as stockqty,
                   reorder_level as reorderlevel
              from public.v_low_stock;
            """;

        public const string History = """
            select m.id,
                   m.ingredient_id as ingredientid,
                   i.name          as ingredientname,
                   m.delta,
                   m.balance_after as balanceafter,
                   m.reason::text  as reason,
                   m.note,
                   p.full_name     as createdbyname,
                   m.created_at    as createdat
              from public.stock_movements m
              join public.ingredients i on i.id = m.ingredient_id
              left join public.profiles p on p.id = m.created_by
             where m.ingredient_id = @id
             order by m.created_at desc
             limit @limit;
            """;
    }
}
