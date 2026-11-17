using CafeOps.Domain;
using CafeOps.Domain.Abstractions;
using CafeOps.Domain.Catalog;
using CafeOps.Domain.Orders;
using CafeOps.Domain.Stock;
using CafeOps.Infrastructure.Database;
using Dapper;
using Microsoft.Extensions.Logging;

namespace CafeOps.Infrastructure.Orders;

/// <summary>
/// Writes orders, and the stock movements they cause, in single transactions.
/// </summary>
/// <remarks>
/// <para>
/// This is the reason the project has an ASP.NET Core service at all. Placing an
/// order is not one insert; it is: look up prices, work out what the recipes
/// consume, check the stock room can cover it, write the order, write its lines,
/// decrement every balance and append a ledger row for each. Either all of that
/// happens or none of it does.
/// </para>
/// <para>
/// A client could not be trusted with it even if it were simpler. The prices
/// come from the database, never the request; the stock check and the decrement
/// happen under a row lock so two tills cannot both sell the last of something;
/// and the database refuses these writes from a client outright
/// (<c>20261117000004_rls_policies.sql</c>).
/// </para>
/// </remarks>
public sealed class OrderService(
    IDbConnectionFactory connectionFactory,
    PricingPolicy pricingPolicy,
    ILogger<OrderService> logger) : IOrderService
{
    private readonly OrderPricer _pricer = new(pricingPolicy);

    public async Task<Result<PlacedOrder>> PlaceOrderAsync(
        NewOrderRequest request,
        Guid actorId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.Lines is null || request.Lines.Count == 0)
        {
            return DomainError.Validation("order.empty", "An order needs at least one item.");
        }

        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        var menuItemIds = request.Lines.Select(line => line.MenuItemId).Distinct().ToArray();

        var catalog = (await connection.QueryAsync<MenuItem>(new CommandDefinition(
                Sql.LoadMenuItems,
                new { ids = menuItemIds },
                transaction,
                cancellationToken: cancellationToken)))
            .ToDictionary(item => item.Id);

        // Price and validate in the domain, which knows nothing about Postgres.
        var pricing = _pricer.Price(request, catalog);
        if (!pricing.IsSuccess)
        {
            return Result<PlacedOrder>.Failure(pricing.Error!);
        }

        var priced = pricing.Value;

        var recipes = (await connection.QueryAsync<RecipeLine>(new CommandDefinition(
                Sql.LoadRecipes,
                new { ids = menuItemIds },
                transaction,
                cancellationToken: cancellationToken)))
            .ToArray();

        var requirements = StockMath.RequirementsFor(priced.Lines, recipes);

        if (requirements.Count > 0)
        {
            var ingredientIds = requirements.Select(r => r.IngredientId).ToArray();

            // FOR UPDATE, ordered by id. The lock is what makes the check and
            // the decrement one decision instead of two racing ones, and taking
            // the rows in a consistent order stops two concurrent orders that
            // share ingredients from deadlocking on each other.
            var ingredients = (await connection.QueryAsync<Ingredient>(new CommandDefinition(
                    Sql.LockIngredients,
                    new { ids = ingredientIds },
                    transaction,
                    cancellationToken: cancellationToken)))
                .ToDictionary(ingredient => ingredient.Id);

            var shortages = StockMath.ShortagesFor(requirements, ingredients);

            if (shortages.Count > 0)
            {
                // Rolling back is implicit: the transaction is disposed without
                // a commit, so nothing was written.
                var detail = new InsufficientStock(shortages).Describe();

                logger.LogInformation(
                    "Refused order for table {Table}: {Shortages}",
                    priced.TableLabel,
                    detail);

                return DomainError.Conflict("stock.insufficient", $"Not enough stock. {detail}");
            }
        }

        var header = await connection.QuerySingleAsync<OrderHeaderRow>(new CommandDefinition(
            Sql.InsertOrder,
            new
            {
                tableLabel = priced.TableLabel,
                note = priced.Note,
                subtotal = priced.Totals.Subtotal,
                serviceCharge = priced.Totals.ServiceCharge,
                tax = priced.Totals.Tax,
                total = priced.Totals.Total,
                placedBy = actorId,
            },
            transaction,
            cancellationToken: cancellationToken));

        await connection.ExecuteAsync(new CommandDefinition(
            Sql.InsertOrderItems,
            new
            {
                orderId = header.Id,
                menuItemIds = priced.Lines.Select(l => l.MenuItemId).ToArray(),
                names = priced.Lines.Select(l => l.NameSnapshot).ToArray(),
                quantities = priced.Lines.Select(l => l.Qty).ToArray(),
                unitPrices = priced.Lines.Select(l => l.UnitPrice).ToArray(),
                lineTotals = priced.Lines.Select(l => l.LineTotal).ToArray(),
                notes = priced.Lines.Select(l => l.Note).ToArray(),
            },
            transaction,
            cancellationToken: cancellationToken));

        if (requirements.Count > 0)
        {
            await connection.ExecuteAsync(new CommandDefinition(
                Sql.ApplySale,
                new
                {
                    orderId = header.Id,
                    actorId,
                    ingredientIds = requirements.Select(r => r.IngredientId).ToArray(),
                    quantities = requirements.Select(r => r.RequiredQty).ToArray(),
                },
                transaction,
                cancellationToken: cancellationToken));
        }

        await transaction.CommitAsync(cancellationToken);

        logger.LogInformation(
            "Order {OrderNumber} placed for table {Table}, total {Total}",
            header.OrderNumber,
            priced.TableLabel,
            priced.Totals.Total);

        return new PlacedOrder(
            Id: header.Id,
            OrderNumber: header.OrderNumber,
            TableLabel: priced.TableLabel,
            Status: header.Status,
            Totals: priced.Totals,
            Lines: priced.Lines,
            CreatedAt: header.CreatedAt.AsUtc());
    }

    public async Task<Result<Receipt>> CheckoutAsync(
        Guid orderId,
        Guid actorId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        var current = await connection.QuerySingleOrDefaultAsync<OrderStatus?>(new CommandDefinition(
            Sql.LockOrderStatus,
            new { id = orderId },
            transaction,
            cancellationToken: cancellationToken));

        if (current is null)
        {
            return DomainError.NotFound("order.not_found", $"Order {orderId} does not exist.");
        }

        if (current == OrderStatus.Paid)
        {
            // Idempotency matters here: a till that loses its connection after
            // the commit will retry, and the second attempt must not look like
            // a failure to the person holding the card machine.
            return DomainError.Conflict("order.already_paid", "This order has already been paid.");
        }

        if (current == OrderStatus.Cancelled)
        {
            return DomainError.Conflict("order.cancelled", "A cancelled order cannot be paid.");
        }

        var header = await connection.QuerySingleAsync<PaidOrderRow>(new CommandDefinition(
            Sql.MarkPaid,
            new { id = orderId },
            transaction,
            cancellationToken: cancellationToken));

        await connection.ExecuteAsync(new CommandDefinition(
            Sql.ServeRemainingItems,
            new { id = orderId },
            transaction,
            cancellationToken: cancellationToken));

        var lines = (await connection.QueryAsync<PricedLine>(new CommandDefinition(
                Sql.LoadOrderLines,
                new { id = orderId },
                transaction,
                cancellationToken: cancellationToken)))
            .ToArray();

        var servedBy = await connection.QuerySingleOrDefaultAsync<string>(new CommandDefinition(
            Sql.LoadProfileName,
            new { id = actorId },
            transaction,
            cancellationToken: cancellationToken));

        await transaction.CommitAsync(cancellationToken);

        logger.LogInformation("Order {OrderNumber} paid, total {Total}", header.OrderNumber, header.Total);

        return new Receipt(
            OrderId: header.Id,
            OrderNumber: header.OrderNumber,
            TableLabel: header.TableLabel,
            Totals: new OrderTotals(header.Subtotal, header.ServiceCharge, header.Tax, header.Total),
            Lines: lines,
            PaidAt: header.ClosedAt.AsUtc(),
            ServedBy: servedBy ?? "Unknown");
    }

    public async Task<Result<PlacedOrder>> CancelAsync(
        Guid orderId,
        string reason,
        Guid actorId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(reason))
        {
            return DomainError.Validation("order.cancel_reason_required",
                "Cancelling an order needs a reason, so the stock credit can be explained later.");
        }

        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        // The row lock here is what makes cancellation safe to retry: a second
        // attempt waits, then sees 'cancelled' and stops, so the ingredients are
        // never credited back twice.
        var current = await connection.QuerySingleOrDefaultAsync<OrderStatus?>(new CommandDefinition(
            Sql.LockOrderStatus,
            new { id = orderId },
            transaction,
            cancellationToken: cancellationToken));

        if (current is null)
        {
            return DomainError.NotFound("order.not_found", $"Order {orderId} does not exist.");
        }

        if (current == OrderStatus.Cancelled)
        {
            return DomainError.Conflict("order.already_cancelled", "This order is already cancelled.");
        }

        if (current == OrderStatus.Paid)
        {
            return DomainError.Conflict("order.already_paid",
                "A paid order cannot be cancelled. Record a refund instead.");
        }

        await connection.ExecuteAsync(new CommandDefinition(
            Sql.ReverseSale,
            new { orderId, actorId, note = reason.Trim() },
            transaction,
            cancellationToken: cancellationToken));

        var header = await connection.QuerySingleAsync<OrderHeaderRow>(new CommandDefinition(
            Sql.MarkCancelled,
            new { id = orderId },
            transaction,
            cancellationToken: cancellationToken));

        await connection.ExecuteAsync(new CommandDefinition(
            Sql.CancelRemainingItems,
            new { id = orderId },
            transaction,
            cancellationToken: cancellationToken));

        var lines = (await connection.QueryAsync<PricedLine>(new CommandDefinition(
                Sql.LoadOrderLines,
                new { id = orderId },
                transaction,
                cancellationToken: cancellationToken)))
            .ToArray();

        await transaction.CommitAsync(cancellationToken);

        logger.LogInformation(
            "Order {OrderNumber} cancelled ({Reason}); stock returned",
            header.OrderNumber,
            reason);

        return new PlacedOrder(
            Id: header.Id,
            OrderNumber: header.OrderNumber,
            TableLabel: header.TableLabel ?? string.Empty,
            Status: OrderStatus.Cancelled,
            Totals: OrderTotals.Zero,
            Lines: lines,
            CreatedAt: header.CreatedAt.AsUtc());
    }

    // Row shapes used only inside this class. Column aliases are lower-case and
    // unspaced so Dapper's case-insensitive matching binds them to the record
    // constructors without any extra configuration.
    // DateTime, not DateTimeOffset: Npgsql materialises timestamptz as a UTC
    // DateTime, and a record declaring DateTimeOffset gives Dapper no
    // constructor it can match. Converted at the boundary with AsUtc().
    private sealed record OrderHeaderRow(
        Guid Id,
        string OrderNumber,
        string? TableLabel,
        OrderStatus Status,
        DateTime CreatedAt);

    private sealed record PaidOrderRow(
        Guid Id,
        string OrderNumber,
        string TableLabel,
        decimal Subtotal,
        decimal ServiceCharge,
        decimal Tax,
        decimal Total,
        DateTime ClosedAt);

    private static class Sql
    {
        public const string LoadMenuItems = """
            select id,
                   name,
                   price,
                   is_available as isavailable
              from public.menu_items
             where id = any(@ids);
            """;

        public const string LoadRecipes = """
            select menu_item_id  as menuitemid,
                   ingredient_id as ingredientid,
                   qty_per_serving as qtyperserving
              from public.recipe_items
             where menu_item_id = any(@ids);
            """;

        public const string LockIngredients = """
            select id,
                   name,
                   unit,
                   stock_qty     as stockqty,
                   reorder_level as reorderlevel
              from public.ingredients
             where id = any(@ids)
             order by id
               for update;
            """;

        public const string InsertOrder = """
            insert into public.orders
                   (table_label, note, subtotal, service_charge, tax, total, placed_by, status)
            values (@tableLabel, @note, @subtotal, @serviceCharge, @tax, @total, @placedBy,
                    'open'::public.order_status)
            returning id,
                      order_number as ordernumber,
                      table_label  as tablelabel,
                      status,
                      created_at   as createdat;
            """;

        // unnest turns six parallel arrays into rows, so every line of the order
        // is written by one statement instead of one round trip per line.
        public const string InsertOrderItems = """
            insert into public.order_items
                   (order_id, menu_item_id, name_snapshot, qty, unit_price, line_total, note)
            select @orderId, t.menu_item_id, t.name_snapshot, t.qty, t.unit_price, t.line_total, t.note
              from unnest(@menuItemIds::uuid[],
                          @names::text[],
                          @quantities::int[],
                          @unitPrices::numeric[],
                          @lineTotals::numeric[],
                          @notes::text[])
                   as t(menu_item_id, name_snapshot, qty, unit_price, line_total, note);
            """;

        // One statement that decrements the balances and writes the matching
        // ledger rows, using the post-update balance returned by the UPDATE.
        // Splitting these would allow a balance to exist that no ledger row
        // explains.
        public const string ApplySale = """
            with req as (
                select * from unnest(@ingredientIds::uuid[], @quantities::numeric[])
                            as t(ingredient_id, required)
            ),
            upd as (
                update public.ingredients i
                   set stock_qty = i.stock_qty - r.required
                  from req r
                 where i.id = r.ingredient_id
                returning i.id, i.stock_qty
            )
            insert into public.stock_movements
                   (ingredient_id, delta, balance_after, reason, order_id, created_by)
            select u.id,
                   -r.required,
                   u.stock_qty,
                   'sale'::public.stock_reason,
                   @orderId,
                   @actorId
              from upd u
              join req r on r.ingredient_id = u.id;
            """;

        // Credits back exactly what this order took, read from the ledger rather
        // than recomputed from the recipes. Recipes may have changed since the
        // order was placed; the ledger is what actually happened.
        public const string ReverseSale = """
            with sold as (
                select ingredient_id, -sum(delta) as qty
                  from public.stock_movements
                 where order_id = @orderId
                   and reason = 'sale'::public.stock_reason
                 group by ingredient_id
                having -sum(delta) > 0
            ),
            upd as (
                update public.ingredients i
                   set stock_qty = i.stock_qty + s.qty
                  from sold s
                 where i.id = s.ingredient_id
                returning i.id, i.stock_qty
            )
            insert into public.stock_movements
                   (ingredient_id, delta, balance_after, reason, order_id, created_by, note)
            select u.id,
                   s.qty,
                   u.stock_qty,
                   'void'::public.stock_reason,
                   @orderId,
                   @actorId,
                   @note
              from upd u
              join sold s on s.ingredient_id = u.id;
            """;

        public const string LockOrderStatus = """
            select status from public.orders where id = @id for update;
            """;

        public const string MarkPaid = """
            update public.orders
               set status = 'paid'::public.order_status,
                   closed_at = now()
             where id = @id
            returning id,
                      order_number   as ordernumber,
                      table_label    as tablelabel,
                      subtotal,
                      service_charge as servicecharge,
                      tax,
                      total,
                      closed_at      as closedat;
            """;

        public const string MarkCancelled = """
            update public.orders
               set status = 'cancelled'::public.order_status,
                   closed_at = now()
             where id = @id
            returning id,
                      order_number as ordernumber,
                      table_label  as tablelabel,
                      status,
                      created_at   as createdat;
            """;

        public const string ServeRemainingItems = """
            update public.order_items
               set status = 'served'::public.order_item_status
             where order_id = @id
               and status not in ('served'::public.order_item_status,
                                  'cancelled'::public.order_item_status);
            """;

        public const string CancelRemainingItems = """
            update public.order_items
               set status = 'cancelled'::public.order_item_status
             where order_id = @id
               and status <> 'cancelled'::public.order_item_status;
            """;

        public const string LoadOrderLines = """
            select menu_item_id  as menuitemid,
                   name_snapshot as namesnapshot,
                   qty,
                   unit_price    as unitprice,
                   line_total    as linetotal,
                   note
              from public.order_items
             where order_id = @id
               and status <> 'cancelled'::public.order_item_status
             order by created_at;
            """;

        public const string LoadProfileName = """
            select full_name from public.profiles where id = @id;
            """;
    }
}
