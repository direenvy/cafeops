/// Data models.
///
/// Two JSON conventions meet in this app, so the constructors say which one
/// they expect:
///
///   * `fromSupabase` parses PostgREST rows, which are snake_case.
///   * `fromApi` parses the ASP.NET Core API, which is camelCase.
///
/// Hand-written rather than generated. At this size, codegen would add a build
/// step and a watch process for less code than it saves, and the parsing is
/// where the two naming conventions have to be made explicit anyway.
library;

/// What someone is allowed to do. Mirrors the `user_role` Postgres enum.
enum UserRole {
  staff,
  manager,
  owner;

  static UserRole parse(String? value) => switch (value) {
    'owner' => UserRole.owner,
    'manager' => UserRole.manager,
    _ => UserRole.staff,
  };

  bool get isManager => this == UserRole.manager || this == UserRole.owner;
  bool get isOwner => this == UserRole.owner;

  String get label => switch (this) {
    UserRole.owner => 'Owner',
    UserRole.manager => 'Manager',
    UserRole.staff => 'Staff',
  };
}

/// Where an order has got to. Mirrors the `order_status` Postgres enum.
enum OrderStatus {
  open,
  preparing,
  ready,
  served,
  paid,
  cancelled;

  static OrderStatus parse(String? value) => switch (value) {
    'preparing' => OrderStatus.preparing,
    'ready' => OrderStatus.ready,
    'served' => OrderStatus.served,
    'paid' => OrderStatus.paid,
    'cancelled' => OrderStatus.cancelled,
    _ => OrderStatus.open,
  };

  String get wire => name;

  String get label => switch (this) {
    OrderStatus.open => 'New',
    OrderStatus.preparing => 'Preparing',
    OrderStatus.ready => 'Ready',
    OrderStatus.served => 'Served',
    OrderStatus.paid => 'Paid',
    OrderStatus.cancelled => 'Cancelled',
  };

  bool get isFinal => this == OrderStatus.paid || this == OrderStatus.cancelled;
}

/// Where one line of an order has got to.
enum OrderItemStatus {
  queued,
  preparing,
  ready,
  served,
  cancelled;

  static OrderItemStatus parse(String? value) => switch (value) {
    'preparing' => OrderItemStatus.preparing,
    'ready' => OrderItemStatus.ready,
    'served' => OrderItemStatus.served,
    'cancelled' => OrderItemStatus.cancelled,
    _ => OrderItemStatus.queued,
  };

  String get wire => name;

  String get label => switch (this) {
    OrderItemStatus.queued => 'Queued',
    OrderItemStatus.preparing => 'Making',
    OrderItemStatus.ready => 'Ready',
    OrderItemStatus.served => 'Served',
    OrderItemStatus.cancelled => 'Cancelled',
  };

  /// The next state a barista would move this to, or null at the end.
  OrderItemStatus? get next => switch (this) {
    OrderItemStatus.queued => OrderItemStatus.preparing,
    OrderItemStatus.preparing => OrderItemStatus.ready,
    OrderItemStatus.ready => OrderItemStatus.served,
    _ => null,
  };
}

/// Why a stock balance moved. Mirrors the `stock_reason` Postgres enum.
enum StockReason {
  delivery,
  sale,
  waste,
  adjustment,
  stockCount,
  voided;

  /// The label Postgres stores. `void` is a Dart keyword, hence [voided].
  String get wire => switch (this) {
    StockReason.stockCount => 'stock_count',
    StockReason.voided => 'void',
    _ => name,
  };

  static StockReason parse(String? value) => switch (value) {
    'delivery' => StockReason.delivery,
    'sale' => StockReason.sale,
    'waste' => StockReason.waste,
    'stock_count' => StockReason.stockCount,
    'void' => StockReason.voided,
    _ => StockReason.adjustment,
  };

  String get label => switch (this) {
    StockReason.delivery => 'Delivery',
    StockReason.sale => 'Sale',
    StockReason.waste => 'Waste',
    StockReason.adjustment => 'Adjustment',
    StockReason.stockCount => 'Stock count',
    StockReason.voided => 'Returned (cancelled order)',
  };
}

/// Parses a Postgres numeric, which PostgREST may send as a string to avoid
/// losing precision in JSON. Treating it as a plain num would throw.
double _num(Object? value) => switch (value) {
  null => 0,
  final num n => n.toDouble(),
  final String s => double.tryParse(s) ?? 0,
  _ => 0,
};

DateTime _date(Object? value) =>
    value == null ? DateTime.now() : DateTime.parse(value as String).toLocal();

class Profile {
  const Profile({
    required this.id,
    required this.fullName,
    required this.role,
    required this.isActive,
  });

  final String id;
  final String fullName;
  final UserRole role;
  final bool isActive;

  factory Profile.fromSupabase(Map<String, dynamic> row) => Profile(
    id: row['id'] as String,
    fullName: (row['full_name'] as String?) ?? 'Unnamed',
    role: UserRole.parse(row['role'] as String?),
    isActive: (row['is_active'] as bool?) ?? true,
  );
}

