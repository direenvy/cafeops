import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatting.dart';
import '../../core/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// Sales reporting for managers.
///
/// Every figure here is computed by Postgres and served by the manager-only
/// reports endpoint. The client does no aggregation of its own, so the numbers
/// on screen are the numbers in the database rather than a second
/// implementation that can drift from it.
class ReportsPage extends ConsumerWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(salesProvider);
    final range = ref.watch(reportRangeProvider);

    return Column(
      children: [
        _RangeBar(range: range),
        const Divider(height: 1),
        Expanded(
          child: AsyncView<SalesSummary>(
            value: sales,
            onRetry: () => ref.invalidate(salesProvider),
            builder: (summary) => RefreshIndicator(
              onRefresh: () async => ref.invalidate(salesProvider),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _Headline(summary: summary),
                  const SizedBox(height: 24),
                  if (summary.isEmpty)
                    const EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: 'No paid orders in this period',
                      message:
                          'Ring up an order on the till and take payment on '
                          'the board, and it will show here.',
                    )
                  else ...[
                    const SectionHeader(title: 'Revenue by day'),
                    _DailyChart(days: summary.byDay),
                    const SizedBox(height: 28),
                    const SectionHeader(title: 'Best sellers'),
                    _TopItems(items: summary.topItems),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RangeBar extends ConsumerWidget {
  const _RangeBar({required this.range});

  final ReportRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(reportRangeProvider.notifier);

    final options = <String, ReportRange>{
      'Today': ReportRange.today(),
      'Last 7 days': ReportRange.lastWeek(),
      'Last 30 days': ReportRange.lastMonth(),
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          for (final entry in options.entries) ...[
            ChoiceChip(
              label: Text(entry.key),
              selected: range == entry.value,
              onSelected: (_) => notifier.set(entry.value),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.summary});

  final SalesSummary summary;

  @override
  Widget build(BuildContext context) {
    final cards = [
      _StatCard(
        label: 'Revenue',
        value: formatMoney(summary.revenue),
        icon: Icons.payments_outlined,
      ),
      _StatCard(
        label: 'Orders paid',
        value: '${summary.ordersPaid}',
        icon: Icons.receipt_outlined,
      ),
      _StatCard(
        label: 'Average order',
        value: formatMoney(summary.averageOrderValue),
        icon: Icons.insights_outlined,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Side by side when there is room, stacked when there is not, rather
        // than squeezing three cards into a phone width.
        final isWide = constraints.maxWidth >= 560;

        if (isWide) {
          return Row(
            children: [
              for (final card in cards) ...[
                Expanded(child: card),
                if (card != cards.last) const SizedBox(width: 12),
              ],
            ],
          );
        }

        return Column(
          children: [
            for (final card in cards) ...[
              card,
              if (card != cards.last) const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: scheme.onPrimaryContainer, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain bar chart, drawn with layout rather than a charting package.
///
/// One series of at most thirty values does not justify a dependency, and
/// building it here keeps the bars on the app's own colour scheme in both
/// light and dark.
class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.days});

  final List<DailySales> days;

  static const double _chartHeight = 180;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (days.isEmpty) {
      return const SizedBox.shrink();
    }

    final peak = days
        .map((day) => day.total)
        .fold<double>(0, (max, value) => value > max ? value : max);

    // Every bar would be full height if the peak were zero, which would read as
    // a busy day rather than an empty one.
    final safePeak = peak <= 0 ? 1.0 : peak;

    final busiest = days.reduce((a, b) => a.total >= b.total ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Peak ${formatMoney(peak)} on ${formatDay(busiest.businessDay)}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: _chartHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final day in days)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Tooltip(
                          message:
                              '${formatDay(day.businessDay)}\n'
                              '${formatMoney(day.total)} · '
                              '${day.ordersPaid} order'
                              '${day.ordersPaid == 1 ? '' : 's'}',
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // A floor of 2px keeps a zero-revenue day visible
                              // as a day rather than a gap.
                              Container(
                                height: (day.total / safePeak * 140)
                                    .clamp(2, 140)
                                    .toDouble(),
                                decoration: BoxDecoration(
                                  color: day == busiest
                                      ? scheme.primary
                                      : scheme.primary.withValues(alpha: 0.45),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              // Labels are dropped rather than overlapped once
                              // the bars get narrow.
                              if (days.length <= 10)
                                Text(
                                  formatDay(day.businessDay),
                                  style: const TextStyle(fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (days.length > 10)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      formatDay(days.first.businessDay),
                      style: const TextStyle(fontSize: 10),
                    ),
                    Text(
                      formatDay(days.last.businessDay),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopItems extends StatelessWidget {
  const _TopItems({required this.items});

  final List<ItemSales> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final best = items.first.revenue;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          formatMoney(item.revenue),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: best <= 0 ? 0 : item.revenue / best,
                              minHeight: 5,
                              backgroundColor: scheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${item.unitsSold} sold · ${item.categoryName}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
