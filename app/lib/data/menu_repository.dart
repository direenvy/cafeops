import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';

/// The menu, as the till needs it.
class MenuRepository {
  MenuRepository(this._supabase);

  final SupabaseClient _supabase;

  /// Categories and their items in one pass.
  ///
  /// Two queries rather than one nested select: the till wants the categories
  /// in menu order even when a category is currently empty, which an inner
  /// join would drop.
  Future<Menu> fetchMenu() async {
    final categoryRows = await _supabase
        .from('menu_categories')
        .select('id, name, sort_order')
        .order('sort_order');

    final itemRows = await _supabase
        .from('menu_items')
        .select(
          'id, category_id, name, description, price, is_available, sort_order',
        )
        .order('sort_order');

    final categories = categoryRows
        .cast<Map<String, dynamic>>()
        .map(MenuCategory.fromSupabase)
        .toList();

    final items = itemRows
        .cast<Map<String, dynamic>>()
        .map(MenuItem.fromSupabase)
        .toList();

    return Menu(categories: categories, items: items);
  }

  /// Managers can take an item off the menu without deleting its history.
  Future<void> setAvailability(String menuItemId, bool isAvailable) async {
    await _supabase
        .from('menu_items')
        .update({'is_available': isAvailable})
        .eq('id', menuItemId);
  }
}

class Menu {
  const Menu({required this.categories, required this.items});

  final List<MenuCategory> categories;
  final List<MenuItem> items;

  List<MenuItem> itemsIn(String categoryId) =>
      items.where((item) => item.categoryId == categoryId).toList();

  bool get isEmpty => items.isEmpty;
}
