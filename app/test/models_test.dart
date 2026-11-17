import 'package:cafeops/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the parsing boundary.
///
/// Two wire formats meet in this app — PostgREST's snake_case and the API's
/// camelCase — and Postgres sends `numeric` as a JSON string to avoid losing
/// precision. Both are easy to get wrong in a way that only shows up as a zero
/// on screen, so they are pinned here.
void main() {
  group('numeric parsing', () {
    test('reads a numeric sent as a string', () {
      final ingredient = Ingredient.fromSupabase({
        'id': 'i1',
        'name': 'Fresh milk',
        'unit': 'ml',
        // PostgREST sends numeric as a string.
        'stock_qty': '24000.500',
        'reorder_level': '8000.000',
        'cost_per_unit': '0.0062',
        'supplier_id': null,
      });

      expect(ingredient.stockQty, 24000.5);
      expect(ingredient.reorderLevel, 8000);
    });

    test('reads a numeric sent as a number', () {
      final ingredient = Ingredient.fromSupabase({
        'id': 'i1',
        'name': 'Ice',
        'unit': 'g',
        'stock_qty': 20000,
        'reorder_level': 5000,
        'cost_per_unit': 0.0008,
        'supplier_id': null,
      });

      expect(ingredient.stockQty, 20000);
    });

    test('a missing numeric reads as zero rather than throwing', () {
      final ingredient = Ingredient.fromSupabase({
        'id': 'i1',
        'name': 'Sugar',
        'unit': 'g',
        'supplier_id': null,
      });

      expect(ingredient.stockQty, 0);
    });
  });

  group('low stock', () {
    test('at the reorder level counts as low', () {
      // The boundary matters: "at or below" is what the database view uses, and
      // the two must agree or the banner disagrees with the list.
      final ingredient = Ingredient.fromSupabase({
        'id': 'i1',
        'name': 'Bagel',
        'unit': 'pc',
        'stock_qty': 10,
        'reorder_level': 10,
        'cost_per_unit': 1.9,
        'supplier_id': null,
      });

      expect(ingredient.isLow, isTrue);
    });

    test('above the reorder level is not low', () {
      final ingredient = Ingredient.fromSupabase({
        'id': 'i1',
        'name': 'Bagel',
        'unit': 'pc',
        'stock_qty': 11,
        'reorder_level': 10,
        'cost_per_unit': 1.9,
        'supplier_id': null,
      });

      expect(ingredient.isLow, isFalse);
    });

    test(
      'fullness is clamped so a well-stocked item does not overflow a bar',
      () {
        final ingredient = Ingredient.fromSupabase({
          'id': 'i1',
          'name': 'Ice',
          'unit': 'g',
          'stock_qty': 100000,
          'reorder_level': 10,
          'cost_per_unit': 0,
          'supplier_id': null,
        });

        expect(ingredient.fullness, 1.0);
      },
    );

    test('an item with no reorder level does not divide by zero', () {
      final ingredient = Ingredient.fromSupabase({
        'id': 'i1',
        'name': 'Napkins',
        'unit': 'pc',
        'stock_qty': 5,
        'reorder_level': 0,
        'cost_per_unit': 0,
        'supplier_id': null,
      });

      expect(ingredient.fullness, 1.0);
      expect(ingredient.isLow, isFalse);
    });
  });

  group('enum labels', () {
    test('stock reasons use the Postgres label on the wire', () {
      expect(StockReason.stockCount.wire, 'stock_count');
      // `void` is a Dart keyword, so the member is named differently from the
      // label it has to send.
      expect(StockReason.voided.wire, 'void');
      expect(StockReason.sale.wire, 'sale');
    });

    test('stock reasons parse back from the Postgres label', () {
      expect(StockReason.parse('stock_count'), StockReason.stockCount);
      expect(StockReason.parse('void'), StockReason.voided);
    });

    test('an unknown role falls back to the least privileged', () {
      // Failing open here would hand someone a manager's screens.
      expect(UserRole.parse('superuser'), UserRole.staff);
      expect(UserRole.parse(null), UserRole.staff);
    });

    test('roles rank correctly', () {
      expect(UserRole.owner.isManager, isTrue);
      expect(UserRole.manager.isManager, isTrue);
      expect(UserRole.staff.isManager, isFalse);
      expect(UserRole.manager.isOwner, isFalse);
    });

    test('the kitchen flow advances and then stops', () {
      expect(OrderItemStatus.queued.next, OrderItemStatus.preparing);
      expect(OrderItemStatus.preparing.next, OrderItemStatus.ready);
      expect(OrderItemStatus.ready.next, OrderItemStatus.served);
      expect(OrderItemStatus.served.next, isNull);
      expect(OrderItemStatus.cancelled.next, isNull);
    });
  });

  group('order parsing', () {
    Map<String, dynamic> orderRow({
      required List<Map<String, dynamic>> items,
    }) => {
      'id': 'o1',
      'order_number': '20261117-001',
      'table_label': 'T4',
      'status': 'preparing',
      'note': null,
      'subtotal': '21.50',
      'service_charge': '2.15',
      'tax': '1.42',
      'total': '25.07',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'order_items': items,
      'profiles': {'full_name': 'Aisha'},
    };

    Map<String, dynamic> line(String status) => {
      'id': 'l-$status',
      'menu_item_id': 'm1',
      'name_snapshot': 'Latte',
      'qty': 1,
      'unit_price': '13.00',
      'line_total': '13.00',
      'status': status,
      'note': null,
    };

    test('reads the nested lines and the placing staff member', () {
      final order = CafeOrder.fromSupabase(
        orderRow(items: [line('ready'), line('queued')]),
      );

      expect(order.lines, hasLength(2));
      expect(order.placedByName, 'Aisha');
      expect(order.status, OrderStatus.preparing);
      expect(order.total, 25.07);
    });

    test('all lines ready is only true when every active line is ready', () {
      final mixed = CafeOrder.fromSupabase(
        orderRow(items: [line('ready'), line('queued')]),
      );
      expect(mixed.allLinesReady, isFalse);

      final allReady = CafeOrder.fromSupabase(
        orderRow(items: [line('ready'), line('ready')]),
      );
      expect(allReady.allLinesReady, isTrue);
    });

    test('a cancelled line does not hold the order back', () {
      // Otherwise an order with one cancelled line could never read as ready.
      final order = CafeOrder.fromSupabase(
        orderRow(items: [line('ready'), line('cancelled')]),
      );

      expect(order.activeLineCount, 1);
      expect(order.allLinesReady, isTrue);
    });

    test('an order with no lines is not ready', () {
      final order = CafeOrder.fromSupabase(orderRow(items: []));

      expect(order.allLinesReady, isFalse);
    });

    test('an unknown status falls back to open', () {
      final order = CafeOrder.fromSupabase({
        ...orderRow(items: []),
        'status': 'teleported',
      });

      expect(order.status, OrderStatus.open);
    });
  });
}
