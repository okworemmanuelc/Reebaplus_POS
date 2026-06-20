import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/payments_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/shared/widgets/activity_log_screen.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/tab_navigator.dart';

// The LazyIndexedStack has been replaced with the direct Offstage + Set approach
// requested for eliminating mount jank on cold start.

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout>
    with SingleTickerProviderStateMixin {
  static void _voidOnCustomerChanged(dynamic _) {}

  // 10 tabs = 10 Navigators (Funds Register removed §23; Deliveries removed).
  final List<GlobalKey<NavigatorState>> _navigatorKeys = List.generate(
    10,
    (_) => GlobalKey<NavigatorState>(),
  );

  // One pop-observer per tab; created in initState once `nav` is available.
  late final List<_TabPopObserver> _observers;

  // Captured at initState — the tab-index listener and the PopScope
  // onPopInvokedWithResult callback both fire across navigator-key regeneration
  // windows (AuthService.setCurrentUser → nav.setIndex(...) → fires listener;
  // back-press → onPopInvokedWithResult) where this State could already be
  // element-unmounted. Touching
  // `ref` from those callbacks would race the riverpod invalidation, so capture
  // the providers up front. See plan §"Bug fix" Pattern 2.
  late final NavigationService _nav;

  // Track which tabs have ever been visited
  final Set<int> _initializedTabs = {};

  final List<Widget> _tabWidgets = [
    const HomeScreen(), // 0
    const PosHomeScreen(), // 1
    const InventoryScreen(), // 2
    const OrdersScreen(), // 3
    const CustomersScreen(), // 4
    const PaymentsScreen(), // 5
    const ExpensesScreen(), // 6
    const StoresScreen(), // 7
    const CartScreen(cart: [], onCustomerChanged: _voidOnCustomerChanged), // 8
    const ActivityLogScreen(), // 9
  ];

  // Persistent pending-orders list — subscribed once, never recreated. Holds
  // every store's pending orders; the badge filters to the active side-bar
  // store at build time (§12.1) so the count tracks the selected store.
  List<OrderData> _pendingOrders = const [];
  StreamSubscription<List<OrderData>>? _pendingOrdersSub;

  late final AnimationController _tabSwitchController;
  late final Animation<double> _tabFadeAnimation;
  int? _previousTabIndex;

  @override
  void initState() {
    super.initState();

    // Link shared keys
    _nav = ref.read(navigationProvider);
    _nav.tabNavigatorKeys = _navigatorKeys;

    _observers = List.generate(
      10,
      (i) => _TabPopObserver(tabIndex: i, nav: _nav),
    );

    // Only pre-load the landing tab. Remaining tabs are warmed offstage one per
    // frame after the first frame settles (see _warmNextTab), so the first tap
    // on any tab is an instant show instead of a cold, janky synchronous build.
    _initializedTabs.add(_nav.currentIndex.value);
    _previousTabIndex = _nav.currentIndex.value;
    WidgetsBinding.instance.addPostFrameCallback((_) => _warmNextTab());

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
        .read(databaseProvider)
        .ordersDao
        .watchPendingOrders()
        .listen((orders) {
          if (mounted) setState(() => _pendingOrders = orders);
        });

    // Consume the one-shot Add Product flag set by SuccessDashboardEntryScreen.
    // Defer to first post-frame so mainScaffoldKey is wired before showing.
    if (_nav.consumeAutoShowAddProductSheet()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final scaffoldCtx = _nav.mainScaffoldKey.currentContext;
        if (scaffoldCtx != null && scaffoldCtx.mounted) {
          Navigator.of(
            scaffoldCtx,
          ).push(MaterialPageRoute(builder: (_) => const AddProductScreen()));
        }
      });
    }
  }

  @override
  void dispose() {
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

  // Progressively mount the not-yet-visited tabs offstage, one per frame, after
  // the first frame has settled. Spreading the mounts across frames keeps cold
  // start cheap (only the landing tab builds synchronously) while ensuring that
  // by the time the user taps a tab its heavy first build (DB streams, lists) is
  // already done — so the switch is an instant offstage→onstage flip with no
  // synchronous-build jank competing with the fade.
  void _warmNextTab() {
    if (!mounted) return;
    for (var i = 0; i < _tabWidgets.length; i++) {
      if (!_initializedTabs.contains(i)) {
        setState(() => _initializedTabs.add(i));
        WidgetsBinding.instance.addPostFrameCallback((_) => _warmNextTab());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final nav = ref.read(navigationProvider);

    // §12.1: the Orders badge is scoped to the active side-bar store. A concrete
    // store counts only its own pending orders; "All Stores" (null) counts all.
    final activeStoreId = ref.watch(lockedStoreProvider).value;
    final pendingOrderCount = activeStoreId == null
        ? _pendingOrders.length
        : _pendingOrders.where((o) => o.storeId == activeStoreId).length;

    // §12.1 confined-user default. A user who cannot view all stores must always
    // have a concrete active store so every view filters correctly and the
    // permission resolver scopes to their store — including single-store staff
    // who see no picker. All-stores viewers (CEO / all-stores Manager) keep
    // `null` (= "All Stores"). The mutation is deferred to post-frame so it never
    // runs during build (lockedStoreId has listeners that rebuild).
    final selectableStores = ref.watch(selectableStoresProvider);
    if (!ref.watch(canViewAllStoresProvider) && selectableStores.isNotEmpty) {
      final active = nav.lockedStoreId.value;
      if (active == null || !selectableStores.any((s) => s.id == active)) {
        final target = selectableStores.first.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (nav.lockedStoreId.value == target) return;
          // explicit: false — this is the silent default, not a user pick, so the
          // POS gate still prompts a multi-store confined user to choose (§12.1).
          nav.setLockedStore(target, explicit: false);
        });
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _nav.handleBackPress(context);
      },
      child: ValueListenableBuilder<int>(
        valueListenable: nav.currentIndex,
        builder: (context, currentIndex, _) {
          _initializedTabs.add(currentIndex); // mark as visited

          return Scaffold(
            key: nav.mainScaffoldKey,

            // Offstage keeps the widget alive and mounted for streams/scroll,
            // while `_initializedTabs` ensures exactly zero unused tabs are mounted initially.
            body: Stack(
              children: List.generate(_tabWidgets.length, (i) {
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
          bottomNavigationBar: Builder(
            builder: (context) {
              final iconColor =
                  t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

              // Nav tabs in bar order. Stock (Inventory, tab 2) is gated on
              // stock.view (§16.7); POS (tab 1) and Cart (tab 8) are gated on
              // sales.make (hard rule #7 — hide what the role can't use, e.g.
              // the stock keeper). Driving the index math AND the items list
              // from one list keeps a hidden tab from desyncing them.
              // Home(0), Stock(2), POS(1), Orders(3), Cart(8).
              final showStock = hasPermission(ref, 'stock.view');
              final showPos = hasPermission(ref, 'sales.make');
              final tabOrder = <int>[
                0,
                if (showStock) 2,
                if (showPos) 1,
                3,
                if (showPos) 8,
              ];
              final bool isNavTab = tabOrder.contains(currentIndex);
              final int navIndex = isNavTab
                  ? tabOrder.indexOf(currentIndex)
                  : 0;

              return ValueListenableBuilder<bool>(
                valueListenable: nav.currentTabCanPop,
                builder: (context, canPop, _) {
                  if (!isNavTab || canPop) return const SizedBox.shrink();
                  return BottomNavigationBar(
                    currentIndex: navIndex,
                    selectedItemColor: isNavTab
                        ? t.colorScheme.primary
                        : iconColor,
                    unselectedItemColor: iconColor,
                    onTap: (index) {
                      // tabOrder maps a bottom-bar slot to its underlying tab index,
                      // so it stays correct whether or not the Stock tab is present.
                      final indexToSet = tabOrder[index];

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
                      if (showStock)
                        BottomNavigationBarItem(
                          icon: const Icon(Icons.inventory_2_outlined),
                          activeIcon: Icon(
                            isNavTab
                                ? Icons.inventory_2
                                : Icons.inventory_2_outlined,
                          ),
                          label: 'Stock',
                        ),
                      if (showPos)
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
                          label: Text(pendingOrderCount.toString()),
                          isLabelVisible: pendingOrderCount > 0,
                          backgroundColor: t.colorScheme.error,
                          child: const Icon(Icons.receipt_long_outlined),
                        ),
                        activeIcon: Badge(
                          label: Text(pendingOrderCount.toString()),
                          isLabelVisible: pendingOrderCount > 0,
                          backgroundColor: t.colorScheme.error,
                          child: Icon(
                            isNavTab
                                ? Icons.receipt_long
                                : Icons.receipt_long_outlined,
                          ),
                        ),
                        label: 'Orders',
                      ),
                      if (showPos)
                        BottomNavigationBarItem(
                          icon:
                              ValueListenableBuilder<
                                List<Map<String, dynamic>>
                              >(
                                valueListenable: ref.read(cartProvider),
                                builder: (_, cart, __) => Badge(
                                  label: Text(cart.length.toString()),
                                  isLabelVisible: cart.isNotEmpty,
                                  backgroundColor: t.colorScheme.error,
                                  child: const Icon(
                                    Icons.shopping_cart_outlined,
                                  ),
                                ),
                              ),
                          activeIcon:
                              ValueListenableBuilder<
                                List<Map<String, dynamic>>
                              >(
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
      ),
    );
  }
}

class _TabPopObserver extends NavigatorObserver {
  _TabPopObserver({required this.tabIndex, required this.nav});

  final int tabIndex;
  final NavigationService nav;

  // Count of full-page routes (PageRoute) on this tab's stack, root included.
  // The bottom nav bar hides only when a *detail page* is pushed (depth > 1).
  //
  // We must NOT count popup routes — dropdown menus, popup menus, and modal
  // bottom sheets all push onto this tab's Navigator by default (only
  // showDialog/showDatePicker default to the root navigator), and they are
  // PopupRoutes, not PageRoutes. Querying navigator.canPop() (the old approach)
  // counted them too, so the bar flickered away every time a filter dropdown or
  // sheet opened on a root tab (Inventory / POS / Home) and reappeared a frame
  // later on dismiss. A popup overlays the bar anyway — its presence underneath
  // is harmless and correct, so it must never toggle visibility.
  int _pageDepth = 0;

  void _sync() {
    final canPop = _pageDepth > 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.setTabCanPop(tabIndex, canPop);
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (route is PageRoute) {
      _pageDepth++;
      _sync();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (route is PageRoute) {
      _pageDepth--;
      _sync();
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (route is PageRoute) {
      _pageDepth--;
      _sync();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    var changed = false;
    if (oldRoute is PageRoute) {
      _pageDepth--;
      changed = true;
    }
    if (newRoute is PageRoute) {
      _pageDepth++;
      changed = true;
    }
    if (changed) _sync();
  }
}
