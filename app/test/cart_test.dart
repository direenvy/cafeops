import 'package:cafeops/core/providers.dart';
import 'package:cafeops/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the till's cart.
///
/// The cart is where a mis-tap becomes a wrong order, so the merging and
/// decrement rules are worth pinning down. No widgets and no network here: the
/// notifier is plain state.
void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  CartNotifier notifier() => container.read(cartProvider.notifier);
  Cart cart() => container.read(cartProvider);

  const latte = MenuItem(
    id: 'latte',
    categoryId: 'espresso',
    name: 'Latte',
    description: null,
    price: 13.00,
    isAvailable: true,
    sortOrder: 1,
  );

  const croissant = MenuItem(
    id: 'croissant',
    categoryId: 'food',
    name: 'Butter Croissant',
    description: null,
    price: 8.50,
    isAvailable: true,
    sortOrder: 1,
  );

  test('starts empty and cannot be sent', () {
    expect(cart().isEmpty, isTrue);
    expect(cart().itemCount, 0);
    expect(cart().canSend, isFalse);
  });

  test('adding the same item twice makes one line of two', () {
    notifier()
      ..add(latte)
      ..add(latte);

    expect(cart().lines, hasLength(1));
    expect(cart().lines.single.qty, 2);
    expect(cart().itemCount, 2);
  });

  test('different items get their own lines', () {
    notifier()
      ..add(latte)
      ..add(croissant);

    expect(cart().lines, hasLength(2));
  });

  test('subtotal multiplies price by quantity across lines', () {
    notifier()
      ..add(latte)
      ..add(latte)
      ..add(croissant);

    expect(cart().subtotal, 34.50);
  });

  test('removing one decrements rather than clearing the line', () {
    notifier()
      ..add(latte)
      ..add(latte)
      ..removeOne(latte.id);

    expect(cart().lines.single.qty, 1);
  });

  test('removing the last one drops the line entirely', () {
    notifier()
      ..add(latte)
      ..removeOne(latte.id);

    expect(cart().lines, isEmpty);
  });

  test('removing an item that is not in the cart does nothing', () {
    notifier()
      ..add(latte)
      ..removeOne('not-in-cart');

    expect(cart().lines.single.qty, 1);
  });

  test('a cart with items still cannot be sent without a table', () {
    notifier().add(latte);

    expect(cart().canSend, isFalse);

    notifier().setTable('T4');

    expect(cart().canSend, isTrue);
  });

  test('whitespace is not a table', () {
    notifier()
      ..add(latte)
      ..setTable('   ');

    expect(cart().canSend, isFalse);
  });

  test('a line note is kept against the right line', () {
    notifier()
      ..add(latte)
      ..add(croissant)
      ..setLineNote(latte.id, 'oat milk');

    final lines = cart().lines;

    expect(lines.firstWhere((l) => l.item.id == latte.id).note, 'oat milk');
    expect(lines.firstWhere((l) => l.item.id == croissant.id).note, isNull);
  });

  test('clearing lines keeps the table, because the next order is often the same one', () {
    notifier()
      ..setTable('T9')
      ..add(latte)
      ..clearLines();

    expect(cart().lines, isEmpty);
    expect(cart().tableLabel, 'T9');
  });

  test('clearing everything also forgets the table', () {
    notifier()
      ..setTable('T9')
      ..add(latte)
      ..clearAll();

    expect(cart().tableLabel, isEmpty);
  });

  test('removeLine drops every unit of that item at once', () {
    notifier()
      ..add(latte)
      ..add(latte)
      ..add(latte)
      ..removeLine(latte.id);

    expect(cart().lines, isEmpty);
  });
}
