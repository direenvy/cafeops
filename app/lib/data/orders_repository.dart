import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/api_client.dart';
import '../models/models.dart';

/// Reads and writes orders.
///
/// The split here is the architecture in miniature:
///
///   * Reads and the realtime subscription go straight to Supabase. The board
///     is driven by Postgres change events under row-level security, so a new
///     ticket appears on every screen without anything polling.
///   * Placing, paying for and cancelling an order go through the API, because
///     those move money and stock and the database refuses them from a client.
///   * Advancing a line's kitchen status goes straight to Supabase: it changes
///     nothing financial, and a guard trigger restricts a client to that one
///     column, so the round trip through the API would buy nothing.
class OrdersRepository {
  OrdersRepository(this._supabase, this._api);

  final SupabaseClient _supabase;
  final ApiClient _api;

  static const List<String> _activeStatuses = [
    'open',
    'preparing',
    'ready',
    'served',
  ];

  /// The nested select the board needs: each order with its lines and whoever
  /// rang it up. The `!orders_placed_by_fkey` hint names which foreign key to
  /// follow, since PostgREST cannot guess when a table is reachable more than
  /// one way.
  static const String _boardSelect = '''
    id, order_number, table_label, status, note,
    subtotal, service_charge, tax, total, created_at,
    order_items ( id, menu_item_id, name_snapshot, qty, unit_price, line_total, status, note ),
    profiles!orders_placed_by_fkey ( full_name )
  ''';

  Future<List<CafeOrder>> fetchBoard() async {
    final rows = await _supabase
        .from('orders')
        .select(_boardSelect)
        .inFilter('status', _activeStatuses)
        .order('created_at', ascending: true);

    return rows
        .cast<Map<String, dynamic>>()
        .map(CafeOrder.fromSupabase)
        .toList();
  }

  /// Live view of every order still in play.
  ///
  /// On a change event the whole board is re-read rather than the single
  /// changed row being patched in. That is a deliberate trade: a cafe has tens
  /// of open orders, not thousands, and re-reading cannot drift out of sync
  /// with the database the way incremental patching can. The 150ms debounce
  /// collapses the burst of events that one order's insert produces — the
  /// order, then each of its lines — into one fetch.
  Stream<List<CafeOrder>> watchBoard() {
    final controller = StreamController<List<CafeOrder>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> push() async {
      try {
        final board = await fetchBoard();
        if (!controller.isClosed) {
          controller.add(board);
        }
      } catch (error, stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
        }
      }
    }

    void schedule() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 150), push);
    }

    controller.onListen = () {
      push();

      channel = _supabase.channel('cafeops:board')
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          callback: (_) => schedule(),
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          callback: (_) => schedule(),
        )
        ..subscribe();
    };

    controller.onCancel = () async {
      debounce?.cancel();

      final open = channel;
      channel = null;

      if (open != null) {
        await _supabase.removeChannel(open);
      }

      await controller.close();
    };

    return controller.stream;
  }

  /// Moves one line along the kitchen flow.
  Future<void> setLineStatus(String lineId, OrderItemStatus status) async {
    await _supabase
        .from('order_items')
        .update({'status': status.wire})
        .eq('id', lineId);
  }

  /// Moves the whole order along. Managers only, enforced by RLS.
  Future<void> setOrderStatus(String orderId, OrderStatus status) async {
    await _supabase
        .from('orders')
        .update({'status': status.wire})
        .eq('id', orderId);
  }

  /// Sends a new order to the API, which prices and stock-checks it.
  ///
  /// Note what is not in this payload: no prices. The server looks every price
  /// up itself, so a tampered client cannot sell itself a discount.
  Future<PlacedOrderResult> placeOrder({
    required String tableLabel,
    required List<CartLine> cart,
    String? note,
  }) async {
    final response = await _api.postJson(
      '/api/orders',
      body: {
        'tableLabel': tableLabel,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'lines': [
          for (final line in cart)
            {
              'menuItemId': line.item.id,
              'qty': line.qty,
              if (line.note != null && line.note!.trim().isNotEmpty)
                'note': line.note!.trim(),
            },
        ],
      },
    );

    return PlacedOrderResult.fromApi(response);
  }

  Future<ReceiptResult> checkout(String orderId) async {
    final response = await _api.postJson('/api/orders/$orderId/checkout');
    return ReceiptResult.fromApi(response);
  }

  Future<void> cancel(String orderId, String reason) async {
    await _api.postJson(
      '/api/orders/$orderId/cancel',
      body: {'reason': reason},
    );
  }
}

/// What the API returns after an order is written.
class PlacedOrderResult {
  const PlacedOrderResult({
    required this.id,
    required this.orderNumber,
    required this.total,
  });

  final String id;
  final String orderNumber;
  final double total;

  factory PlacedOrderResult.fromApi(Map<String, dynamic> json) {
    final totals = json['totals'] as Map<String, dynamic>?;

    return PlacedOrderResult(
      id: json['id'] as String,
      orderNumber: (json['orderNumber'] as String?) ?? '',
      total: ((totals?['total'] ?? 0) as num).toDouble(),
    );
  }
}

/// What the API returns after an order is paid.
class ReceiptResult {
  const ReceiptResult({
    required this.orderNumber,
    required this.total,
    required this.servedBy,
  });

  final String orderNumber;
  final double total;
  final String servedBy;

  factory ReceiptResult.fromApi(Map<String, dynamic> json) {
    final totals = json['totals'] as Map<String, dynamic>?;

    return ReceiptResult(
      orderNumber: (json['orderNumber'] as String?) ?? '',
      total: ((totals?['total'] ?? 0) as num).toDouble(),
      servedBy: (json['servedBy'] as String?) ?? '',
    );
  }
}
