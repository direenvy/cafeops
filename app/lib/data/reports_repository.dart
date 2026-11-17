import 'package:intl/intl.dart';

import '../core/api_client.dart';
import '../models/models.dart';

/// Sales reporting, served by the API.
///
/// These numbers aggregate across every member of staff's orders, which is
/// exactly what one person's row-level view should not be able to do, so they
/// are read from a manager-only endpoint rather than from Supabase directly.
class ReportsRepository {
  ReportsRepository(this._api);

  final ApiClient _api;

  static final DateFormat _isoDate = DateFormat('yyyy-MM-dd');

  Future<SalesSummary> fetchSales({
    required DateTime from,
    required DateTime to,
  }) async {
    final response = await _api.getJson(
      '/api/reports/sales',
      query: {'from': _isoDate.format(from), 'to': _isoDate.format(to)},
    );

    return SalesSummary.fromApi(response);
  }
}
