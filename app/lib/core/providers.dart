import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/inventory_repository.dart';
import '../data/menu_repository.dart';
import '../data/orders_repository.dart';
import '../data/reports_repository.dart';
import '../models/models.dart';
import 'api_client.dart';

/// Dependency wiring and shared state.
///
/// Repositories are plain classes that take their dependencies in a
/// constructor; Riverpod only decides when to build them. That keeps the data
/// layer testable without Riverpod in the picture at all.

// ---------------------------------------------------------------- foundations

final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(ref.watch(supabaseProvider));
  ref.onDispose(client.dispose);
  return client;
});

// --------------------------------------------------------------- repositories

final ordersRepositoryProvider = Provider<OrdersRepository>(
  (ref) => OrdersRepository(
    ref.watch(supabaseProvider),
    ref.watch(apiClientProvider),
  ),
);

final menuRepositoryProvider = Provider<MenuRepository>(
  (ref) => MenuRepository(ref.watch(supabaseProvider)),
);

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepository(
    ref.watch(supabaseProvider),
    ref.watch(apiClientProvider),
  ),
);

final reportsRepositoryProvider = Provider<ReportsRepository>(
  (ref) => ReportsRepository(ref.watch(apiClientProvider)),
);

// ----------------------------------------------------------------- identity

/// Emits on sign-in, sign-out and token refresh.
final authChangesProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

/// The signed-in user's profile, including the role the UI gates on.
///
/// Depends on [authChangesProvider] so that signing in or out rebuilds it
/// rather than leaving the previous user's role on screen.
final currentProfileProvider = FutureProvider<Profile?>((ref) async {
  ref.watch(authChangesProvider);

  final supabase = ref.watch(supabaseProvider);
  final userId = supabase.auth.currentUser?.id;

  if (userId == null) {
    return null;
  }

  final row = await supabase
      .from('profiles')
      .select('id, full_name, role, is_active')
      .eq('id', userId)
      .maybeSingle();

  return row == null ? null : Profile.fromSupabase(row);
});

// -------------------------------------------------------------------- orders

/// The live order board.
final boardProvider = StreamProvider<List<CafeOrder>>(
  (ref) => ref.watch(ordersRepositoryProvider).watchBoard(),
);

// ---------------------------------------------------------------------- menu

final menuProvider = FutureProvider<Menu>(
  (ref) => ref.watch(menuRepositoryProvider).fetchMenu(),
);

// ----------------------------------------------------------------- inventory

final ingredientsProvider = FutureProvider<List<Ingredient>>(
  (ref) => ref.watch(inventoryRepositoryProvider).fetchIngredients(),
);

final suppliersProvider = FutureProvider<List<Supplier>>(
  (ref) => ref.watch(inventoryRepositoryProvider).fetchSuppliers(),
);

final stockHistoryProvider = FutureProvider.family<List<StockMovement>, String>(
  (ref, ingredientId) =>
      ref.watch(inventoryRepositoryProvider).fetchHistory(ingredientId),
);

// ------------------------------------------------------------------- reports

/// The date range the reports page is showing.
class ReportRange {
  const ReportRange({required this.from, required this.to});

  final DateTime from;
  final DateTime to;

  /// Today and the six days before it.
  factory ReportRange.lastWeek() {
    final today = DateTime.now();
    return ReportRange(
      from: DateTime(
        today.year,
        today.month,
        today.day,
      ).subtract(const Duration(days: 6)),
      to: DateTime(today.year, today.month, today.day),
    );
  }

  factory ReportRange.today() {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    return ReportRange(from: day, to: day);
  }

  factory ReportRange.lastMonth() {
    final today = DateTime.now();
    return ReportRange(
      from: DateTime(
        today.year,
        today.month,
        today.day,
      ).subtract(const Duration(days: 29)),
      to: DateTime(today.year, today.month, today.day),
    );
  }

  int get days => to.difference(from).inDays + 1;

  @override
  bool operator ==(Object other) =>
      other is ReportRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

class ReportRangeNotifier extends Notifier<ReportRange> {
  @override
  ReportRange build() => ReportRange.lastWeek();

  void set(ReportRange range) => state = range;
}

final reportRangeProvider = NotifierProvider<ReportRangeNotifier, ReportRange>(
  ReportRangeNotifier.new,
);

final salesProvider = FutureProvider<SalesSummary>((ref) {
  final range = ref.watch(reportRangeProvider);
  return ref
      .watch(reportsRepositoryProvider)
      .fetchSales(from: range.from, to: range.to);
});

// ---------------------------------------------------------------------- cart

/// The till's current, unsent order.
class Cart {
  const Cart({this.tableLabel = '', this.lines = const [], this.note});

  final String tableLabel;
  final List<CartLine> lines;
  final String? note;

  bool get isEmpty => lines.isEmpty;

  int get itemCount => lines.fold(0, (sum, line) => sum + line.qty);

  /// Indicative subtotal only. The server recomputes every figure from its own
  /// prices; this exists so the counter can read a number out loud.
  double get subtotal => lines.fold(0, (sum, line) => sum + line.lineTotal);

  bool get canSend => lines.isNotEmpty && tableLabel.trim().isNotEmpty;

  Cart copyWith({String? tableLabel, List<CartLine>? lines, String? note}) =>
      Cart(
        tableLabel: tableLabel ?? this.tableLabel,
        lines: lines ?? this.lines,
        note: note ?? this.note,
      );
}

class CartNotifier extends Notifier<Cart> {
  @override
  Cart build() => const Cart();

  void setTable(String label) => state = state.copyWith(tableLabel: label);

  void setNote(String? note) => state = state.copyWith(note: note);

  /// Adds one of an item, merging with an existing line for the same item.
  void add(MenuItem item) {
    final index = state.lines.indexWhere((line) => line.item.id == item.id);
    final lines = [...state.lines];

    if (index == -1) {
      lines.add(CartLine(item: item, qty: 1));
    } else {
      lines[index] = lines[index].copyWith(qty: lines[index].qty + 1);
    }

    state = state.copyWith(lines: lines);
  }

  /// Removes one of an item, dropping the line when it reaches zero.
  void removeOne(String menuItemId) {
    final index = state.lines.indexWhere((line) => line.item.id == menuItemId);

    if (index == -1) {
      return;
    }

    final lines = [...state.lines];

    if (lines[index].qty <= 1) {
      lines.removeAt(index);
    } else {
      lines[index] = lines[index].copyWith(qty: lines[index].qty - 1);
    }

    state = state.copyWith(lines: lines);
  }

  void removeLine(String menuItemId) {
    state = state.copyWith(
      lines: state.lines.where((line) => line.item.id != menuItemId).toList(),
    );
  }

  void setLineNote(String menuItemId, String? note) {
    final lines = [
      for (final line in state.lines)
        if (line.item.id == menuItemId) line.copyWith(note: note) else line,
    ];

    state = state.copyWith(lines: lines);
  }

  int qtyOf(String menuItemId) => state.lines
      .where((line) => line.item.id == menuItemId)
      .fold(0, (sum, line) => sum + line.qty);

  /// Clears the lines but keeps the table, since a counter usually rings up
  /// several orders for the same table in a row.
  void clearLines() => state = Cart(tableLabel: state.tableLabel);

  void clearAll() => state = const Cart();
}

final cartProvider = NotifierProvider<CartNotifier, Cart>(CartNotifier.new);
