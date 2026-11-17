import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/formatting.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'delivery_sheet.dart';

/// Stock levels, with the ledger behind each one.
///
/// Everyone on shift can see what is running low — that is useful to a barista,
/// not just a manager. Only managers can move a balance, and even then only
/// through the API, which writes the movement and the new balance together.
class InventoryPage extends ConsumerWidget {
  const InventoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ingredients = ref.watch(ingredientsProvider);
    final isManager =
        ref.watch(currentProfileProvider).value?.role.isManager ?? false;

    return Scaffold(
      body: AsyncView<List<Ingredient>>(
        value: ingredients,
        onRetry: () => ref.invalidate(ingredientsProvider),
        isEmpty: (list) => list.isEmpty,
        emptyIcon: Icons.inventory_2_outlined,
        emptyTitle: 'No ingredients yet',
        emptyMessage: 'Seed the database to populate the stock room.',
        builder: (list) {
          final low = list.where((item) => item.isLow).toList();

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(ingredientsProvider),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (low.isNotEmpty) _LowStockBanner(items: low),
                SectionHeader(
                  title: 'Stock room',
                  trailing: Text(
                    '${list.length} items',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                for (final ingredient in list)
                  _IngredientTile(ingredient: ingredient, isManager: isManager),
                const SizedBox(height: 80),
              ],
            ),
          );
        },
      ),
      floatingActionButton: isManager
          ? FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => const DeliverySheet(),
              ),
              icon: const Icon(Icons.local_shipping_outlined),
              label: const Text('Receive delivery'),
            )
          : null,
    );
  }
}

class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.items});

  final List<Ingredient> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.warningSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${items.length} item${items.length == 1 ? '' : 's'} at or '
                  'below the reorder level',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onWarningSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in items)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${item.name} · ${formatQuantity(item.stockQty, item.unit)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IngredientTile extends ConsumerWidget {
  const _IngredientTile({required this.ingredient, required this.isManager});

  final Ingredient ingredient;
  final bool isManager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isLow = ingredient.isLow;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) =>
              _IngredientSheet(ingredient: ingredient, isManager: isManager),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ingredient.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    formatQuantity(ingredient.stockQty, ingredient.unit),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isLow ? scheme.warning : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ingredient.fullness,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                    isLow ? scheme.warning : scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Reorder at '
                      '${formatQuantity(ingredient.reorderLevel, ingredient.unit)}'
                      '${ingredient.supplierName == null ? '' : ' · ${ingredient.supplierName}'}',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isLow)
                    const StatusChip(label: 'Low', tone: ChipTone.warning),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Detail for one ingredient: its ledger, and the manager actions.
class _IngredientSheet extends ConsumerWidget {
  const _IngredientSheet({required this.ingredient, required this.isManager});

  final Ingredient ingredient;
  final bool isManager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(stockHistoryProvider(ingredient.id));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ingredient.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${formatQuantity(ingredient.stockQty, ingredient.unit)} on hand · '
              'reorder at '
              '${formatQuantity(ingredient.reorderLevel, ingredient.unit)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (isManager) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        _showAdjust(context, ref, StockReason.waste),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Record waste'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _showAdjust(context, ref, StockReason.stockCount),
                    icon: const Icon(Icons.fact_check_outlined, size: 18),
                    label: const Text('Stock count'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _showAdjust(context, ref, StockReason.adjustment),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Adjust'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const SectionHeader(title: 'Ledger'),
            Expanded(
              child: AsyncView<List<StockMovement>>(
                value: history,
                onRetry: () =>
                    ref.invalidate(stockHistoryProvider(ingredient.id)),
                isEmpty: (list) => list.isEmpty,
                emptyIcon: Icons.history,
                emptyTitle: 'No movements yet',
                emptyMessage: isManager
                    ? 'Deliveries, sales and corrections appear here.'
                    : 'Only managers can see the ledger.',
                builder: (movements) => ListView.separated(
                  controller: controller,
                  itemCount: movements.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _MovementRow(movement: movements[index]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAdjust(
    BuildContext context,
    WidgetRef ref,
    StockReason reason,
  ) async {
    final result = await showDialog<_AdjustResult>(
      context: context,
      builder: (context) =>
          _AdjustDialog(ingredient: ingredient, reason: reason),
    );

    if (result == null) {
      return;
    }

    try {
      await ref
          .read(inventoryRepositoryProvider)
          .adjust(
            ingredientId: ingredient.id,
            quantity: result.quantity,
            reason: reason,
            note: result.note,
          );

      ref.invalidate(ingredientsProvider);
      ref.invalidate(stockHistoryProvider(ingredient.id));

      if (context.mounted) {
        showToast(context, '${ingredient.name} updated');
      }
    } on ApiException catch (error) {
      if (context.mounted) {
        showToast(context, error.message, isError: true);
      }
    } catch (error) {
      if (context.mounted) {
        showToast(context, '$error', isError: true);
      }
    }
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.movement});

  final StockMovement movement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isIncrease = movement.delta > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(
            isIncrease ? Icons.arrow_upward : Icons.arrow_downward,
            size: 18,
            color: isIncrease ? scheme.success : scheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(movement.reason.label),
                Text(
                  [
                    formatStamp(movement.createdAt),
                    if (movement.createdByName != null) movement.createdByName!,
                    if (movement.note != null) movement.note!,
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isIncrease ? '+' : ''}${movement.delta.toStringAsFixed(movement.delta.truncateToDouble() == movement.delta ? 0 : 2)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isIncrease ? scheme.success : scheme.error,
                ),
              ),
              Text(
                'to ${movement.balanceAfter.toStringAsFixed(0)}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AdjustResult {
  const _AdjustResult({required this.quantity, this.note});

  final double quantity;
  final String? note;
}

class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.ingredient, required this.reason});

  final Ingredient ingredient;
  final StockReason reason;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _quantity = TextEditingController();
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _note.dispose();
    super.dispose();
  }

  /// A stock count is an absolute balance; the others are a change.
  bool get _isAbsolute => widget.reason == StockReason.stockCount;

  String get _title => switch (widget.reason) {
    StockReason.waste => 'Record waste',
    StockReason.stockCount => 'Stock count',
    _ => 'Adjust stock',
  };

  String get _hint => switch (widget.reason) {
    StockReason.waste => 'How much was thrown away',
    StockReason.stockCount => 'What is actually on the shelf',
    _ => 'Use a negative number to reduce',
  };

  void _submit() {
    final value = double.tryParse(_quantity.text.trim());

    if (value == null) {
      setState(() => _error = 'Enter a number');
      return;
    }

    if (widget.reason == StockReason.waste && value <= 0) {
      setState(
        () => _error = 'Enter how much was wasted, as a positive amount',
      );
      return;
    }

    if (_isAbsolute && value < 0) {
      setState(() => _error = 'A counted quantity cannot be negative');
      return;
    }

    // Waste is entered as a positive number because that is how a person says
    // it; the server needs it as a reduction.
    final quantity = widget.reason == StockReason.waste ? -value : value;

    Navigator.pop(
      context,
      _AdjustResult(
        quantity: quantity,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.ingredient.name} · '
            '${formatQuantity(widget.ingredient.stockQty, widget.ingredient.unit)} '
            'on hand',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _quantity,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: InputDecoration(
              labelText: 'Quantity (${widget.ingredient.unit})',
              hintText: _hint,
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
