import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/payments/screens/payments_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/shared/widgets/activity_log_screen.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/tab_navigator.dart';
import 'package:reebaplus_pos/shared/widgets/sync_pull_banner.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/frame/cart_panel.dart';
import 'package:reebaplus_pos/shared/widgets/frame/frame_nav.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/view_cart_bar.dart';
import 'package:reebaplus_pos/shared/widgets/push_permission_sheet.dart';
import 'package:reebaplus_pos/features/dashboard/controllers/first_run_tour_controller.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

// The LazyIndexedStack has been replaced with the direct Offstage + Set approach
// requested for eliminating mount jank on cold start.

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout>
    with TickerProviderStateMixin {
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

  late final AnimationController _bottomBarController;
  late final Animation<double> _bottomBarAnimation;

  // ── App frame (#352) ──────────────────────────────────────────────────────
  /// Keeps the tab stack (and every tab Navigator) intact when a rotation
  /// moves it between the bottom-bar and the rail layouts.
  final GlobalKey _contentKey = GlobalKey();

  /// The cart panel's own Navigator (600dp+), so checkout opened from the
  /// panel stays inside the panel.
  final GlobalKey<NavigatorState> _panelNavigatorKey =
      GlobalKey<NavigatorState>();

  /// Built once, on the panel's first appearance.
  CartScreen? _panelCartScreen;

  /// Whether the cart panel is wanted open: the slide-in panel after "View
  /// Cart" (600–1023dp), the fixed panel until its ✕ (1024dp+).
  bool _panelOpen = false;

  /// Mounted lazily on first show, then kept so an in-progress checkout
  /// survives closing and reopening the panel.
  bool _panelMounted = false;

  /// The panel mode seen by the last build; a change resets [_panelOpen].
  _CartPanelMode? _lastPanelMode;

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

    // Push (#138 Slice 2): the app shell is mounted (authed, past PIN) — replay
    // a cold-start broadcast tap and, once per install, soft-ask for
    // notification permission. Post-frame so `context`/navigator are ready.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _bootstrapPushForShell(),
    );

    _tabSwitchController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _tabFadeAnimation = CurvedAnimation(
      parent: _tabSwitchController,
      curve: Curves.easeOut,
    );

    _bottomBarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _bottomBarAnimation = CurvedAnimation(
      parent: _bottomBarController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _nav.currentIndex.addListener(_onTabIndexChanged);
    _nav.currentTabCanPop.addListener(_onCurrentTabCanPopChanged);

    _pendingOrdersSub = ref
        .read(databaseProvider)
        .ordersDao
        .watchPendingOrders()
        .listen((orders) {
          if (mounted) setState(() => _pendingOrders = orders);
        });
  }

  @override
  void dispose() {
    _nav.currentIndex.removeListener(_onTabIndexChanged);
    _nav.currentTabCanPop.removeListener(_onCurrentTabCanPopChanged);
    _tabSwitchController.dispose();
    _bottomBarController.dispose();
    _pendingOrdersSub?.cancel();
    super.dispose();
  }

  /// Push (#138 Slice 2): ensure the FCM port is started (idempotent), replay a
  /// killed-app broadcast tap now that we're safely past auth/PIN, then run the
  /// once-per-install permission soft-ask.
  Future<void> _bootstrapPushForShell() async {
    final push = ref.read(pushNotificationServiceProvider);
    await push.start();
    await push.replayInitialTap();
    if (!mounted) return;
    await maybePromptForPushPermission(context, ref);
  }

  void _onTabIndexChanged() {
    final newIndex = _nav.currentIndex.value;
    if (newIndex == _previousTabIndex) return;
    _previousTabIndex = newIndex;
    _tabSwitchController.forward(from: 0);
    _showBottomBar(immediate: true);
    // Leaving POS takes the slide-in cart panel (and its dim) with it; the
    // fixed wide panel stays wanted for when POS comes back.
    if (mounted &&
        _panelOpen &&
        _lastPanelMode == _CartPanelMode.slideIn &&
        newIndex != NavigationService.posTab) {
      setState(() => _panelOpen = false);
    }
  }

  void _onCurrentTabCanPopChanged() {
    if (!_nav.currentTabCanPop.value) {
      _showBottomBar(immediate: true);
    }
  }

  void _hideBottomBar() {
    if (_bottomBarController.status != AnimationStatus.reverse &&
        _bottomBarController.value > 0.0) {
      _bottomBarController.reverse();
    }
  }

  void _showBottomBar({bool immediate = false}) {
    if (immediate) {
      if (_bottomBarController.value != 1.0) {
        _bottomBarController.value = 1.0;
      }
    } else if (_bottomBarController.status != AnimationStatus.forward &&
        _bottomBarController.value < 1.0) {
      _bottomBarController.forward();
    }
  }

  bool _handleScrollNotification(
    BuildContext context,
    ScrollNotification notification,
  ) {
    // 1. Only sideways viewports that still have the bottom bar (under 600dp
    // wide, #352) slide it away. Upright never hides; 600dp+ has the rail.
    final isMobileLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        !context.isRailLayout;
    if (!isMobileLandscape) {
      return false;
    }

    // 2. Only vertical scrolling in the active screen drives it.
    // Sideways swipes (tabs, chip rows) never toggle it.
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }

    // 3. Resolve the notification's source navigator and ensure it belongs to the
    // currently active tab. Offstage tabs or unrelated navigators never drive the bar.
    final notificationContext = notification.context;
    if (notificationContext == null) {
      return false;
    }
    final sourceNavigator = Navigator.maybeOf(notificationContext);
    if (!_nav.isActiveTabNavigator(sourceNavigator)) {
      return false;
    }

    // 4. If this notification originates from a pushed modal / route (not the root screen),
    // do not let it toggle or restore the root bottom bar.
    final route = ModalRoute.of(notificationContext);
    if (route != null && !route.isFirst) {
      return false;
    }

    // 5. If content fits without scrolling (maxScrollExtent <= 0), never hide.
    if (notification.metrics.maxScrollExtent <= 0) {
      return false;
    }

    // 6. If content returns to the top (or in overscroll), always show the bar.
    if (notification.metrics.pixels <= 0) {
      _showBottomBar();
      return false;
    }

    // 7. Scroll direction handling:
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.reverse) {
        _hideBottomBar();
      } else if (notification.direction == ScrollDirection.forward) {
        _showBottomBar();
      }
    } else if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta;
      if (delta != null) {
        if (delta > 2.0 && notification.metrics.pixels > 10.0) {
          _hideBottomBar();
        } else if (delta < -2.0) {
          _showBottomBar();
        }
      }
    }

    return false;
  }

  bool _handleScrollMetricsNotification(
    BuildContext context,
    ScrollMetricsNotification notification,
  ) {
    final isMobileLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        !context.isRailLayout;
    if (!isMobileLandscape) {
      return false;
    }

    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }

    final sourceNavigator = Navigator.maybeOf(notification.context);
    if (!_nav.isActiveTabNavigator(sourceNavigator)) {
      return false;
    }

    final route = ModalRoute.of(notification.context);
    if (route != null && !route.isFirst) {
      return false;
    }

    if (notification.metrics.maxScrollExtent <= 0) {
      _showBottomBar();
    }

    return false;
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

  String _getActiveRoute(int index) {
    switch (index) {
      case 0:
        return 'dashboard';
      case 1:
        return 'pos';
      case 2:
        return 'inventory';
      case 3:
        return 'orders';
      case 4:
        return 'customers';
      case 5:
        return 'supplier_accounts';
      case 6:
        return 'expenses';
      case 7:
        return 'store';
      case 8:
        return 'cart';
      case 9:
        return 'activity_logs';
      default:
        return 'dashboard';
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.read(navigationProvider);

    // §12.1: the Orders badge is scoped to the active side-bar store. A concrete
    // store counts only its own pending orders; "All Stores" (null) counts all.
    final activeStoreId = ref.watch(lockedStoreProvider).value;
    final pendingOrderCount = activeStoreId == null
        ? _pendingOrders.length
        : _pendingOrders.where((o) => o.storeId == activeStoreId).length;

    // §12.1 active-store default. The app never auto-lands on "All Stores": every
    // user — confined staff AND all-stores viewers (CEO / all-stores Manager) —
    // silently defaults to a concrete active store (their first selectable store,
    // or their lone store) so every view filters to a real store and the
    // permission resolver scopes correctly. "All Stores" is only ever reached as
    // a deliberate pick from the store picker (latched via `allStoresChosen`),
    // which we must NOT override here. The mutation is deferred to post-frame so
    // it never runs during build (lockedStoreId has listeners that rebuild).
    final selectableStores = ref.watch(selectableStoresProvider);
    if (selectableStores.isNotEmpty) {
      final active = nav.lockedStoreId.value;
      final activeValid =
          active != null && selectableStores.any((s) => s.id == active);
      // A CEO / all-stores Manager who deliberately chose All Stores keeps null.
      final allStoresDeliberate =
          ref.watch(canViewAllStoresProvider) && nav.allStoresChosen.value;
      if (!activeValid && !allStoresDeliberate) {
        final target = selectableStores.first.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (nav.lockedStoreId.value == target) return;
          // explicit: false — this is the silent default, not a user pick, so the
          // POS gate still prompts a multi-store user to choose before selling.
          nav.setLockedStore(target, explicit: false);
        });
      }
    }

    // Role landing tab. `setCurrentUser` opens every session on Home because the
    // role row has not arrived from local SQLite yet; once it has, move the
    // session to the tab this role actually starts its day on — Cashier on the
    // till, CEO / Manager / Stock keeper on Home (see
    // `NavigationService.landingTabForRole`). Both reads below are gated on the
    // permission set being RESOLVED (not the transient empty-while-loading
    // state) so nobody is routed off a stale, still-denying gate.
    //
    // `canSell` folds hard rule #7 into the landing: a role that cannot sell
    // lands on Home whatever its slug says, so a Cashier stripped of
    // `sales.make` never opens on a POS tab that is hidden from their nav bar.
    //
    // `applyRoleLanding` is a one-shot — re-scheduling it on every build until
    // the role resolves is cheap, and it will not yank a user who has already
    // moved to another tab.
    final canSell = Gates.makeSale.allows(ref);
    final role = ref.watch(currentUserRoleProvider);
    final permsResolved =
        role != null && ref.watch(rolePermissionsProvider(role.id)).hasValue;
    if (permsResolved) {
      final landing = canSell
          ? NavigationService.landingTabForRole(role.slug)
          : NavigationService.homeTab;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        nav.applyRoleLanding(landing);
      });
    }

    // Hard rule #7, continuous guard: a role without POS access (e.g. the stock
    // keeper) must never SIT on the POS (1) or Cart (8) tab — both are
    // sales.make-gated and hidden from their nav bar, so being there leaves them
    // on a screen they can't use with no tab to leave it. Distinct from the
    // one-shot landing above and deliberately NOT latched: this also catches a
    // permission revoked live mid-session while they are standing on the tab.
    if (permsResolved && !canSell) {
      final idx = nav.currentIndex.value;
      if (idx == 1 || idx == 8) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final live = nav.currentIndex.value;
          if (live == 1 || live == 8) nav.setIndex(NavigationService.homeTab);
        });
      }
    }

    final isMobileLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        !context.isRailLayout;
    if (!isMobileLandscape && _bottomBarController.value < 1.0) {
      _bottomBarController.value = 1.0;
    }

    // Cart panel mode follows the width (#352). Entering the wide layout opens
    // the fixed panel; entering the slide-in layout (or the phone layout)
    // starts it closed. Plain field writes: nothing listens to them but this
    // build.
    final panelMode = _panelModeOf(context);
    if (panelMode != _lastPanelMode) {
      _panelOpen = panelMode == _CartPanelMode.fixed;
      _lastPanelMode = panelMode;
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_handleCartPanelBack()) return;
        _nav.handleBackPress(context);
      },
      child: ValueListenableBuilder<int>(
        valueListenable: nav.currentIndex,
        builder: (context, currentIndex, _) {
          _initializedTabs.add(currentIndex); // mark as visited
          return ValueListenableBuilder<bool>(
            valueListenable: nav.currentTabCanPop,
            builder: (context, canPop, _) => _buildFrame(
              context,
              currentIndex: currentIndex,
              canPop: canPop,
              pendingOrderCount: pendingOrderCount,
              panelMode: panelMode,
            ),
          );
        },
      ),
    );
  }

  /// The tabs, the navigation (bottom bar or rail), the drawer and the cart
  /// panel host, arranged for the current width (#352).
  Widget _buildFrame(
    BuildContext context, {
    required int currentIndex,
    required bool canPop,
    required int pendingOrderCount,
    required _CartPanelMode panelMode,
  }) {
    final nav = _nav;
    final isRail = context.isRailLayout;
    final onPosRoot = currentIndex == NavigationService.posTab && !canPop;
    final panelShown =
        panelMode != _CartPanelMode.none && onPosRoot && _panelOpen;
    if (panelShown) _panelMounted = true;

    // Tab content. Keyed so the whole stack (and every tab's Navigator) moves
    // intact when a rotation swaps the bottom bar for the rail. The scope
    // tells everything above a visible bottom bar that the bar already clears
    // the system-nav inset (#377), so deviceBottomPadding adds none there.
    final tabs = BottomBarInsetScope(
      clearsInset: !isRail && _bottomBarShown(currentIndex, canPop),
      child: KeyedSubtree(
        key: _contentKey,
        child: Stack(
          children: [
            ...List.generate(_tabWidgets.length, (i) {
              if (!_initializedTabs.contains(i)) {
                // Not yet visited — render nothing
                return const SizedBox.shrink();
              }
              Widget tabChild = TabNavigator(
                navigatorKey: _navigatorKeys[i],
                rootScreen: _tabWidgets[i],
                observer: _observers[i],
              );
              if (i == NavigationService.posTab) {
                // The View Cart bar sits under POS (never over its grid or its
                // scan button). The Column is unconditional so POS's Navigator
                // keeps its place in the tree whether the bar shows or not.
                tabChild = Column(
                  children: [
                    Expanded(child: tabChild),
                    _buildViewCartSlot(
                      context,
                      onPosRoot: onPosRoot,
                      panelMode: panelMode,
                    ),
                  ],
                );
              }
              final tab = Offstage(
                offstage: i != currentIndex,
                // TickerMode guarantees animations on offstage tabs don't tick
                child: TickerMode(enabled: i == currentIndex, child: tabChild),
              );
              if (i != currentIndex) return tab;
              return FadeTransition(opacity: _tabFadeAnimation, child: tab);
            }),
            // Non-blocking sync pull status overlay — first-download
            // progress bar at top, "Synced" pill above the bottom nav.
            const Positioned.fill(child: SyncPullBanner()),
          ],
        ),
      ),
    );

    final cartPanel = (panelMode != _CartPanelMode.none && _panelMounted)
        ? _buildCartPanel()
        : null;

    // Side system insets (#352 phone check): a landscape navigation bar on
    // the right, or a display cutout on the left. The rail owns the left one;
    // the content owns the right one unless the fixed cart panel sits there
    // (the panel owns it then). Under 600dp the content owns both.
    final fixedPanelShown = panelMode == _CartPanelMode.fixed && panelShown;
    Widget bodyWidget = _insetContent(
      context,
      tabs,
      padLeft: !isRail,
      padRight: !fixedPanelShown,
    );
    if (isRail) {
      bodyWidget = Row(
        children: [
          _buildNavigation(
            context,
            currentIndex: currentIndex,
            pendingOrderCount: pendingOrderCount,
            rail: true,
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).dividerColor,
          ),
          Expanded(child: bodyWidget),
          if (panelMode == _CartPanelMode.fixed && cartPanel != null)
            Offstage(
              offstage: !panelShown,
              child: TickerMode(enabled: panelShown, child: cartPanel),
            ),
        ],
      );
    }

    final scrollListeningBody = NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) =>
          _handleScrollMetricsNotification(context, notification),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) =>
            _handleScrollNotification(context, notification),
        child: bodyWidget,
      ),
    );

    final slideIn = panelMode == _CartPanelMode.slideIn && cartPanel != null;
    final activeRoute = _getActiveRoute(currentIndex);

    return Stack(
      children: [
        Scaffold(
          key: nav.mainScaffoldKey,
          // At 600dp+ the drawer belongs to this Scaffold, so it pops over the
          // rail and the content alike; the rail's menu button opens it. Under
          // 600dp each screen keeps declaring its own (SharedScaffold & co.).
          drawer: isRail ? AppDrawer(activeRoute: activeRoute) : null,
          // DrawerHost must sit inside the Scaffold that declares the drawer
          // (test/tour/drawer_presence_ban_test.dart). Its opener rules itself
          // out — it is not inside a tab Navigator — so NavigationService.
          // openDrawer() falls back to mainScaffoldKey, which is this drawer.
          body: DrawerHost(child: scrollListeningBody),
          bottomNavigationBar: isRail
              ? null
              : _buildBottomBarHost(
                  context,
                  currentIndex: currentIndex,
                  canPop: canPop,
                  pendingOrderCount: pendingOrderCount,
                ),
        ),
        if (slideIn) ...[
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !panelShown,
              child: AnimatedOpacity(
                opacity: panelShown ? 1.0 : 0.0,
                duration: _kPanelSlideDuration,
                curve: Curves.easeOut,
                child: CartPanelScrim(onTap: _closeCartPanel),
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !panelShown,
              child: AnimatedSlide(
                offset: panelShown ? Offset.zero : const Offset(1, 0),
                duration: _kPanelSlideDuration,
                curve: Curves.easeOutCubic,
                child: TickerMode(enabled: panelShown, child: cartPanel),
              ),
            ),
          ),
        ],
        const FirstRunRailTourView(),
      ],
    );
  }

  /// Pads [child] clear of the left / right system insets it owns and removes
  /// those insets from its MediaQuery, so screens inside never add them again.
  ///
  /// The MediaQuery is read INSIDE the frame Scaffold's body (the [Builder]),
  /// never from MainLayout's own context above it (#377). The Scaffold has
  /// already taken the bottom system inset out of its body when the bottom
  /// bar is present (the bar pads itself by it) and the keyboard out always
  /// (it resizes the body). Rebuilding from the outer context put both back:
  /// every tab body with a bottom `SafeArea` (POS, Stock) padded the
  /// system-nav height a second time above the bar — the band — and nested
  /// Scaffolds resized for the keyboard twice. So the rule inside the frame:
  /// a screen's MediaQuery is exactly what the frame Scaffold gives its body,
  /// minus the side insets handled here.
  Widget _insetContent(
    BuildContext context,
    Widget child, {
    required bool padLeft,
    required bool padRight,
  }) {
    return Builder(
      builder: (context) {
        final insets = MediaQuery.paddingOf(context);
        return Padding(
          padding: EdgeInsets.only(
            left: padLeft ? insets.left : 0.0,
            right: padRight ? insets.right : 0.0,
          ),
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            child: child,
          ),
        );
      },
    );
  }

  /// Whether the bottom bar is on screen (under 600dp wide): only on a nav
  /// tab's root. A pushed screen or a drawer-only tab has no bar.
  bool _bottomBarShown(int currentIndex, bool canPop) =>
      !canPop && _navTabOrder().contains(currentIndex);

  /// The bottom bar under 600dp wide, inside #258's slide-away clip.
  Widget _buildBottomBarHost(
    BuildContext context, {
    required int currentIndex,
    required bool canPop,
    required int pendingOrderCount,
  }) {
    if (!_bottomBarShown(currentIndex, canPop)) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _bottomBarAnimation,
      builder: (context, child) {
        final value = _bottomBarAnimation.value;
        return ClipRect(
          key: const Key('main-bottom-nav-clip'),
          // Fully shown, the raised POS circle may rise above the bar; only
          // clip while the bar is sliding away (#258).
          clipBehavior: value >= 1.0 ? Clip.none : Clip.hardEdge,
          child: Align(
            key: const Key('main-bottom-nav-align'),
            alignment: Alignment.topCenter,
            heightFactor: value,
            child: child,
          ),
        );
      },
      child: _buildNavigation(
        context,
        currentIndex: currentIndex,
        pendingOrderCount: pendingOrderCount,
        rail: false,
      ),
    );
  }

  /// Nav tabs in bar order. Stock (Inventory, tab 2) is gated on
  /// Gates.viewInventory (§16.7); POS (tab 1) and Cart (tab 8) are gated on
  /// Gates.makeSale (hard rule #7 — hide what the role can't use, e.g. the
  /// stock keeper) — the same entries as the drawer items and destination
  /// screens. Home(0), Stock(2), POS(1), Orders(3), Cart(8). The bottom bar
  /// and the rail both draw from this one list (#352).
  List<int> _navTabOrder() {
    final showStock = Gates.viewInventory.allows(ref);
    final showPos = Gates.makeSale.allows(ref);
    return <int>[
      NavigationService.homeTab,
      if (showStock) 2,
      if (showPos) NavigationService.posTab,
      3,
      if (showPos) 8,
    ];
  }

  List<FrameNavItem> _navItems({
    required int pendingOrderCount,
    required int cartCount,
  }) {
    return [
      for (final tab in _navTabOrder())
        switch (tab) {
          NavigationService.homeTab => const FrameNavItem(
            tabIndex: NavigationService.homeTab,
            icon: AppIcons.home,
            label: 'Home',
          ),
          2 => const FrameNavItem(
            tabIndex: 2,
            icon: AppIcons.inventory,
            label: 'Stock',
          ),
          NavigationService.posTab => const FrameNavItem(
            tabIndex: NavigationService.posTab,
            icon: AppIcons.pos,
            label: 'POS',
            raised: true,
          ),
          3 => FrameNavItem(
            tabIndex: 3,
            icon: AppIcons.orders,
            label: 'Orders',
            badgeCount: pendingOrderCount,
          ),
          _ => FrameNavItem(
            tabIndex: 8,
            icon: AppIcons.cart,
            label: 'Cart',
            badgeCount: cartCount,
            flyTarget: FlyTargetId.cart,
          ),
        },
    ];
  }

  /// The bottom bar ([rail] false) or the side rail ([rail] true). Same items,
  /// same order, same permission hiding, same tap behaviour.
  Widget _buildNavigation(
    BuildContext context, {
    required int currentIndex,
    required int pendingOrderCount,
    required bool rail,
  }) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ref.read(cartProvider),
      builder: (context, cart, _) {
        final items = _navItems(
          pendingOrderCount: pendingOrderCount,
          cartCount: cart.length,
        );
        void onTap(int tab) => _onNavTap(tab, currentIndex);
        return rail
            ? FrameNavRail(
                key: const Key('main-nav-rail'),
                items: items,
                currentIndex: currentIndex,
                onTap: onTap,
              )
            : FrameBottomBar(
                key: const Key('main-bottom-nav'),
                items: items,
                currentIndex: currentIndex,
                onTap: onTap,
              );
      },
    );
  }

  void _onNavTap(int tab, int currentIndex) {
    if (currentIndex == tab) {
      // Tap current tab: pop all detail screens to root
      _navigatorKeys[tab].currentState?.popUntil((r) => r.isFirst);
    } else {
      _nav.setIndex(tab);
    }
  }

  /// The View Cart bar under POS: shown on the POS root when the cart has
  /// lines and the cart panel is not already showing it.
  Widget _buildViewCartSlot(
    BuildContext context, {
    required bool onPosRoot,
    required _CartPanelMode panelMode,
  }) {
    final cart = ref.read(cartProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([cart, cart.activeCustomer]),
      builder: (context, _) {
        // Hidden while the keyboard is up (e.g. searching POS): the bottom
        // bar sits behind the keyboard, and so should this. Read from the raw
        // view because this Scaffold body has the inset removed.
        final view = View.maybeOf(context);
        final keyboardUp =
            view != null && MediaQueryData.fromView(view).viewInsets.bottom > 0;
        final panelHandlesCart = panelMode != _CartPanelMode.none && _panelOpen;
        if (!onPosRoot ||
            cart.value.isEmpty ||
            keyboardUp ||
            panelHandlesCart) {
          return const SizedBox.shrink();
        }
        final gutter = context.getRSize(16);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(8),
            gutter,
            context.getRSize(8) +
                (context.isRailLayout
                    ? MediaQuery.paddingOf(context).bottom
                    : 0),
          ),
          child: ViewCartBar(
            itemCount: cart.value.length,
            customerName: cart.activeCustomer.value?.name ?? 'Walk-in Customer',
            total: cart.subtotal - cart.discountTotalKobo / 100.0,
            onTap: () => _onViewCart(panelMode),
          ),
        );
      },
    );
  }

  void _onViewCart(_CartPanelMode panelMode) {
    if (panelMode == _CartPanelMode.none) {
      // Under 600dp the cart lives on the Cart tab.
      _nav.setIndex(_cartTab);
      return;
    }
    setState(() => _panelOpen = true);
  }

  void _closeCartPanel() {
    if (!mounted) return;
    setState(() => _panelOpen = false);
  }

  /// Back press while the cart panel is on screen: first unwind anything the
  /// panel pushed (checkout, receipt), then close a slide-in panel. Returns
  /// whether the press was used.
  bool _handleCartPanelBack() {
    final mode = _lastPanelMode;
    if (mode == null || mode == _CartPanelMode.none || !_panelOpen) {
      return false;
    }
    final onPos =
        _nav.currentIndex.value == NavigationService.posTab &&
        !_nav.currentTabCanPop.value;
    if (!onPos) return false;
    final panelNav = _panelNavigatorKey.currentState;
    if (panelNav != null && panelNav.canPop()) {
      panelNav.pop();
      return true;
    }
    if (mode == _CartPanelMode.slideIn) {
      _closeCartPanel();
      return true;
    }
    return false;
  }

  /// The cart panel's content: the existing Cart screen in its own Navigator,
  /// so checkout and the receipt open inside the panel through the very same
  /// code path the Cart tab uses.
  Widget _buildCartPanel() {
    _panelCartScreen ??= CartScreen(
      cart: const [],
      activeCustomer: ref.read(cartProvider).activeCustomer.value,
      onCustomerChanged: _voidOnCustomerChanged,
      onClosePanel: _closeCartPanel,
    );
    return CartPanel(
      child: TabNavigator(
        navigatorKey: _panelNavigatorKey,
        rootScreen: _panelCartScreen!,
      ),
    );
  }
}

/// How the cart is hosted on POS at the current width (#352).
enum _CartPanelMode {
  /// Under 600dp: no panel; the cart is the Cart tab.
  none,

  /// 600–1023dp: slides in from the right over a dimmed screen.
  slideIn,

  /// 1024dp+: fixed on the right of POS.
  fixed,
}

_CartPanelMode _panelModeOf(BuildContext context) {
  if (!context.isRailLayout) return _CartPanelMode.none;
  return context.isWideLayout ? _CartPanelMode.fixed : _CartPanelMode.slideIn;
}

const Duration _kPanelSlideDuration = Duration(milliseconds: 250);

/// MainLayout's Cart tab index.
const int _cartTab = 8;

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
