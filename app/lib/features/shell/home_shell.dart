import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import '../inventory/inventory_page.dart';
import '../orders/board_page.dart';
import '../orders/new_order_page.dart';
import '../reports/reports_page.dart';

/// The signed-in app: navigation, and the role gate on what is reachable.
///
/// Reports are manager-only. The gate here is a convenience, not the security
/// boundary — the API enforces the same rule, so hiding the tab only saves
/// someone from a 403 they would otherwise have to discover.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({required this.profile, super.key});

  final Profile profile;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  /// Breakpoint at which a rail reads better than a bottom bar. 900 is roughly
  /// a landscape tablet, which is what a counter screen tends to be.
  static const double _railBreakpoint = 900;

  List<_Destination> get _destinations => [
    const _Destination(
      label: 'Board',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
    ),
    const _Destination(
      label: 'New order',
      icon: Icons.add_shopping_cart_outlined,
      selectedIcon: Icons.add_shopping_cart,
    ),
    const _Destination(
      label: 'Stock',
      icon: Icons.inventory_2_outlined,
      selectedIcon: Icons.inventory_2,
    ),
    if (widget.profile.role.isManager)
      const _Destination(
        label: 'Reports',
        icon: Icons.insights_outlined,
        selectedIcon: Icons.insights,
      ),
  ];

  Widget _pageAt(int index) => switch (index) {
    0 => const BoardPage(),
    1 => const NewOrderPage(),
    2 => const InventoryPage(),
    _ => const ReportsPage(),
  };

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to take orders.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await ref.read(supabaseProvider).auth.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final destinations = _destinations;

    // Clamp in case the role changed while a manager-only tab was selected.
    final index = _index.clamp(0, destinations.length - 1);

    final isWide = MediaQuery.sizeOf(context).width >= _railBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('CafeOps'),
            const SizedBox(width: 12),
            StatusChip(
              label: widget.profile.role.label,
              tone: switch (widget.profile.role) {
                UserRole.owner => ChipTone.success,
                UserRole.manager => ChipTone.info,
                UserRole.staff => ChipTone.neutral,
              },
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(
              child: Text(
                widget.profile.fullName,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: isWide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (value) =>
                      setState(() => _index = value),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final destination in destinations)
                      NavigationRailDestination(
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selectedIcon),
                        label: Text(destination.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _pageAt(index)),
              ],
            )
          : _pageAt(index),
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: [
                for (final destination in destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: destination.label,
                  ),
              ],
            ),
    );
  }
}

class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