class MenuCategory {
  const MenuCategory({
    required this.id,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String name;
  final int sortOrder;

  factory MenuCategory.fromSupabase(Map<String, dynamic> row) => MenuCategory(
    id: row['id'] as String,
    name: row['name'] as String,
    sortOrder: (row['sort_order'] as int?) ?? 0,
  );
}

class MenuItem {
  const MenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.price,
    required this.isAvailable,
    required this.sortOrder,
  });

  final String id;
  final String categoryId;
  final String name;
  final String? description;
  final double price;
  final bool isAvailable;
  final int sortOrder;

  factory MenuItem.fromSupabase(Map<String, dynamic> row) => MenuItem(
    id: row['id'] as String,
    categoryId: row['category_id'] as String,
    name: row['name'] as String,
    description: row['description'] as String?,
    price: _num(row['price']),
    isAvailable: (row['is_available'] as bool?) ?? true,
    sortOrder: (row['sort_order'] as int?) ?? 0,
  );
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.menuItemId,
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    required this.status,
    required this.note,
  });

  final String id;
  final String menuItemId;
  final String name;
  final int qty;
  final double unitPrice;
  final double lineTotal;
  final OrderItemStatus status;
  final String? note;

  factory OrderLine.fromSupabase(Map<String, dynamic> row) => OrderLine(
    id: row['id'] as String,
    menuItemId: row['menu_item_id'] as String,
    name: (row['name_snapshot'] as String?) ?? 'Item',
    qty: (row['qty'] as int?) ?? 1,
    unitPrice: _num(row['unit_price']),
    lineTotal: _num(row['line_total']),
    status: OrderItemStatus.parse(row['status'] as String?),
    note: row['note'] as String?,
  );
}

class CafeOrder {
  const CafeOrder({
    required this.id,
    required this.orderNumber,
    required this.tableLabel,
    required this.status,
    required this.note,
    required this.subtotal,
    required this.serviceCharge,
    required this.tax,
    required this.total,
    required this.createdAt,
    required this.lines,
    required this.placedByName,
  });

  final String id;
  final String orderNumber;
  final String tableLabel;
  final OrderStatus status;
  final String? note;
  final double subtotal;
  final double serviceCharge;
  final double tax;
  final double total;
  final DateTime createdAt;
  final List<OrderLine> lines;
  final String? placedByName;

  Duration get age => DateTime.now().difference(createdAt);

  int get readyCount =>
      lines.where((line) => line.status == OrderItemStatus.ready).length;

  int get activeLineCount =>
      lines.where((line) => line.status != OrderItemStatus.cancelled).length;

  bool get allLinesReady =>
      activeLineCount > 0 && readyCount == activeLineCount;

  /// Parses the nested select used by the board:
  /// `orders` joined to `order_items` and the placing profile.
  factory CafeOrder.fromSupabase(Map<String, dynamic> row) {
    final rawLines = (row['order_items'] as List<dynamic>?) ?? const [];
    final profile = row['profiles'] as Map<String, dynamic>?;

    final lines =
        rawLines
            .cast<Map<String, dynamic>>()
            .map(OrderLine.fromSupabase)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    return CafeOrder(
      id: row['id'] as String,
      orderNumber: (row['order_number'] as String?) ?? '',
      tableLabel: (row['table_label'] as String?) ?? '',
      status: OrderStatus.parse(row['status'] as String?),
      note: row['note'] as String?,
      subtotal: _num(row['subtotal']),
      serviceCharge: _num(row['service_charge']),
      tax: _num(row['tax']),
      total: _num(row['total']),
      createdAt: _date(row['created_at']),
      lines: lines,
      placedByName: profile?['full_name'] as String?,
    );
  }
}

class Ingredient {
  const Ingredient({
    required this.id,
    required this.name,
    required this.unit,
    required this.stockQty,
    required this.reorderLevel,
    required this.costPerUnit,
    required this.supplierId,
    required this.supplierName,
  });

  final String id;
  final String name;
  final String unit;
  final double stockQty;
  final double reorderLevel;
  final double costPerUnit;
  final String? supplierId;
  final String? supplierName;

  bool get isLow => stockQty <= reorderLevel;

  /// How full the shelf is relative to twice the reorder level, clamped for a
  /// progress bar. Twice the reorder level is a readable notion of "stocked".
  double get fullness {
    if (reorderLevel <= 0) {
      return stockQty > 0 ? 1 : 0;
    }
    return (stockQty / (reorderLevel * 2)).clamp(0, 1).toDouble();
  }

  factory Ingredient.fromSupabase(Map<String, dynamic> row) {
    final supplier = row['suppliers'] as Map<String, dynamic>?;

    return Ingredient(
      id: row['id'] as String,
      name: row['name'] as String,
      unit: (row['unit'] as String?) ?? '',
      stockQty: _num(row['stock_qty']),
      reorderLevel: _num(row['reorder_level']),
      costPerUnit: _num(row['cost_per_unit']),
      supplierId: row['supplier_id'] as String?,
      supplierName: supplier?['name'] as String?,
    );
  }
}

