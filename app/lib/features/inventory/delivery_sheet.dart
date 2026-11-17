import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/formatting.dart';
import '../../core/providers.dart';
import '../../data/inventory_repository.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// Books in a delivery: pick a supplier, add what arrived, submit once.
///
/// The whole delivery goes to the API in one call so that the balances and the
/// ledger rows land in a single transaction. Sending a line at a time would
/// leave a half-booked delivery behind if the connection dropped.
class DeliverySheet extends ConsumerStatefulWidget {
  const DeliverySheet({super.key});

  @override
  ConsumerState<DeliverySheet> createState() => _DeliverySheetState();
}

class _DeliverySheetState extends ConsumerState<DeliverySheet> {
  final Map<String, double> _quantities = {};
  final _note = TextEditingController();
  String? _supplierId;
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  List<Ingredient> _candidates(List<Ingredient> all) {
    if (_supplierId == null) {
      return all;
    }

    // Default to the chosen supplier's own ingredients, which is what a
    // delivery note from them will list.
    final theirs = all.where((item) => item.supplierId == _supplierId).toList();

    return theirs.isEmpty ? all : theirs;
  }

  Future<void> _submit(List<Ingredient> ingredients) async {
    final supplierId = _supplierId;

    final lines = [
      for (final entry in _quantities.entries)
        if (entry.value > 0)
          DeliveryDraftLine(
            ingredient: ingredients.firstWhere((i) => i.id == entry.key),
            qty: entry.value,
          ),
    ];

    if (supplierId == null || lines.isEmpty || _busy) {
      return;
    }

    setState(() => _busy = true);

    try {
      final movements = await ref
          .read(inventoryRepositoryProvider)
          .receiveDelivery(
            supplierId: supplierId,
            lines: lines,
            note: _note.text,
          );

      ref.invalidate(ingredientsProvider);

      for (final line in lines) {
        ref.invalidate(stockHistoryProvider(line.ingredient.id));
      }

      if (mounted) {
        Navigator.pop(context);
        showToast(
          context,
          'Booked in ${movements.length} '
          'item${movements.length == 1 ? '' : 's'}',
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        showToast(context, error.message, isError: true);
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

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(suppliersProvider);
    final ingredients = ref.watch(ingredientsProvider);

    final lineCount = _quantities.values.where((qty) => qty > 0).length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Receive delivery',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            switch (suppliers) {
              AsyncError(:final error) => ErrorState(
                error: error,
                onRetry: () => ref.invalidate(suppliersProvider),
              ),
              AsyncLoading() => const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
              AsyncValue(:final value?) => DropdownButtonFormField<String>(
                initialValue: _supplierId,
                decoration: const InputDecoration(
                  labelText: 'Supplier',
                  prefixIcon: Icon(Icons.store_outlined),
                ),
                items: [
                  for (final supplier in value)
                    DropdownMenuItem(
                      value: supplier.id,
                      child: Text(supplier.name),
                    ),
                ],
                onChanged: (id) => setState(() => _supplierId = id),
              ),
            },
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Delivery note reference (optional)',
                prefixIcon: Icon(Icons.receipt_long_outlined),
              ),
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'What arrived'),
            Expanded(
              child: AsyncView<List<Ingredient>>(
                value: ingredients,
                onRetry: () => ref.invalidate(ingredientsProvider),
                builder: (all) {
                  final candidates = _candidates(all);

                  return ListView.builder(
                    controller: controller,
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final ingredient = candidates[index];

                      return _DeliveryLineRow(
                        ingredient: ingredient,
                        quantity: _quantities[ingredient.id] ?? 0,
                        onChanged: (value) => setState(() {
                          if (value <= 0) {
                            _quantities.remove(ingredient.id);
                          } else {
                            _quantities[ingredient.id] = value;
                          }
                        }),
                      );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: FilledButton.icon(
                  onPressed: _supplierId == null || lineCount == 0 || _busy
                      ? null
                      : () => _submit(ingredients.value ?? const []),
                  icon: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(
                    lineCount == 0
                        ? 'Add at least one item'
                        : 'Book in $lineCount '
                              'item${lineCount == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeliveryLineRow extends StatefulWidget {
  const _DeliveryLineRow({
    required this.ingredient,
    required this.quantity,
    required this.onChanged,
  });

  final Ingredient ingredient;
  final double quantity;
  final ValueChanged<double> onChanged;

  @override
  State<_DeliveryLineRow> createState() => _DeliveryLineRowState();
}

class _DeliveryLineRowState extends State<_DeliveryLineRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.quantity > 0 ? _format(widget.quantity) : '',
  );

  static String _format(double value) => value.truncateToDouble() == value
      ? value.toStringAsFixed(0)
      : value.toString();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.ingredient.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'On hand '
                  '${formatQuantity(widget.ingredient.stockQty, widget.ingredient.unit)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.ingredient.isLow
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                isDense: true,
                suffixText: widget.ingredient.unit,
                hintText: '0',
              ),
              onChanged: (text) =>
                  widget.onChanged(double.tryParse(text.trim()) ?? 0),
            ),
          ),
        ],
      ),
    );
  }
}
