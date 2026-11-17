import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/formatting.dart';
import '../../core/providers.dart';
import '../../data/menu_repository.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// The till: pick items, name a table, send the order.
///
/// The cart holds menu items and quantities only. Prices shown here are read
/// from the same menu rows the server will price against, but they are
/// indicative — the server recomputes every figure, so what the customer is
/// charged never depends on what this screen believed.
class NewOrderPage extends ConsumerStatefulWidget {
  const NewOrderPage({super.key});

  @override
  ConsumerState<NewOrderPage> createState() => _NewOrderPageState();
}

class _NewOrderPageState extends ConsumerState<NewOrderPage> {
  final _tableController = TextEditingController();
  String? _categoryId;
  bool _sending = false;

  static const double _twoPaneBreakpoint = 820;

  @override
  void initState() {
    super.initState();
    _tableController.text = ref.read(cartProvider).tableLabel;
  }

  @override
  void dispose() {
    _tableController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final cart = ref.read(cartProvider);

    if (!cart.canSend || _sending) {
      return;
    }

    setState(() => _sending = true);

    try {
      final result = await ref
          .read(ordersRepositoryProvider)
          .placeOrder(
            tableLabel: cart.tableLabel,
            cart: cart.lines,
            note: cart.note,
          );

      ref.read(cartProvider.notifier).clearLines();

      // The sale moved stock, so anything showing balances is now stale.
      ref.invalidate(ingredientsProvider);

      if (mounted) {
        showToast(
          context,
          'Order ${result.orderNumber} sent — ${formatMoney(result.total)}',
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        // A stock shortage names every ingredient that is short, which is the
        // one error here worth showing in full rather than summarising.
        showToast(
          context,
          humanizeErrorCode(error.code, error.message),
          isError: true,
        );
      }
    } on ApiUnreachable catch (error) {
      if (mounted) {
        showToast(context, '$error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider);
    final isWide = MediaQuery.sizeOf(context).width >= _twoPaneBreakpoint;

    return AsyncView<Menu>(
      value: menu,
      onRetry: () => ref.invalidate(menuProvider),
      isEmpty: (menu) => menu.isEmpty,
      emptyIcon: Icons.menu_book_outlined,
      emptyTitle: 'The menu is empty',
      emptyMessage: 'Seed the database, or add items as a manager.',
      builder: (menu) {
        final categories = menu.categories;
        final selectedId =
            _categoryId ?? (categories.isNotEmpty ? categories.first.id : null);

        final items = selectedId == null
            ? const <MenuItem>[]
            : menu.itemsIn(selectedId);

        final menuPane = Column(
          children: [
            _CategoryBar(
              categories: categories,
              selectedId: selectedId,
              onSelected: (id) => setState(() => _categoryId = id),
            ),
            const Divider(height: 1),
            Expanded(child: _MenuGrid(items: items)),
          ],
        );

        if (isWide) {
          return Row(
            children: [
              Expanded(flex: 3, child: menuPane),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 360,
                child: _CartPane(
                  tableController: _tableController,
                  sending: _sending,
                  onSend: _send,
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            Expanded(child: menuPane),
            const Divider(height: 1),
            // On a phone the cart gets a compact, fixed footer so the total and
            // the send button are always reachable without scrolling.
            _CartFooter(
              tableController: _tableController,
              sending: _sending,
              onSend: _send,
            ),
          ],
        );
      },
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  final List<MenuCategory> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          for (final category in categories) ...[
            ChoiceChip(
              label: Text(category.name),
              selected: category.id == selectedId,
              onSelected: (_) => onSelected(category.id),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _MenuGrid extends ConsumerWidget {
  const _MenuGrid({required this.items});

  final List<MenuItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.local_cafe_outlined,
        title: 'Nothing in this category',
      );
    }

    final cart = ref.watch(cartProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 180).floor().clamp(2, 6);

        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 116,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final qty = cart.lines
                .where((line) => line.item.id == item.id)
                .fold(0, (sum, line) => sum + line.qty);

            return _MenuTile(
              item: item,
              qty: qty,
              onTap: item.isAvailable
                  ? () => ref.read(cartProvider.notifier).add(item)
                  : null,
            );
          },
        );
      },
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.item, required this.qty, required this.onTap});

  final MenuItem item;
  final int qty;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOut = !item.isAvailable;

    return Card(
      color: qty > 0 ? scheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isOut ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                  ),
                  if (qty > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '$qty',
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              if (isOut)
                const StatusChip(label: 'Unavailable', tone: ChipTone.danger)
              else
                Text(
                  formatMoney(item.price),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cart as a side panel, on a tablet or desktop.
class _CartPane extends ConsumerWidget {
  const _CartPane({
    required this.tableController,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController tableController;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final notifier = ref.read(cartProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: tableController,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Table',
              hintText: 'e.g. T4 or Takeaway',
              prefixIcon: Icon(Icons.table_restaurant_outlined),
            ),
            onChanged: notifier.setTable,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: cart.isEmpty
              ? const EmptyState(
                  icon: Icons.shopping_cart_outlined,
                  title: 'Cart is empty',
                  message: 'Tap an item to add it.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: cart.lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _CartRow(line: cart.lines[index]),
                ),
        ),
        const Divider(height: 1),
        _CartTotals(
          cart: cart,
          sending: sending,
          onSend: onSend,
          onClear: cart.isEmpty ? null : notifier.clearLines,
        ),
      ],
    );
  }
}

class _CartRow extends ConsumerWidget {
  const _CartRow({required this.line});

  final CartLine line;

  Future<void> _editNote(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: line.note ?? '');

    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(line.item.name),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Note for the kitchen',
            hintText: 'e.g. oat milk, extra hot',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (note != null) {
      ref
          .read(cartProvider.notifier)
          .setLineNote(line.item.id, note.trim().isEmpty ? null : note.trim());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(cartProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  formatMoney(line.lineTotal),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (line.note != null)
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
          IconButton(
            onPressed: () => _editNote(context, ref),
            icon: const Icon(Icons.edit_note, size: 20),
            tooltip: 'Add a note',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: () => notifier.removeOne(line.item.id),
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            visualDensity: VisualDensity.compact,
          ),
          SizedBox(
            width: 22,
            child: Text(
              '${line.qty}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            onPressed: () => notifier.add(line.item),
            icon: const Icon(Icons.add_circle_outline, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _CartTotals extends StatelessWidget {
  const _CartTotals({
    required this.cart,
    required this.sending,
    required this.onSend,
    required this.onClear,
  });

  final Cart cart;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              Text(
                formatMoney(cart.subtotal),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Service charge and tax are added by the server.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: cart.canSend && !sending ? onSend : null,
            icon: sending
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(sending ? 'Sending…' : 'Send to kitchen'),
          ),
          if (!cart.isEmpty && cart.tableLabel.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Enter a table to send this order.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          if (onClear != null)
            TextButton(onPressed: onClear, child: const Text('Clear cart')),
        ],
      ),
    );
  }
}

/// The cart as a phone footer: a total, a send button, and a sheet for detail.
class _CartFooter extends ConsumerWidget {
  const _CartFooter({
    required this.tableController,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController tableController;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: tableController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Table',
                      isDense: true,
                    ),
                    onChanged: ref.read(cartProvider.notifier).setTable,
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: cart.isEmpty
                      ? null
                      : () => showModalBottomSheet<void>(
                          context: context,
                          showDragHandle: true,
                          builder: (context) => SizedBox(
                            height: 420,
                            child: _CartPane(
                              tableController: tableController,
                              sending: sending,
                              onSend: () {
                                Navigator.pop(context);
                                onSend();
                              },
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                  label: Text('${cart.itemCount}'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatMoney(cart.subtotal),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                FilledButton.icon(
                  onPressed: cart.canSend && !sending ? onSend : null,
                  icon: sending
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, size: 18),
                  label: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
