import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/features/dashboard/screens/dashboard_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/add_product_sheet.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/payments_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/features/deliveries/screens/deliveries_screen.dart';
import 'package:reebaplus_pos/shared/widgets/activity_log_screen.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/models/order.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/sync_banner.dart';
import 'package:reebaplus_pos/shared/widgets/tab_navigator.dart';

// The LazyIndexedStack has been replaced with the direct Offstage + Set approach
// requested for eliminating mount jank on cold start.

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static void _voidOnCustomerChanged(dynamic _) {}

  // 11 tabs = 11 Navigators (Staff tab removed with staff management feature)
  final List<GlobalKey<NavigatorState>> _navigatorKeys = List.generate(
    11,
    (_) => GlobalKey<NavigatorState>(),
  );

  // One pop-observer per tab; created in initState once `nav` is available.
  late final List<_TabPopObserver> _observers;

  // Captured at initState — the tab-index listener and the WidgetsBindingObserver
  // didPopRoute callback both fire across navigator-key regeneration windows
  // (AuthService.setCurrentUser → nav.setIndex(...) → fires listener; back-press
  // → didPopRoute) where this State could already be element-unmounted. Touching
  // `ref` from those callbacks would race the riverpod invalidation, so capture
  // the providers up front. See plan §"Bug fix" Pattern 2.
  late final NavigationService _nav;

  // Track which tabs have ever been visited
  final Set<int> _initializedTabs = {};

  final List<Widget> _tabWidgets = [
    const DashboardScreen(), // 0
    const PosHomeScreen(), // 1
    const InventoryScreen(), // 2
    const OrdersScreen(), // 3
    const CustomersScreen(), // 4
    const PaymentsScreen(), // 5
    const ExpensesScreen(), // 6
    const StoresScreen(), // 7
    const CartScreen(
      cart: [],
      crateDeposit: 0.0,
      onCustomerChanged: _voidOnCustomerChanged,
    ), // 8
    const DeliveriesScreen(), // 9
    const ActivityLogScreen(), // 10
  ];

  // Persistent pending-orders count — subscribed once, never recreated.
  int _pendingOrderCount = 0;
  StreamSubscription<List<Order>>? _pendingOrdersSub;

  late final AnimationController _tabSwitchController;
  late final Animation<double> _tabFadeAnimation;
  int? _previousTabIndex;

  @override
  void initState() {
    super.initState();

    // Register BEFORE any Navigator so we get the back event first.
    WidgetsBinding.instance.addObserver(this);

    // Link shared keys
    _nav = ref.read(navigationProvider);
    _nav.tabNavigatorKeys = _navigatorKeys;

    _observers = List.generate(11, (i) => _TabPopObserver(tabIndex: i, nav: _nav));

    // Only pre-load the landing tab
    _initializedTabs.add(_nav.currentIndex.value);
    _previousTabIndex = _nav.currentIndex.value;

    _tabSwitchController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _tabFadeAnimation = CurvedAnimation(
      parent: _tabSwitchController,
      curve: Curves.easeOut,
    );

    _nav.currentIndex.addListener(_onTabIndexChanged);

    _pendingOrdersSub = ref
        .read(orderServiceProvider)
        .watchPendingOrders()
        .listen((orders) {
          if (mounted) setState(() => _pendingOrderCount = orders.length);
        });

    // Consume the one-shot AddProductSheet flag set by SuccessDashboardEntryScreen.
    // Defer to first post-frame so mainScaffoldKey is wired before showing.
    if (_nav.consumeAutoShowAddProductSheet()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final scaffoldCtx = _nav.mainScaffoldKey.currentContext;
        if (scaffoldCtx != null && scaffoldCtx.mounted) {
          showModalBottomSheet(
            context: scaffoldCtx,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const AddProductSheet(),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nav.currentIndex.removeListener(_onTabIndexChanged);
    _tabSwitchController.dispose();
    _pendingOrdersSub?.cancel();
    super.dispose();
  }

  void _onTabIndexChanged() {
    final newIndex = _nav.currentIndex.value;
    if (newIndex == _previousTabIndex) return;
    _previousTabIndex = newIndex;
    _tabSwitchController.forward(from: 0);
  }

  /// Intercepts the system back button at the highest level, before any
  /// nested Navigator (TabNavigator) can consume it.
  @override
  Future<bool> didPopRoute() async {
    _nav.handleBackPress(context);
    return true; // Always consume — we handle everything ourselves.
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final nav = ref.read(navigationProvider);

    return ValueListenableBuilder<int>(
      valueListenable: nav.currentIndex,
      builder: (context, currentIndex, _) {
        _initializedTabs.add(currentIndex); // mark as visited

        return Scaffold(
          key: nav.mainScaffoldKey,

          // Offstage keeps the widget alive and mounted for streams/scroll,
          // while `_initializedTabs` ensures exactly zero unused tabs are mounted initially.
          //
          // The Column overlay places SyncBanner above the tab Stack. The
          // banner self-collapses to zero height when the pull state is idle
          // (AnimatedSize), so the per-screen Scaffolds underneath still
          // reach the status bar when nothing is syncing.
          body: Column(
            children: [
              const SyncBanner(),
              Expanded(
                child: Stack(
                  children: List.generate(11, (i) {
                    if (!_initializedTabs.contains(i)) {
                      // Not yet visited — render nothing
                      return const SizedBox.shrink();
                    }
                    final tab = Offstage(
                      offstage: i != currentIndex,
                      // TickerMode guarantees animations on offstage tabs don't tick
                      child: TickerMode(
                        enabled: i == currentIndex,
                        child: TabNavigator(
                          navigatorKey: _navigatorKeys[i],
                          rootScreen: _tabWidgets[i],
                          observer: _observers[i],
                        ),
                      ),
                    );
                    if (i != currentIndex) return tab;
                    return FadeTransition(opacity: _tabFadeAnimation, child: tab);
                  }),
                ),
              ),
            ],
          ),
          bottomNavigationBar: Builder(
            builder: (context) {
              final iconColor =
                  t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

              // Lone-owner nav: Home(0), Stock(2), POS(1), Orders(3), Cart(8)
              final bool isNavTab = [0, 1, 2, 3, 8].contains(currentIndex);
              final int navIndex = currentIndex == 0
                  ? 0
                  : (currentIndex == 2
                        ? 1
                        : (currentIndex == 1
                              ? 2
                              : (currentIndex == 3
                                    ? 3
                                    : (currentIndex == 8 ? 4 : 0))));

              return ValueListenableBuilder<bool>(
                valueListenable: nav.currentTabCanPop,
                builder: (context, canPop, _) {
                  if (!isNavTab || canPop) return const SizedBox.shrink();
                  return BottomNavigationBar(
                currentIndex: navIndex,
                selectedItemColor: isNavTab ? t.colorScheme.primary : iconColor,
                unselectedItemColor: iconColor,
                onTap: (index) {
                  int indexToSet = 0;
                  switch (index) {
                    case 0:
                      indexToSet = 0;
                      break;
                    case 1:
                      indexToSet = 2;
                      break;
                    case 2:
                      indexToSet = 1;
                      break;
                    case 3:
                      indexToSet = 3;
                      break;
                    case 4:
                      indexToSet = 8;
                      break;
                  }

                  if (currentIndex == indexToSet) {
                    // Tap current tab: pop all detail screens to root
                    _navigatorKeys[indexToSet].currentState?.popUntil(
                      (r) => r.isFirst,
                    );
                  } else {
                    nav.setIndex(indexToSet);
                  }
                },
                type: BottomNavigationBarType.fixed,
                items: [
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.dashboard_outlined),
                    activeIcon: Icon(
                      isNavTab ? Icons.dashboard : Icons.dashboard_outlined,
                    ),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.inventory_2_outlined),
                    activeIcon: Icon(
                      isNavTab ? Icons.inventory_2 : Icons.inventory_2_outlined,
                    ),
                    label: 'Stock',
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.point_of_sale_outlined),
                    activeIcon: Icon(
                      isNavTab
                          ? Icons.point_of_sale
                          : Icons.point_of_sale_outlined,
                    ),
                    label: 'POS',
                  ),
                  BottomNavigationBarItem(
                    icon: Badge(
                      label: Text(_pendingOrderCount.toString()),
                      isLabelVisible: _pendingOrderCount > 0,
                      backgroundColor: t.colorScheme.error,
                      child: const Icon(Icons.receipt_long_outlined),
                    ),
                    activeIcon: Badge(
                      label: Text(_pendingOrderCount.toString()),
                      isLabelVisible: _pendingOrderCount > 0,
                      backgroundColor: t.colorScheme.error,
                      child: Icon(
                        isNavTab
                            ? Icons.receipt_long
                            : Icons.receipt_long_outlined,
                      ),
                    ),
                    label: 'Orders',
                  ),
                  BottomNavigationBarItem(
                    icon: ValueListenableBuilder<List<Map<String, dynamic>>>(
                      valueListenable: ref.read(cartProvider),
                      builder: (_, cart, __) => Badge(
                        label: Text(cart.length.toString()),
                        isLabelVisible: cart.isNotEmpty,
                        backgroundColor: t.colorScheme.error,
                        child: const Icon(Icons.shopping_cart_outlined),
                      ),
                    ),
                    activeIcon:
                        ValueListenableBuilder<List<Map<String, dynamic>>>(
                          valueListenable: ref.read(cartProvider),
                          builder: (_, cart, __) => Badge(
                            label: Text(cart.length.toString()),
                            isLabelVisible: cart.isNotEmpty,
                            backgroundColor: t.colorScheme.error,
                            child: Icon(
                              isNavTab
                                  ? Icons.shopping_cart
                                  : Icons.shopping_cart_outlined,
                            ),
                          ),
                        ),
                    label: 'Cart',
                  ),
                ],
              );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _TabPopObserver extends NavigatorObserver {
  _TabPopObserver({required this.tabIndex, required this.nav});

  final int tabIndex;
  final NavigationService nav;

  void _sync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.setTabCanPop(tabIndex, navigator?.canPop() ?? false);
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _sync();
  }
}
