import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NavigationService {
  static final NavigationService _instance = NavigationService._internal();

  factory NavigationService() {
    return _instance;
  }

  NavigationService._internal();

  final ValueNotifier<int> currentIndex = ValueNotifier<int>(1);
  final List<int> _history = [];

  // Each tab has its own NavigatorState key
  List<GlobalKey<NavigatorState>> tabNavigatorKeys = [];

  // Per-tab nested-Navigator pop state, kept in sync by NavigatorObservers
  // attached in MainLayout. `currentTabCanPop` surfaces only the active tab's
  // value so the bottom nav can listen to a single notifier.
  final List<bool> _tabCanPop = List.filled(12, false);
  final ValueNotifier<bool> currentTabCanPop = ValueNotifier<bool>(false);

  // One-shot flag set by SuccessDashboardEntryScreen and consumed once by
  // MainLayout on first frame after mount. Replaces the previous nested
  // Future.delayed in SuccessDashboardEntryScreen which used `ref` after
  // pushAndRemoveUntil disposed the source widget. See plan §"Bug fix"
  // Pattern 3.
  bool _autoShowAddProductPending = false;
  void requestAutoShowAddProductSheet() {
    _autoShowAddProductPending = true;
  }
  bool consumeAutoShowAddProductSheet() {
    final v = _autoShowAddProductPending;
    _autoShowAddProductPending = false;
    return v;
  }

  void setTabCanPop(int tabIndex, bool canPop) {
    if (tabIndex < 0 || tabIndex >= _tabCanPop.length) return;
    _tabCanPop[tabIndex] = canPop;
    if (tabIndex == currentIndex.value) {
      currentTabCanPop.value = canPop;
    }
  }

  // Used by MainLayout to access and potentially close the drawer
  final GlobalKey<ScaffoldState> mainScaffoldKey = GlobalKey<ScaffoldState>();

  bool get isDrawerOpen => mainScaffoldKey.currentState?.isDrawerOpen ?? false;

  void openDrawer() {
    mainScaffoldKey.currentState?.openDrawer();
  }

  void closeDrawer() {
    mainScaffoldKey.currentState?.closeDrawer();
  }

  final ValueNotifier<bool> warehouseLocked = ValueNotifier<bool>(false);
  final ValueNotifier<String?> lockedWarehouseId = ValueNotifier<String?>(null);

  /// Used by InventoryScreen to react to warehouse changes from other screens.
  final ValueNotifier<String?> selectedWarehouseId = ValueNotifier<String?>(
    null,
  );

  /// One-shot warehouse pre-filter for CustomersScreen. Set by the warehouse
  /// details "Customers" card before switching to the customers tab. The
  /// customers screen reads this once on init and clears it.
  final ValueNotifier<String?> customersInitialWarehouseId = ValueNotifier<String?>(
    null,
  );

  static final Map<int, String> indexToRoute = {
    0: 'dashboard',
    1: 'pos',
    2: 'inventory',
    3: 'orders',
    4: 'customers',
    5: 'payments',
    6: 'expenses',
    7: 'warehouse',
    8: 'staff',
    9: 'cart',
    10: 'deliveries',
    11: 'activity',
  };

  void setIndex(int index) {
    if (currentIndex.value != index) {
      _history.add(currentIndex.value);
      // Keep history reasonable
      if (_history.length > 10) _history.removeAt(0);
      currentIndex.value = index;
      if (index >= 0 && index < _tabCanPop.length) {
        currentTabCanPop.value = _tabCanPop[index];
      }
    }
  }

  bool popIndex() {
    if (_history.isNotEmpty) {
      currentIndex.value = _history.removeLast();
      return true;
    }
    return false;
  }

  // ── Back navigation ───────────────────────────────────────────────────────
  DateTime? _lastBackPress;
  DateTime?
  _lastHandleTime; // Only blocks hardware double-fires, NOT user presses

  /// Returns true if the event was fully consumed (caller should NOT let Flutter
  /// propagate it further). Wire this into PopScope's onPopInvokedWithResult:
  ///   onPopInvokedWithResult: (didPop, _) { if (!didPop) handleBackPress(ctx, tier); }
  /// Make sure PopScope has canPop: false so Flutter never pops on its own.
  void handleBackPress(BuildContext context, int roleTier) {
    final now = DateTime.now();

    // Block hardware-level double-fires only (< 500 ms).
    // Some devices have high latency in hardware bounce.
    if (_lastHandleTime != null &&
        now.difference(_lastHandleTime!) < const Duration(milliseconds: 500)) {
      debugPrint('[NavigationService] Back press blocked by hardware debounce');
      return;
    }
    _lastHandleTime = now;

    debugPrint('[NavigationService] handleBackPress triggered at $now');

    // Step 1: close drawer if open
    if (isDrawerOpen) {
      closeDrawer();
      return;
    }

    // Step 2: pop nested screen within the current tab
    final tabNav =
        tabNavigatorKeys.isNotEmpty &&
            currentIndex.value < tabNavigatorKeys.length
        ? tabNavigatorKeys[currentIndex.value].currentState
        : null;

    if (tabNav != null && tabNav.canPop()) {
      tabNav.pop();
      return;
    }

    // Step 3: go to role-based home tab if not already there
    final homeTab = roleTier >= 5 ? 0 : 1;
    if (currentIndex.value != homeTab) {
      debugPrint(
        '[NavigationService] Not on home tab ($homeTab). Redirecting...',
      );
      setIndex(homeTab);
      return;
    }

    // Step 4: already on home — double-back-to-exit
    debugPrint(
      '[NavigationService] Already on home tab. Checking double-back exit...',
    );
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      debugPrint('[NavigationService] Showing exit warning snackbar');
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Press back again to exit'),
            duration: Duration(seconds: 2),
          ),
        );
    } else {
      debugPrint(
        '[NavigationService] Second back press within 2s, EXITING APP',
      );
      _lastBackPress = null;
      SystemNavigator.pop();
    }
  }

  /// Called right after login. Locks non-CEO users to their assigned warehouse.
  /// [roleTier] and [warehouseId] come from the UserData that just logged in.
  void applyUserWarehouseLock(int roleTier, String? warehouseId) {
    if (roleTier >= 6) {
      // CEO — no restrictions, clear any previous lock
      warehouseLocked.value = false;
      lockedWarehouseId.value = null;
    } else {
      warehouseLocked.value = true;
      lockedWarehouseId.value = warehouseId;
    }
  }

  /// Called on logout — removes all warehouse restrictions.
  void clearWarehouseLock() {
    warehouseLocked.value = false;
    lockedWarehouseId.value = null;
  }

  /// Resets navigation state to defaults. Call on logout so the next session
  /// starts clean (tab 0, empty history).
  void resetNavigation() {
    _history.clear();
    currentIndex.value = 0;
    _lastBackPress = null;
    _lastHandleTime = null;
    for (int i = 0; i < _tabCanPop.length; i++) {
      _tabCanPop[i] = false;
    }
    currentTabCanPop.value = false;
  }

  /// Manually update the warehouse lock (e.g. for CEO switching locations in POS)
  void setLockedWarehouse(String? id) {
    lockedWarehouseId.value = id;
  }
}
