import 'package:intl/intl.dart';

import 'env.dart';

/// Shared formatters.
///
/// Built once as top-level finals rather than per build() call: constructing a
/// NumberFormat parses a pattern each time, and these run inside list builders.
final NumberFormat _money = NumberFormat.currency(
  symbol: '${Env.currencySymbol} ',
  decimalDigits: 2,
);

final NumberFormat _quantity = NumberFormat('#,##0.###');
final DateFormat _timeOfDay = DateFormat('HH:mm');
final DateFormat _dayAndMonth = DateFormat('d MMM');
final DateFormat _fullStamp = DateFormat('d MMM yyyy, HH:mm');

String formatMoney(num amount) => _money.format(amount);

/// Formats a stock quantity with its unit, trimming pointless decimals.
String formatQuantity(num quantity, String unit) =>
    '${_quantity.format(quantity)}$unit';

String formatTime(DateTime when) => _timeOfDay.format(when.toLocal());

String formatDay(DateTime when) => _dayAndMonth.format(when.toLocal());

String formatStamp(DateTime when) => _fullStamp.format(when.toLocal());

/// Renders how long an order has been waiting, for the board.
///
/// Deliberately coarse: a kitchen cares whether a ticket is two minutes or
/// twenty old, not whether it is 127 seconds.
String formatAge(Duration age) {
  if (age.inSeconds < 60) {
    return 'just now';
  }
  if (age.inMinutes < 60) {
    return '${age.inMinutes}m';
  }
  final hours = age.inHours;
  final minutes = age.inMinutes.remainder(60);
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

/// Turns an API error code into something a person can act on.
///
/// The API returns stable codes (`stock.insufficient`) alongside its English
/// message. Mapping the ones worth rewording keeps the UI useful without
/// hiding the detail the server sent.
String humanizeErrorCode(String? code, String fallback) {
  switch (code) {
    case 'stock.insufficient':
      return fallback; // Already lists exactly what is short.
    case 'menu_item.unavailable':
      return 'That item is marked unavailable.';
    case 'order.already_paid':
      return 'This order has already been paid.';
    case 'order.already_cancelled':
      return 'This order is already cancelled.';
    case 'order.empty':
      return 'Add at least one item first.';
    case 'order.table_required':
      return 'Enter a table before sending the order.';
    default:
      return fallback;
  }
}
