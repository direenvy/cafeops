import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/api_client.dart';
import '../models/models.dart';

/// Stock levels, suppliers and the ledger.
///
/// Reads come from Supabase; anything that changes a balance goes through the
/// API, because a balance and the ledger row explaining it have to be written
/// together or not at all.
class InventoryRepository {
  InventoryRepository(this._supabase, this._api);

  final SupabaseClient _supabase;
  final ApiClient _api;

  Future<List<Ingredient>> fetchIngredients() async {
    final rows = await _supabase
        .from('ingredients')
        .select(
          'id, name, unit, stock_qty, reorder_level, cost_per_unit, supplier_id, '
          'suppliers ( name )',
        )
        .order('name');

    return rows
        .cast<Map<String, dynamic>>()
        .map(Ingredient.fromSupabase)
        .toList();
  }

  Future<List<Supplier>> fetchSuppliers() async {
    final rows = await _supabase
        .from('suppliers')
        .select('id, name, contact_email')
        .eq('is_active', true)
        .order('name');

    return rows
        .cast<Map<String, dynamic>>()
        .map(Supplier.fromSupabase)
        .toList();
  }

  /// Recent ledger rows for one ingredient.
  ///
  /// Read through Supabase, where RLS already limits the ledger to managers,
  /// rather than through the API: it is a plain read and needs no transaction.
  Future<List<StockMovement>> fetchHistory(
    String ingredientId, {
    int limit = 30,
  }) async {
    final rows = await _supabase
        .from('stock_movements')
        .select(
          'id, ingredient_id, delta, balance_after, reason, note, created_at, '
          'ingredients ( name ), profiles ( full_name )',
        )
        .eq('ingredient_id', ingredientId)
        .order('created_at', ascending: false)
        .limit(limit);

    return rows
        .cast<Map<String, dynamic>>()
        .map(StockMovement.fromSupabase)
        .toList();
  }

  /// Books in a delivery. Raises balances and writes one ledger row per line.
  Future<List<StockMovement>> receiveDelivery({
    required String supplierId,
    required List<DeliveryDraftLine> lines,
    String? note,
  }) async {
    final response = await _api.postList(
      '/api/stock/deliveries',
      body: {
        'supplierId': supplierId,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'lines': [
          for (final line in lines)
            {
              'ingredientId': line.ingredient.id,
              'qty': line.qty,
              if (line.unitCost != null) 'unitCost': line.unitCost,
            },
        ],
      },
    );

    return response
        .cast<Map<String, dynamic>>()
        .map(StockMovement.fromApi)
        .toList();
  }

  /// Records waste, a correction, or the result of a physical count.
  ///
  /// For [StockReason.stockCount] the server treats [quantity] as the counted
  /// balance, not a difference.
  Future<StockMovement> adjust({
    required String ingredientId,
    required double quantity,
    required StockReason reason,
    String? note,
  }) async {
    final response = await _api.postJson(
      '/api/stock/adjustments',
      body: {
        'ingredientId': ingredientId,
        'delta': quantity,
        'reason': _apiReason(reason),
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    );

    return StockMovement.fromApi(response);
  }

  /// The API deserialises its enums from camelCase.
  static String _apiReason(StockReason reason) => switch (reason) {
    StockReason.stockCount => 'stockCount',
    StockReason.voided => 'void',
    _ => reason.name,
  };
}

/// One line being entered on a delivery form.
class DeliveryDraftLine {
  const DeliveryDraftLine({
    required this.ingredient,
    required this.qty,
    this.unitCost,
  });

  final Ingredient ingredient;
  final double qty;
  final double? unitCost;
}