class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    required this.contactEmail,
  });

  final String id;
  final String name;
  final String? contactEmail;

  factory Supplier.fromSupabase(Map<String, dynamic> row) => Supplier(
    id: row['id'] as String,
    name: row['name'] as String,
    contactEmail: row['contact_email'] as String?,
  );
}

class StockMovement {
  const StockMovement({
    required this.id,
    required this.ingredientId,
    required this.ingredientName,
    required this.delta,
    required this.balanceAfter,
    required this.reason,
    required this.note,
    required this.createdByName,
    required this.createdAt,
  });

  final String id;
  final String ingredientId;
  final String ingredientName;
  final double delta;
  final double balanceAfter;
  final StockReason reason;
  final String? note;
  final String? createdByName;
  final DateTime createdAt;

  /// From the API, which sends camelCase and the enum as a camelCase string.
  factory StockMovement.fromApi(Map<String, dynamic> json) => StockMovement(
    id: json['id'] as String,
    ingredientId: json['ingredientId'] as String,
    ingredientName: (json['ingredientName'] as String?) ?? '',
    delta: _num(json['delta']),
    balanceAfter: _num(json['balanceAfter']),
    reason: _parseApiReason(json['reason'] as String?),
    note: json['note'] as String?,
    createdByName: json['createdByName'] as String?,
    createdAt: _date(json['createdAt']),
  );

  /// From PostgREST, which sends the raw Postgres label.
  factory StockMovement.fromSupabase(Map<String, dynamic> row) {
    final ingredient = row['ingredients'] as Map<String, dynamic>?;
    final profile = row['profiles'] as Map<String, dynamic>?;

    return StockMovement(
      id: row['id'] as String,
      ingredientId: row['ingredient_id'] as String,
      ingredientName: (ingredient?['name'] as String?) ?? '',
      delta: _num(row['delta']),
      balanceAfter: _num(row['balance_after']),
      reason: StockReason.parse(row['reason'] as String?),
      note: row['note'] as String?,
      createdByName: profile?['full_name'] as String?,
      createdAt: _date(row['created_at']),
    );
  }

  /// The API serialises enums as camelCase, so `stock_count` arrives as
  /// `stockCount` and `void` as `void`.
  static StockReason _parseApiReason(String? value) => switch (value) {
    'delivery' => StockReason.delivery,
    'sale' => StockReason.sale,
    'waste' => StockReason.waste,
    'stockCount' => StockReason.stockCount,
    'void' => StockReason.voided,
    _ => StockReason.adjustment,
  };
}

class DailySales {
  const DailySales({
    required this.businessDay,
    required this.ordersPaid,
    required this.total,
    required this.averageOrderValue,
  });

  final DateTime businessDay;
  final int ordersPaid;
  final double total;
  final double averageOrderValue;

  factory DailySales.fromApi(Map<String, dynamic> json) => DailySales(
    businessDay: DateTime.parse(json['businessDay'] as String),
    ordersPaid: (json['ordersPaid'] as int?) ?? 0,
    total: _num(json['total']),
    averageOrderValue: _num(json['averageOrderValue']),
  );
}

class ItemSales {
  const ItemSales({
    required this.name,
    required this.categoryName,
    required this.unitsSold,
    required this.revenue,
  });

  final String name;
  final String categoryName;
  final int unitsSold;
  final double revenue;

  factory ItemSales.fromApi(Map<String, dynamic> json) => ItemSales(
    name: (json['name'] as String?) ?? '',
    categoryName: (json['categoryName'] as String?) ?? '',
    unitsSold: (json['unitsSold'] as int?) ?? 0,
    revenue: _num(json['revenue']),
  );
}

class SalesSummary {
  const SalesSummary({
    required this.from,
    required this.to,
    required this.ordersPaid,
    required this.revenue,
    required this.averageOrderValue,
    required this.byDay,
    required this.topItems,
  });

  final DateTime from;
  final DateTime to;
  final int ordersPaid;
  final double revenue;
  final double averageOrderValue;
  final List<DailySales> byDay;
  final List<ItemSales> topItems;

  bool get isEmpty => ordersPaid == 0;

  factory SalesSummary.fromApi(Map<String, dynamic> json) => SalesSummary(
    from: DateTime.parse(json['from'] as String),
    to: DateTime.parse(json['to'] as String),
    ordersPaid: (json['ordersPaid'] as int?) ?? 0,
    revenue: _num(json['revenue']),
    averageOrderValue: _num(json['averageOrderValue']),
    byDay: ((json['byDay'] as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(DailySales.fromApi)
        .toList(),
    topItems: ((json['topItems'] as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ItemSales.fromApi)
        .toList(),
  );
}

/// A line in the till's cart, before the order is sent.
class CartLine {
  const CartLine({required this.item, required this.qty, this.note});

  final MenuItem item;
  final int qty;
  final String? note;

  double get lineTotal => item.price * qty;

  CartLine copyWith({int? qty, String? note}) =>
      CartLine(item: item, qty: qty ?? this.qty, note: note ?? this.note);
}
