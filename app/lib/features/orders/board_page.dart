import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/formatting.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// The kitchen board: every order still in play, updating live.
///
/// Nothing here polls. The stream behind [boardProvider] is driven by Postgres
/// change events over a websocket, so a ticket rung up at the till appears on
/// the barista's screen in the same moment.
class BoardPage extends ConsumerStatefulWidget {
  const BoardPage({super.key});

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();

    // The ages on the cards have to move even when no data changes. Twenty
    // seconds is often enough for a display measured in minutes, and cheap
    // enough not to matter.
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(boardProvider);
    final profile = ref.watch(currentProfileProvider).value;
    final isManager = profile?.role.isManager ?? false;

    return AsyncView<List<CafeOrder>>(
      value: board,
      onRetry: () => ref.invalidate(boardProvider),
      isEmpty: (orders) => orders.isEmpty,
      emptyIcon: Icons.coffee_outlined,
      emptyTitle: 'No orders on the board',
      emptyMessage: 'New orders appear here the moment they are rung up.',
      builder: (orders) => Column(
        children: [
          _BoardSummary(orders: orders),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Cards are sized to stay readable rather than to fill the
                // width: a fixed column count would give unreadably wide cards
                // on a desktop and cramped ones on a phone.
                final columns = (constraints.maxWidth / 340).floor().clamp(
                  1,
                  4,
                );

                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // Tall enough for a handful of lines plus the footer.
                    mainAxisExtent: 320,
                  ),
                  itemCount: orders.length,
                  itemBuilder: (context, index) =>
                      _OrderCard(order: orders[index], isManager: isManager),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BoardSummary extends StatelessWidget {
  const _BoardSummary({required this.orders});

  final List<CafeOrder> orders;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final waiting = orders
        .where((order) => order.status != OrderStatus.served)
        .length;
    final ready = orders.where((order) => order.allLinesReady).length;

    final oldest = orders.isEmpty
        ? Duration.zero
        : orders.map((order) => order.age).reduce((a, b) => a > b ? a : b);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: scheme.success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Live',
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: scheme.success, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _Metric(label: 'Open', value: '$waiting'),
                _Metric(label: 'Ready', value: '$ready'),
                if (orders.isNotEmpty)
                  _Metric(label: 'Oldest', value: formatAge(oldest)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _OrderCard extends ConsumerStatefulWidget {
  const _OrderCard({required this.order, required this.isManager});

  final CafeOrder order;
  final bool isManager;

  @override
  ConsumerState<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends ConsumerState<_OrderCard> {
  bool _busy = false;

  CafeOrder get order => widget.order;

  /// Orders that have been waiting this long are flagged on the card.
  static const Duration _lateAfter = Duration(minutes: 10);

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) {
      return;
    }

    setState(() => _busy = true);

    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) {
        showToast(
          context,
          humanizeErrorCode(error.code, error.message),
          isError: true,
        );
      }
    } catch (error) {
      if (mounted) {
        showToast(context, '$error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _advanceLine(OrderLine line) async {
    final next = line.status.next;

    if (next == null) {
      return;
    }

    await _guard(
      () => ref.read(ordersRepositoryProvider).setLineStatus(line.id, next),
    );
  }

  Future<void> _checkout() async {
    await _guard(() async {
      final receipt = await ref
          .read(ordersRepositoryProvider)
          .checkout(order.id);

      if (!mounted) {
        return;
      }

      showToast(
        context,
        'Order ${receipt.orderNumber} paid — ${formatMoney(receipt.total)}',
      );
    });
  }

  Future<void> _cancel() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _CancelDialog(),
    );

    if (reason == null || reason.trim().isEmpty) {
      return;
    }

    await _guard(() async {
      await ref.read(ordersRepositoryProvider).cancel(order.id, reason);

      if (!mounted) {
        return;
      }

      showToast(
        context,
        'Order ${order.orderNumber} cancelled, stock returned',
      );
    });
  }

  Future<void> _setOrderStatus(OrderStatus status) => _guard(
    () => ref.read(ordersRepositoryProvider).setOrderStatus(order.id, status),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLate = order.age > _lateAfter;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Table ${order.tableLabel}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        order.orderNumber,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                StatusChip(
                  label: formatAge(order.age),
                  tone: isLate ? ChipTone.warning : ChipTone.neutral,
                  icon: isLate ? Icons.schedule : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                StatusChip(
                  label: order.status.label,
                  tone: switch (order.status) {
                    OrderStatus.open => ChipTone.info,
                    OrderStatus.preparing => ChipTone.warning,
                    OrderStatus.ready => ChipTone.success,
                    OrderStatus.served => ChipTone.neutral,
                    _ => ChipTone.neutral,
                  },
                ),
                if (order.allLinesReady) ...[
                  const SizedBox(width: 6),
                  const StatusChip(
                    label: 'All ready',
                    tone: ChipTone.success,
                    icon: Icons.check_circle_outline,
                  ),
                ],
              ],
            ),
            if (order.note != null && order.note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      order.note!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: order.lines.length,
                itemBuilder: (context, index) => _LineRow(
                  line: order.lines[index],
                  onTap: _busy ? null : () => _advanceLine(order.lines[index]),
                ),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatMoney(order.total),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (widget.isManager) ...[
                  PopupMenuButton<OrderStatus>(
                    enabled: !_busy,
                    tooltip: 'Set order status',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: _setOrderStatus,
                    itemBuilder: (context) => [
                      for (final status in const [
                        OrderStatus.open,
                        OrderStatus.preparing,
                        OrderStatus.ready,
                        OrderStatus.served,
                      ])
                        PopupMenuItem(
                          value: status,
                          enabled: status != order.status,
                          child: Text(status.label),
                        ),
                    ],
                  ),
                  IconButton(
                    onPressed: _busy ? null : _cancel,
                    icon: const Icon(Icons.cancel_outlined),
                    tooltip: 'Cancel order',
                    color: scheme.error,
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _checkout,
                    icon: _busy
                        ? const SizedBox(
                            height: 14,
                            width: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.payments_outlined, size: 18),
                    label: const Text('Pay'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onTap});

  final OrderLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDone = line.status == OrderItemStatus.served;
    final isCancelled = line.status == OrderItemStatus.cancelled;

    return InkWell(
      onTap: isCancelled ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${line.qty}×',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      decoration: isCancelled
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      color: isDone || isCancelled
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  if (line.note != null && line.note!.isNotEmpty)
                    Text(
                      line.note!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.primary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            StatusChip(
              label: line.status.label,
              tone: switch (line.status) {
                OrderItemStatus.queued => ChipTone.neutral,
                OrderItemStatus.preparing => ChipTone.warning,
                OrderItemStatus.ready => ChipTone.success,
                OrderItemStatus.served => ChipTone.neutral,
                OrderItemStatus.cancelled => ChipTone.danger,
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelDialog extends StatefulWidget {
  const _CancelDialog();

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _controller = TextEditingController();

  /// Common reasons, so the usual case is one tap rather than typing.
  static const List<String> _presets = [
    'Customer changed their mind',
    'Rung up by mistake',
    'Cannot make it',
    'Duplicate order',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cancel this order?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The ingredients go back into stock, and the reason is recorded '
            'on the ledger.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in _presets)
                ActionChip(
                  label: Text(preset),
                  onPressed: () => setState(() => _controller.text = preset),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'Why is this being cancelled?',
            ),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep order'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Cancel order'),
        ),
      ],
    );
  }
}
